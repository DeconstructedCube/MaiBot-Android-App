import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../../core/services/backend_process_manager.dart';
import '../../../../core/services/backup_service.dart';

/// 显示 Material You 风格的备份恢复选择对话框
Future<void> showBackupRestoreDialog({
  bool isInitialInstall = false,
  VoidCallback? onCompleted,
}) async {
  if (!isInitialInstall) {
    await BackupService.ensureStoragePermission();
  }

  final backups = await BackupService.getAvailableBackupsAsync();
  if (backups.isEmpty) {
    if (!isInitialInstall) {
      Get.snackbar(
        '未找到备份',
        '未在手机存储或应用备份目录中找到备份存档',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
    }
    onCompleted?.call();
    return;
  }

  int selectedBackupIndex = 0;
  bool restoreData = true;
  bool restoreConfig = true;
  bool restorePlugins = true;
  bool restoreNapcat = true;
  bool isRestoring = false;

  await Get.dialog(
    StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final currentFile = backups[selectedBackupIndex];
        return AlertDialog(
          backgroundColor: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.settings_backup_restore_rounded,
                  color: colorScheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isInitialInstall ? '检测到历史备份' : '恢复数据备份',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      isInitialInstall ? '是否恢复历史存档与配置？' : '选择要还原的存档与模块',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: isRestoring
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text('正在恢复选定模块数据...', style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择备份存档 (${backups.length} 个可用)',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: backups.length > 4 ? 4 : backups.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.3),
                            ),
                            itemBuilder: (context, idx) {
                              final f = backups[idx];
                              final isSelected = idx == selectedBackupIndex;
                              final isLatest = idx == 0;
                              final fStat = f.statSync();
                              final fDate =
                                  '${fStat.modified.month.toString().padLeft(2, '0')}-${fStat.modified.day.toString().padLeft(2, '0')} ${fStat.modified.hour.toString().padLeft(2, '0')}:${fStat.modified.minute.toString().padLeft(2, '0')}';
                              final fMB =
                                  (fStat.size / 1024 / 1024).toStringAsFixed(1);

                              return ListTile(
                                dense: true,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16)),
                                selected: isSelected,
                                selectedTileColor: colorScheme.secondaryContainer
                                    .withValues(alpha: 0.4),
                                leading: Icon(
                                  isSelected
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                  size: 20,
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        f.uri.pathSegments.last,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isLatest) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: colorScheme.primaryContainer,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '最新备份',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: colorScheme
                                                .onPrimaryContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  '$fDate · ${fMB}MB',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onTap: () =>
                                    setState(() => selectedBackupIndex = idx),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '选择要恢复的模块内容',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                final allSelected = restoreData &&
                                    restoreConfig &&
                                    restorePlugins &&
                                    restoreNapcat;
                                setState(() {
                                  restoreData = !allSelected;
                                  restoreConfig = !allSelected;
                                  restorePlugins = !allSelected;
                                  restoreNapcat = !allSelected;
                                });
                              },
                              style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                              child: Text(
                                (restoreData &&
                                        restoreConfig &&
                                        restorePlugins &&
                                        restoreNapcat)
                                    ? '取消全选'
                                    : '全选',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Container(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: Column(
                            children: [
                              CheckboxListTile(
                                dense: true,
                                title: const Text(
                                  '聊天记录与记忆库',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'MaiBot/data (SQLite 数据库、长期记忆、用户画像)',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: restoreData,
                                onChanged: (v) =>
                                    setState(() => restoreData = v ?? true),
                              ),
                              Divider(
                                height: 1,
                                color: colorScheme.outlineVariant
                                    .withValues(alpha: 0.3),
                              ),
                              CheckboxListTile(
                                dense: true,
                                title: const Text(
                                  '核心配置与密钥',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'MaiBot/config (bot.toml、模型 API Key、WebUI 令牌)',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: restoreConfig,
                                onChanged: (v) =>
                                    setState(() => restoreConfig = v ?? true),
                              ),
                              Divider(
                                height: 1,
                                color: colorScheme.outlineVariant
                                    .withValues(alpha: 0.3),
                              ),
                              CheckboxListTile(
                                dense: true,
                                title: const Text(
                                  '已装插件与适配器',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'MaiBot/plugins (NapCat 适配器与自定义插件)',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: restorePlugins,
                                onChanged: (v) =>
                                    setState(() => restorePlugins = v ?? true),
                              ),
                              Divider(
                                height: 1,
                                color: colorScheme.outlineVariant
                                    .withValues(alpha: 0.3),
                              ),
                              CheckboxListTile(
                                dense: true,
                                title: const Text(
                                  'NapCat QQ 账号配置',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'napcat/config (OneBot11 通信令牌与面板凭证)',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: restoreNapcat,
                                onChanged: (v) =>
                                    setState(() => restoreNapcat = v ?? true),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          actions: isRestoring
              ? null
              : [
                  TextButton(
                    onPressed: () {
                      Get.back();
                      onCompleted?.call();
                    },
                    child: Text(isInitialInstall ? '跳过 (全新初始化)' : '取消'),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('开始恢复'),
                    onPressed: () {
                      unawaited(() async {
                        setState(() => isRestoring = true);
                        final success =
                            await BackupService.performSelectiveRestore(
                          backupFile: currentFile,
                          restoreData: restoreData,
                          restoreConfig: restoreConfig,
                          restorePlugins: restorePlugins,
                          restoreNapcat: restoreNapcat,
                          restartService: isInitialInstall,
                          showSnackbar: false,
                        );
                        if (Get.isDialogOpen == true) {
                          Get.back();
                        }
                        if (success) {
                          if (!isInitialInstall) {
                            Get.snackbar(
                              '恢复成功',
                              '已成功还原数据与配置，应用即将退出，请重新打开',
                              snackPosition: SnackPosition.BOTTOM,
                              duration: const Duration(seconds: 3),
                            );
                            Future.delayed(const Duration(seconds: 2),
                                () async {
                              try {
                                await BackendProcessManager.stopService();
                              } catch (_) {}
                              await SystemNavigator.pop();
                              exit(0);
                            });
                          } else {
                            Get.snackbar(
                              '恢复成功',
                              '已成功还原选定的数据与配置模块',
                              snackPosition: SnackPosition.BOTTOM,
                              duration: const Duration(seconds: 3),
                            );
                          }
                        } else {
                          Get.snackbar(
                            '恢复失败',
                            '数据还原过程中发生错误',
                            snackPosition: SnackPosition.BOTTOM,
                            backgroundColor: Colors.red,
                            colorText: Colors.white,
                            duration: const Duration(seconds: 3),
                          );
                        }
                        onCompleted?.call();
                      }());
                    },
                  ),
                ],
        );
      },
    ),
    barrierDismissible: false,
  );
}
