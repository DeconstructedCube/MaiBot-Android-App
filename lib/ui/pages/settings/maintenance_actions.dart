import 'dart:async';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../../core/utils/app_dialog.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/utils/runtime_envir.dart';

import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/services/backend_process_manager.dart';
import '../../../core/services/backup_service.dart';

/// 设置页中的维护与重置操作（重装/清理/退出）
class MaintenanceActions {
  /// 更新或重装 MaiBot：删除 MaiBot 目录后退出应用
  static Future<void> reinstallMaiBot() async {
    // 询问是否需要备份
    final backupChoice = await showAppDialog<String>(
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 28, color: Colors.orange),
        title: const Text('重新安装 MaiBot'),
        content: const Text('重新安装将删除当前 MaiBot 的程序与数据。\n是否需要在重装前备份数据？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop('cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogCtx).pop('no_backup'),
            child: const Text('直接重装'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop('backup'),
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
        final continueAnyway = await showAppDialog<bool>(
          builder: (dialogCtx) => AlertDialog(
            title: const Text('备份未完成'),
            content: const Text('数据备份失败，是否仍要继续重新安装？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(true),
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
    final finalConfirm = await showAppDialog<bool>(
      builder: (dialogCtx) => AlertDialog(
        title: const Text('确认重新安装'),
        content: const Text('确定要删除 MaiBot 并重新安装吗？\n未备份的数据将无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
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
        await BackendProcessManager.stopService();
        await SystemNavigator.pop();
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


  /// 重置 Python 环境：删除虚拟环境后退出应用
  static Future<void> resetPythonEnv() async {
    final confirmed = await showAppDialog<bool>(
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded, size: 28, color: Colors.orange),
        title: const Text('确认重置 Python 环境'),
        content: const Text(
          '此操作将删除 Python 虚拟环境并退出应用。\n'
          '下次启动时将自动重新配置环境与依赖。\n\n'
          '确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
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
        await BackendProcessManager.stopService();
        await SystemNavigator.pop();
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
      final confirm = await showAppDialog<bool>(
        builder: (dialogCtx) => AlertDialog(
          icon: const Icon(Icons.power_settings_new_rounded, size: 28, color: Colors.redAccent),
          title: const Text('确认退出应用'),
          content: const Text('退出应用将停止后台运行的服务与容器环境，确定要退出吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('退出应用'),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    BuildContext? loadingCtx;
    unawaited(
      showAppDialog<void>(
        barrierDismissible: false,
        builder: (ctx) {
          loadingCtx = ctx;
          return const PopScope(
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
          );
        },
      ),
    );

    try {
      await const MethodChannel('maibot_channel').invokeMethod('exit_app');
    } catch (e) {
      Log.e('exit_app 原生退出异常，降级停止服务: $e', tag: 'MaiBot');
      try {
        await BackendProcessManager.stopService();
      } catch (_) {}
      final ctx = loadingCtx;
      if (ctx != null && ctx.mounted) {
        Navigator.of(ctx).pop();
      }
      await SystemNavigator.pop();
    }
  }

  /// 退出应用（设置页入口）
  static Future<void> exitApp() async {
    await performExit(showConfirmation: true);
  }
}
