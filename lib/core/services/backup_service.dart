import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import '../constants/scripts.dart' as scripts;
import 'backend_process_manager.dart';
import '../utils/file_utils.dart';
import '../../ui/pages/settings/dialogs/backup_restore_dialog.dart';

/// 备份与恢复服务：负责 MaiBot / NapCat 全量备份与细粒度选择性模块恢复的底层文件与事务处理
class BackupService {
  /// 异步获取本地现有的所有有效备份文件（按修改时间倒序排列，最新的排在最前）
  static Future<List<File>> getAvailableBackupsAsync() async {
    try {
      final backupDirs = [
        getMaiBotBackupDirectory(),
        Directory('${RuntimeEnvir.homePath}/backups'),
      ];
      final seenPaths = <String>{};
      final fileEntries = <({File file, DateTime modified})>[];

      for (final backupDir in backupDirs) {
        if (!await backupDir.exists()) continue;
        await for (final entity in backupDir.list()) {
          if (entity is File && entity.path.endsWith('.tar.gz')) {
            if (seenPaths.contains(entity.path)) continue;
            seenPaths.add(entity.path);
            try {
              final stat = await entity.stat();
              if (stat.size > 1024) {
                fileEntries.add((file: entity, modified: stat.modified));
              }
            } catch (_) {}
          }
        }
      }

      fileEntries.sort((a, b) => b.modified.compareTo(a.modified));
      return fileEntries.map((e) => e.file).toList();
    } catch (e) {
      Log.e('异步扫描备份文件失败: $e', tag: 'BackupService');
      return [];
    }
  }

  /// 同步获取本地现有的所有有效备份文件
  static List<File> getAvailableBackups() {
    try {
      final backupDirs = [
        getMaiBotBackupDirectory(),
        Directory('${RuntimeEnvir.homePath}/backups'),
      ];
      final seenPaths = <String>{};
      final fileEntries = <({File file, DateTime modified})>[];

      for (final backupDir in backupDirs) {
        if (!backupDir.existsSync()) continue;
        for (final entity in backupDir.listSync()) {
          if (entity is File && entity.path.endsWith('.tar.gz')) {
            if (seenPaths.contains(entity.path)) continue;
            seenPaths.add(entity.path);
            try {
              final stat = entity.statSync();
              if (stat.size > 1024) {
                fileEntries.add((file: entity, modified: stat.modified));
              }
            } catch (_) {}
          }
        }
      }

      fileEntries.sort((a, b) => b.modified.compareTo(a.modified));
      return fileEntries.map((e) => e.file).toList();
    } catch (e) {
      Log.e('扫描备份文件失败: $e', tag: 'BackupService');
      return [];
    }
  }

  /// 安全平滑停止后台进程与 Linux 容器
  static Future<void> safelyTerminateProcessesForMaintenance() async {
    Log.i('通过统一进程管理器平滑停止后台容器与进程...', tag: 'BackupService');
    await BackendProcessManager.runMaintenanceTransaction(
      action: () async => null,
      autoRestart: false,
    );
  }

  /// 确保获取存储权限（支持 Android 11+ 所有文件权限与旧版存储权限），无法获取时降级使用内部目录
  static Future<bool> ensureStoragePermission() async {
    try {
      var manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isGranted) return true;

      var storageStatus = await Permission.storage.status;
      if (storageStatus.isGranted) return true;

      manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return true;

      storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) return true;

