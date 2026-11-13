import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
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

  final backups = await BackupService.getAvailableBackupEntriesAsync();
  if (backups.isEmpty && isInitialInstall) {
    onCompleted?.call();
    return;
  }

  int selectedBackupIndex = 0;
  bool restoreData = true;
  bool restoreConfig = true;
  bool restorePlugins = true;
  bool isRestoring = false;

  await Get.dialog(
    StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final currentFile = backups.isEmpty
            ? null
            : backups[selectedBackupIndex].file;
        return PopScope(
          canPop: !isRestoring,
          child: AlertDialog(
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
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '选择备份存档 (${backups.length} 个可用)',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.folder_open_rounded, size: 15),
                              label: const Text('从文件导入', style: TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () {
                                unawaited(() async {
                                  final picked = await FilePicker.pickFile(
                                    type: FileType.custom,
                                    allowedExtensions: ['gz', 'tgz'],
                                  );
                                  if (picked?.path != null) {
                                    final pickedFile = File(picked!.path!);
                                    final stat = await pickedFile.stat();
                                    if (context.mounted) {
                                      setState(() {
                                        backups.insert(
                                          0,
                                          BackupEntry(
                                            file: pickedFile,
                                            modified: stat.modified,
                                            sizeBytes: stat.size,
                                          ),
                                        );
                                        selectedBackupIndex = 0;
                                      });
                                    }
                                  }
                                }());
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (backups.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              '默认目录暂无备份存档，可点击右上角「从文件导入」选择外部 .tar.gz 备份包',
                              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                            ),
                          )
                        else
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
                              final entry = backups[idx];
                              final f = entry.file;
                              final isSelected = idx == selectedBackupIndex;
                              final isLatest = idx == 0;
                              final modified = entry.modified;
                              final fDate =
                                  '${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} ${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}';
                              final fMB =
                                  (entry.sizeBytes / 1024 / 1024).toStringAsFixed(1);

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
                                trailing: isInitialInstall
                                    ? null
                                    : IconButton(
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                          color: colorScheme.error,
                                        ),
                                        tooltip: '删除此备份',
                                        onPressed: () {
                                          unawaited(() async {
                                            try {
                                              if (await f.exists()) {
                                                await f.delete();
                                              }
                                              if (context.mounted) {
                                                setState(() {
                                                  backups.removeAt(idx);
                                                  if (backups.isEmpty) {
                                                    Navigator.of(context).pop();
                                                  } else if (selectedBackupIndex >= backups.length) {
                                                    selectedBackupIndex = backups.length - 1;
                                                  }
                                                });
                                              }
                                            } catch (e) {
                                              Get.snackbar(
                                                '删除失败',
                                                e.toString(),
                                                snackPosition: SnackPosition.BOTTOM,
                                              );
                                            }
                                          }());
                                        },
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
                                    restorePlugins;
                                setState(() {
                                  restoreData = !allSelected;
                                  restoreConfig = !allSelected;
                                  restorePlugins = !allSelected;
                                });
                              },
                              style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                              child: Text(
                                (restoreData &&
                                        restoreConfig &&
                                        restorePlugins)
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
                                  'MaiBot/data 目录',
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
                                  '核心配置与宿主凭据',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: const Text(
                                  'config 与 host 配置目录',
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
                                  'MaiBot/plugins 目录',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: restorePlugins,
                                onChanged: (v) =>
                                    setState(() => restorePlugins = v ?? true),
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
                      Navigator.of(context).pop();
                      onCompleted?.call();
                    },
                    child: Text(isInitialInstall ? '跳过' : '取消'),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('开始恢复'),
                    onPressed: currentFile == null
                        ? null
                        : () {
                            final navigator = Navigator.of(context);
                            unawaited(() async {
                              setState(() => isRestoring = true);
                              final success =
                                  await BackupService.performSelectiveRestore(
                                backupFile: currentFile,
                                restoreData: restoreData,
                                restoreConfig: restoreConfig,
                                restorePlugins: restorePlugins,
                                restartService: false,
                                showSnackbar: false,
                              );
                        if (navigator.mounted) {
                          navigator.pop();
                        } else if (Get.isDialogOpen == true) {
                          Get.back(canPop: false);
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
          ),
        );
      },
    ),
    barrierDismissible: false,
  );
}
