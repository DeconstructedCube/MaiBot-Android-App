import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../core/services/backend_process_manager.dart';
import '../../../../core/services/git_service.dart';

/// 统一执行 Git 操作并展示流式日志的弹窗
Future<bool> _runGitTaskWithProgressDialog({
  required String title,
  required Future<ProotExecResult> Function(Function(String) onLog) task,
}) async {
  final logs = <String>[].obs;
  final isDone = false.obs;
  final isSuccess = false.obs;
  final scrollController = ScrollController();

  void appendLog(String text) {
    logs.add(text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      }
    });
  }

  // 启动后台任务
  Future<void> execute() async {
    try {
      final res = await task(appendLog);
      isSuccess.value = res.success;
      if (res.success) {
        appendLog('\n操作已完成，正在重启 MaiBot 服务...\n');
        try {
          await BackendProcessManager.restartService(target: ServiceTarget.maibot);
          appendLog('MaiBot 服务已重启生效。\n');
        } catch (e) {
          appendLog('重启服务提示: $e\n');
        }
      } else {
        appendLog('\n❌ 执行失败 (Exit code: ${res.exitCode})\n${res.stderr}\n');
      }
    } catch (e) {
      isSuccess.value = false;
      appendLog('\n❌ 任务发生异常: $e\n');
    } finally {
      isDone.value = true;
    }
  }

  execute();

  final result = await Get.dialog<bool>(
    Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        return PopScope(
          canPop: false,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Obx(() {
                          if (!isDone.value) {
                            return const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            );
                          }
                          return Icon(
                            isSuccess.value ? Icons.check_circle_rounded : Icons.error_rounded,
                            color: isSuccess.value ? Colors.green : Colors.red,
                            size: 24,
                          );
                        }),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Obx(
                          () => SingleChildScrollView(
                            controller: scrollController,
                            child: SelectableText(
                              logs.isEmpty ? '正在准备运行环境...' : logs.join(''),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Obx(() {
                      if (!isDone.value) {
                        return const SizedBox(
                          width: double.infinity,
                          child: Center(
                            child: Text(
                              '正在执行，请勿关闭应用...',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        );
                      }
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!isSuccess.value)
                            TextButton(
                              onPressed: () => Get.back(result: false),
                              child: const Text('关闭'),
                            ),
                          if (isSuccess.value)
                            FilledButton.icon(
                              onPressed: () => Get.back(result: true),
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('完成'),
                            ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
    barrierDismissible: false,
  );

  return result ?? false;
}

/// 弹出更新 MaiBot 对话框 (git pull)
Future<void> showUpdateMaiBotDialog() async {
  if (!GitService.isMaiBotGitRepo()) {
    Get.snackbar(
      '提示',
      '未检测到 MaiBot Git 仓库，请先完成初始安装',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.orange,
      colorText: Colors.white,
    );
    return;
  }

  final confirm = await Get.dialog<bool>(
    AlertDialog(
      icon: const Icon(Icons.cloud_sync_rounded, size: 28, color: Colors.blue),
      title: const Text('更新 MaiBot'),
      content: const Text(
        '将执行 git pull 拉取当前分支的最新提交，并自动同步更新 Python 依赖库。\n\n'
        '数据目录已在 .gitignore 中忽略，更新不会影响您的本地配置与数据。\n\n'
        '确定要检查并更新吗？',
        style: TextStyle(fontSize: 13, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Get.back(result: true),
          child: const Text('开始更新'),
        ),
      ],
    ),
  );

  if (confirm == true) {
    await _runGitTaskWithProgressDialog(
      title: '更新 MaiBot',
      task: (onLog) => GitService.pullMaiBot(onLog: onLog),
    );
  }
}

/// 弹出切换分支对话框 (内置异步加载，杜绝路由跳转/退栈冲突)
Future<void> showSwitchBranchDialog() async {
  if (!GitService.isMaiBotGitRepo()) {
    Get.snackbar(
      '提示',
      '未检测到 MaiBot Git 仓库',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.orange,
      colorText: Colors.white,
    );
    return;
  }

  String currentRef = 'main';
  List<String> branches = ['main', 'master', 'dev'];
  bool isLoading = true;
  bool hasRequested = false;
  String selectedBranch = 'main';
  final customBranchController = TextEditingController();

  final choice = await Get.dialog<String>(
    StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        if (!hasRequested) {
          hasRequested = true;
          GitService.getCurrentRef().then((ref) {
            currentRef = ref;
            selectedBranch = ref;
            return GitService.getAvailableBranches();
          }).then((fetchedBranches) {
            if (context.mounted) {
              setState(() {
                if (fetchedBranches.isNotEmpty) {
                  branches = fetchedBranches;
                  if (branches.contains(currentRef)) {
                    selectedBranch = currentRef;
                  } else if (branches.isNotEmpty) {
                    selectedBranch = branches.first;
                  }
                }
                isLoading = false;
              });
            }
          }).catchError((_) {
            if (context.mounted) {
              setState(() {
                isLoading = false;
              });
            }
          });
        }

        return AlertDialog(
          icon: const Icon(Icons.alt_route_rounded, size: 28, color: Colors.teal),
          title: const Text('切换 MaiBot 分支'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded, size: 16, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '当前处于: $currentRef',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '从当前 Git 远程仓库动态获取，兼容自定义 Fork 仓库。切换分支后将自动同步依赖：',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.3),
                  ),
                  const SizedBox(height: 10),
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '正在查询远端分支列表...',
                              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    ...branches.map((branch) {
                      final isCurrent = branch == currentRef;
                      final isSelected = branch == selectedBranch;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        title: Text(
                          branch + (isCurrent ? ' (当前)' : ''),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            selectedBranch = branch;
                            customBranchController.clear();
                          });
                        },
                      );
                    }),
                    const SizedBox(height: 8),
                    TextField(
                      controller: customBranchController,
                       decoration: const InputDecoration(
                        labelText: '或输入其他分支名',
                        hintText: '例如: feat/new-adapter',
                        prefixIcon: Icon(Icons.edit_road_rounded, size: 20),
                        isDense: true,
                      ),
                      onChanged: (val) {
                        if (val.trim().isNotEmpty) {
                          setState(() {
                            selectedBranch = val.trim();
                          });
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final target = customBranchController.text.trim().isNotEmpty
                    ? customBranchController.text.trim()
                    : selectedBranch;
                Navigator.of(context).pop(target);
              },
              child: const Text('确定切换'),
            ),
          ],
        );
      },
    ),
  );

  if (choice != null && choice.isNotEmpty) {
    await _runGitTaskWithProgressDialog(
      title: '切换分支: $choice',
      task: (onLog) => GitService.switchBranch(choice, onLog: onLog),
    );
  }
}