      final internalBackupDir = Directory('${RuntimeEnvir.homePath}/backups');
      if (await internalBackupDir.exists()) {
        return true;
      }
      return false;
    } catch (e) {
      Log.w('请求存储权限异常: $e', tag: 'BackupService');
      return true;
    }
  }

  /// 探测备份文件内部包含的具体模块
  static Future<Map<String, bool>> inspectBackupContents(File backupFile) async {
    final result = {
      'data': false,
      'config': false,
      'plugins': false,
      'napcat': false,
    };

    try {
      final proc = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-tzf',
        backupFile.path,
      ]);

      if (proc.exitCode == 0) {
        final lines = proc.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.startsWith('MaiBot/data/')) result['data'] = true;
          if (line.startsWith('MaiBot/config/')) result['config'] = true;
          if (line.startsWith('MaiBot/plugins/')) result['plugins'] = true;
          if (line.startsWith('napcat/config/')) result['napcat'] = true;
        }
      }
    } catch (e) {
      Log.w('解析备份目录结构异常: $e', tag: 'BackupService');
      return {'data': true, 'config': true, 'plugins': true, 'napcat': true};
    }

    return result;
  }

  /// 执行备份操作
  static Future<bool> performBackup({
    bool showLoadingDialog = false,
    bool restoreService = true,
  }) async {
    final hasPermission = await ensureStoragePermission();
    if (!hasPermission) {
      Get.snackbar(
        '权限不足',
        '需要存储权限才能备份数据到手机存储',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
      return false;
    }

    final dataPath = '${scripts.ubuntuPath}/root/MaiBot/data';
    final dataDir = Directory(dataPath);
    if (!await dataDir.exists()) {
      Get.snackbar(
        '备份失败',
        'MaiBot 数据目录不存在',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
      return false;
    }

    final backupDir = getMaiBotBackupDirectory();
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';

    final backupFileName = 'MaiBot-backup-$timestamp.tar.gz';
    final backupPath = '${backupDir.path}/$backupFileName';

    bool dialogShown = false;
    if (showLoadingDialog) {
      Get.dialog(
        const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(16))),
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在打包备份数据...', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
        ),
        barrierDismissible: false,
      );
      dialogShown = true;
    }

    void dismissDialog() {
      if (dialogShown) {
        if (Get.isDialogOpen == true) {
          Get.back();
        }
        dialogShown = false;
      }
    }

    return await BackendProcessManager.runMaintenanceTransaction(
      autoRestart: restoreService,
      action: () async {
        try {
          final List<String> pathsToCreate = [
            '${scripts.ubuntuPath}/root/MaiBot/config',
            '${scripts.ubuntuPath}/root/MaiBot/plugins',
            '${scripts.ubuntuPath}/root/napcat/config',
          ];
          for (final path in pathsToCreate) {
            final dir = Directory(path);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
          }

          final result = await Process.run('${RuntimeEnvir.binPath}/busybox', [
            'tar',
            '-czf',
            backupPath,
            '--exclude=MaiBot/plugins/hello_world_plugin',
            '-C',
            '${scripts.ubuntuPath}/root',
            'MaiBot/data',
            'MaiBot/config',
            'MaiBot/plugins',
            'napcat/config',
          ]);

          dismissDialog();

          if (result.exitCode == 0) {
            final backupFile = File(backupPath);
            final fileSize = await backupFile.length();
            final fileSizeMB = (fileSize / 1024 / 1024).toStringAsFixed(2);

            Get.snackbar(
              '备份成功',
              '备份文件: $backupFileName\n大小: ${fileSizeMB}MB',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 3),
            );
            Log.i('备份成功: $backupPath (${fileSizeMB}MB)', tag: 'BackupService');
            return true;
          } else {
            Get.snackbar(
              '备份失败',
              '错误: ${result.stderr}',
              snackPosition: SnackPosition.BOTTOM,
              backgroundColor: Colors.red,
              colorText: Colors.white,
            );
            Log.e('备份失败: ${result.stderr}', tag: 'BackupService');
            return false;
          }
        } catch (e) {
          dismissDialog();
          Get.snackbar(
            '备份失败',
            e.toString(),
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.red,
            colorText: Colors.white,
          );
          Log.e('备份异常: $e', tag: 'BackupService');
          return false;
        } finally {
          dismissDialog();
        }
      },
    );
  }

  /// 执行细粒度选择性备份恢复
  static Future<bool> performSelectiveRestore({
    required File backupFile,
    bool restoreData = true,
    bool restoreConfig = true,
    bool restorePlugins = true,
    bool restoreNapcat = true,
    bool restartService = true,
    bool showSnackbar = true,
  }) async {
    await ensureStoragePermission();

    if (!await backupFile.exists()) {
      if (showSnackbar) {
        Get.snackbar('恢复失败', '备份文件不存在', snackPosition: SnackPosition.BOTTOM);
      }
      return false;
    }

    Log.i('开始执行选择性备份恢复: ${backupFile.path}', tag: 'BackupService');
    return await BackendProcessManager.runMaintenanceTransaction(
      autoRestart: restartService,
      action: () async {
        try {
          final extractTargets = <String>[];
          if (restoreData) extractTargets.add('MaiBot/data');
          if (restoreConfig) extractTargets.add('MaiBot/config');
          if (restorePlugins) extractTargets.add('MaiBot/plugins');
          if (restoreNapcat) extractTargets.add('napcat/config');

          if (extractTargets.isEmpty) {
            if (showSnackbar) {
              Get.snackbar('提示', '未选择任何要恢复的模块',
                  snackPosition: SnackPosition.BOTTOM);
            }
            return true;
          }

          await Directory('${scripts.ubuntuPath}/root/MaiBot')
              .create(recursive: true);
          await Directory('${scripts.ubuntuPath}/root/napcat')
              .create(recursive: true);

          final args = [
            'tar',
            '-xzf',
            backupFile.path,
            '-C',
            '${scripts.ubuntuPath}/root',
            ...extractTargets,
          ];

          final res = await Process.run('${RuntimeEnvir.binPath}/busybox', args);
          if (res.exitCode == 0) {
            Log.i('选择性恢复成功: $extractTargets', tag: 'BackupService');
            if (showSnackbar) {
              Get.snackbar(
                '恢复成功',
                '已成功还原选定的数据与配置模块',
                snackPosition: SnackPosition.BOTTOM,
                duration: const Duration(seconds: 3),
              );
            }
            return true;
          } else {
            Log.e('恢复失败: ${res.stderr}', tag: 'BackupService');
            if (showSnackbar) {
              Get.snackbar('恢复失败', '解压文件失败: ${res.stderr}',
                  snackPosition: SnackPosition.BOTTOM);
            }
            return false;
          }
        } catch (e) {
          Log.e('恢复过程异常: $e', tag: 'BackupService');
          if (showSnackbar) {
            Get.snackbar('恢复异常', e.toString(),
                snackPosition: SnackPosition.BOTTOM);
          }
          return false;
        }
      },
    );
  }

  /// 显示备份恢复选择对话框（委托给 UI 层弹窗组件）
  static Future<void> showRestoreDialog({
    bool isInitialInstall = false,
    VoidCallback? onCompleted,
  }) async {
    await showBackupRestoreDialog(
      isInitialInstall: isInitialInstall,
      onCompleted: onCompleted,
    );
  }
}
