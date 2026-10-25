import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';

// 显示自定义 Git Clone 对话框
Future<void> showCustomGitCloneDialog() async {
  Setting customGitCloneSetting = 'custom_git_clone_url'.setting;
  String currentCommand = customGitCloneSetting.get() ?? '';

  // 显示编辑对话框
  final commandController = TextEditingController(text: currentCommand);

  final result = await Get.dialog<bool>(
    Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        return AlertDialog(
          icon: const Icon(Icons.code_rounded, size: 28),
          title: const Text('自定义 Git Clone 链接'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '自定义克隆仓库链接，以使用 fork 的 MaiBot 仓库。\n留空则使用默认逻辑（从镜像源获取官方最新版）。',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 8),
                Text(
                  '示例：\nhttps://github.com/Mai-with-u/MaiBot.git',
                  style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8), fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: commandController,
                  decoration: const InputDecoration(
                    labelText: 'Git Repository URL',
                    hintText: '留空使用默认官方逻辑',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                  maxLines: 2,
                  keyboardType: TextInputType.url,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Get.back(result: true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );

  if (result == true) {
    final newCommand = commandController.text.trim();

    try {
      customGitCloneSetting.set(newCommand);
      Log.i('已更新自定义 Git Clone 链接: $newCommand', tag: 'MaiBot');

      Get.snackbar(
        '保存成功',
        newCommand.isEmpty ? '已清除自定义链接，将使用默认逻辑' : '自定义仓库链接已保存',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '保存失败',
        '写入设置失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
      Log.e('保存自定义 Git Clone 失败: $e', tag: 'MaiBot');
    }
  }

  commandController.dispose();
}