/// 弹出切换 Release 版本对话框 (内置异步加载，杜绝路由跳转/退栈冲突)
Future<void> showSwitchReleaseTagDialog() async {
  if (!GitService.isMaiBotGitRepo()) {
    Get.snackbar(
      '提示',
      '未检测到 MaiBot Git 仓库',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.orange,
      colorText: Colors.white,
    );
    return;
  }

  String currentRef = '';
  List<String> tags = [];
  bool isLoading = true;
  bool hasRequested = false;
  String selectedTag = '';

  final choice = await Get.dialog<String>(
    StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        if (!hasRequested) {
          hasRequested = true;
          GitService.getCurrentRef().then((ref) {
            currentRef = ref;
            return GitService.getReleaseTags();
          }).then((fetchedTags) {
            if (context.mounted) {
              setState(() {
                tags = fetchedTags;
                if (tags.isNotEmpty) {
                  selectedTag = tags.first;
                }
                isLoading = false;
              });
            }
          }).catchError((_) {
            if (context.mounted) {
              setState(() {
                isLoading = false;
              });
            }
          });
        }

        return AlertDialog(
          icon: const Icon(Icons.sell_rounded, size: 28, color: Colors.purple),
          title: const Text('切换 MaiBot Release 版本'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 440),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '提示：切换版本将检出对应 Release Tag。当前状态: $currentRef',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurface,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '选择要检出的 Release 版本：',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '正在查询远端 Release Tags...',
                              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (tags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text(
                          '当前未检索到任何 Release Tag 标签',
                          style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    ...tags.map((tag) {
                      final isCurrent = tag == currentRef;
                      final isSelected = tag == selectedTag;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        title: Text(
                          tag + (isCurrent ? ' (当前)' : ''),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            selectedTag = tag;
                          });
                        },
                      );
                    }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            if (!isLoading && tags.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(selectedTag),
                child: const Text('确定检出'),
              ),
          ],
        );
      },
    ),
  );

  if (choice != null && choice.isNotEmpty) {
    await _runGitTaskWithProgressDialog(
      title: '检出版本: $choice',
      task: (onLog) => GitService.switchReleaseTag(choice, onLog: onLog),
    );
  }
}
