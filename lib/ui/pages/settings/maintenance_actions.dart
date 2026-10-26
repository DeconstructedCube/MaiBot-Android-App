import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';

import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/services/backend_process_manager.dart';
import '../../../core/services/backup_service.dart';
import '../../../core/services/installer_service.dart';

/// 设置页中的维护与重置操作（重装/清理/退出）
class MaintenanceActions {
  /// 更新或重装 MaiBot：删除 MaiBot 目录后退出应用
  static Future<void> reinstallMaiBot() async {
    // 询问是否需要备份
    final backupChoice = await Get.dialog<String>(
      AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 28, color: Colors.orange),
        title: const Text('重新安装 MaiBot'),
        content: const Text('重新安装将删除当前 MaiBot 的程序与数据。\n是否需要在重装前备份数据？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: 'cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Get.back(result: 'no_backup'),
            child: const Text('直接重装'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: 'backup'),
            child: const Text('备份后重装'),
          ),
        ],
      ),
    );

    if (backupChoice == 'cancel' || backupChoice == null) {
      return;
    }

    // 如果选择备份，先执行备份
    if (backupChoice == 'backup') {
      final backupSuccess = await BackupService.performBackup(
        showLoadingDialog: true,
        restoreService: false,
      );

      if (!backupSuccess) {
        final continueAnyway = await Get.dialog<bool>(
          AlertDialog(
            title: const Text('备份未完成'),
            content: const Text('数据备份失败，是否仍要继续重新安装？'),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: const Text('继续重装', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );

        if (continueAnyway != true) {
          // 用户取消，恢复后台服务
          await BackendProcessManager.startService();
          return;
        }
      }
    }

    // 最终确认
    final finalConfirm = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('确认重新安装'),
        content: const Text('确定要删除 MaiBot 并重新安装吗？\n未备份的数据将无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Get.back(result: true),
            child: const Text('确定重装'),
          ),
        ],
      ),
    );

    if (finalConfirm != true) {
      await BackendProcessManager.startService();
      return;
    }

    try {
      await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: false,
        action: () async {
          final maiBotPath = '${scripts.ubuntuPath}/root/MaiBot';
          final maiBotDir = Directory(maiBotPath);
          if (await maiBotDir.exists()) {
            await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', maiBotPath]);
            Log.i('已删除 MaiBot 目录: $maiBotPath', tag: 'MaiBot');
          }
        },
      );

      Get.snackbar(
        '操作完成',
        'MaiBot 数据已清理，应用即将退出，请重新打开以完成重装',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      Future.delayed(const Duration(seconds: 2), () async {
        await SystemNavigator.pop();
        exit(0);
      });
    } catch (e) {
      Log.e('重新安装 MaiBot 失败: $e', tag: 'MaiBot');
      Get.snackbar(
        '操作失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  /// 更新或重装 NapcatQQ：卸载 QQ 和 NapCat 并暂存配置
  static Future<void> reinstallNapcat() async {
    final confirm = await Get.dialog<bool>(
      AlertDialog(
        icon: const Icon(Icons.refresh_rounded, size: 28, color: Colors.orange),
        title: const Text('确认重新安装 NapCat'),
        content: const Text(
          '此操作将卸载 QQ 与 NapCat 并暂存当前配置。\n\n'
          '应用退出并重新打开后，将自动重新安装 NapCat 并恢复配置，确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('确定重装'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    Get.dialog(
      const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在暂存配置并清理 NapCat...', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
      barrierDismissible: false,
    );

    try {
      final success = await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: false,
        action: () async {
          return await InstallerService.prepareNapcatReinstall();
        },
      );

      if (Get.isDialogOpen == true) {
        Get.back();
      }

      if (success) {
        Get.snackbar(
          '清理完成',
          'NapCat 与 QQ 已卸载，应用即将退出，请重新打开以完成重装',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );

        Future.delayed(const Duration(seconds: 2), () async {
          await SystemNavigator.pop();
          exit(0);
        });
      } else {
        Get.snackbar(
          '操作失败',
          '准备重新安装失败，请查看运行日志',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
      }
    } catch (e) {
      if (Get.isDialogOpen == true) {
        Get.back();
      }
      Log.e('重新安装 NapCat 失败: $e', tag: 'MaiBot');
      Get.snackbar(
        '操作失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  /// 重置 Python 环境：删除虚拟环境后退出应用
  static Future<void> resetPythonEnv() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded, size: 28, color: Colors.orange),
        title: const Text('确认重置 Python 环境'),
        content: const Text(
          '此操作将删除 Python 虚拟环境并退出应用。\n'
          '下次启动时将自动重新配置环境与依赖。\n\n'
          '确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('确定重置'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: false,
        action: () async {
          final venvPath = '${scripts.ubuntuPath}/root/MaiBot/.venv';
          final venvDir = Directory(venvPath);
          if (await venvDir.exists()) {
            await Process.run(
              '${RuntimeEnvir.binPath}/busybox',
              ['rm', '-rf', venvPath, '${scripts.ubuntuPath}/root/MaiBot/.venv_sync_ready'],
            );
            Log.i('已删除 Python 虚拟环境: $venvPath', tag: 'MaiBot');
          }
        },
      );

      Get.snackbar(
        '重置完成',
        'Python 环境已删除，应用即将退出',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      Future.delayed(const Duration(seconds: 2), () async {
        await SystemNavigator.pop();
        exit(0);
      });
    } catch (e) {
      Log.e('删除 Python 虚拟环境失败: $e', tag: 'MaiBot');
      Get.snackbar(
        '操作失败',
        '删除虚拟环境失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
    }
  }

  /// 统一退出应用流程
  static Future<void> performExit({bool showConfirmation = true}) async {
    if (showConfirmation) {
      final confirm = await Get.dialog<bool>(
        AlertDialog(
          icon: const Icon(Icons.power_settings_new_rounded, size: 28, color: Colors.redAccent),
          title: const Text('确认退出应用'),
          content: const Text('退出应用将停止后台运行的服务与容器环境，确定要退出吗？'),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Get.back(result: true),
              child: const Text('退出应用'),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    Get.dialog(
      const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在停止后台服务并退出...', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
      barrierDismissible: false,
    );

    try {
      await BackendProcessManager.stopService();
    } catch (e) {
      Log.e('退出应用停止服务异常: $e', tag: 'MaiBot');
    }
    // 等待停止指令送达并处理
    await Future.delayed(const Duration(milliseconds: 300));
    await SystemNavigator.pop();
    exit(0);
  }
  /// 退出应用（设置页入口）
  static Future<void> exitApp() async {
    await performExit(showConfirmation: true);
  }
}
