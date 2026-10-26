import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../core/config/app_config.dart';
import '../../../controllers/webview_controller.dart';

// 显示添加自定义 WebView 对话框
Future<void> showAddWebViewDialog(WebviewController controller) async {
  final titleController = TextEditingController();
  final urlController = TextEditingController();

  await Get.dialog(
    AlertDialog(
      icon: const Icon(Icons.add_link_rounded, size: 28),
      title: const Text('添加自定义 WebView'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: titleController,
            decoration: const InputDecoration(
              labelText: '面板标题',
              hintText: '例如：我的仪表盘',
              prefixIcon: Icon(Icons.title_rounded),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: urlController,
            decoration: InputDecoration(
              labelText: 'URL 地址',
              hintText: '例如：${Ports.napcatWebUi}/webui?token=***',
              helperText: '默认自动补全 http://127.0.0.1:',
              prefixIcon: const Icon(Icons.link_rounded),
            ),
            keyboardType: TextInputType.url,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final title = titleController.text.trim();
            var url = urlController.text.trim();

            if (title.isEmpty || url.isEmpty) {
              Get.snackbar(
                '输入错误',
                '标题和 URL 不能为空',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: Colors.orange,
                colorText: Colors.white,
              );
              return;
            }
            // 如果URL不包含协议前缀,自动添加 http://127.0.0.1:
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              url = 'http://127.0.0.1:$url';
            }

            final parsedUri = Uri.tryParse(url);
            if (parsedUri == null || (parsedUri.scheme != 'http' && parsedUri.scheme != 'https')) {
              Get.snackbar(
                'URL 格式无效',
                '请输入有效的 http 或 https 地址',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: Colors.orange,
                colorText: Colors.white,
              );
              return;
            }
            controller.addCustomWebView(title, url);
            Get.back();

            Get.snackbar(
              '添加成功',
              '自定义 WebView "$title" 已添加',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
          },
          child: const Text('添加'),
        ),
      ],
    ),
  );
  titleController.dispose();
  urlController.dispose();
}

// 显示编辑自定义 WebView 对话框
Future<void> showEditWebViewDialog(
    WebviewController controller, int index, Map<String, String> webview) async {
  final titleController = TextEditingController(text: webview['title']);

  // 将完整URL转换为简化格式用于编辑
  String displayUrl = webview['url'] ?? '';
  if (displayUrl.startsWith('https://127.0.0.1:')) {
    displayUrl = displayUrl.substring('https://127.0.0.1:'.length);
  } else if (displayUrl.startsWith('http://127.0.0.1:')) {
    displayUrl = displayUrl.substring('http://127.0.0.1:'.length);
  }

  final urlController = TextEditingController(text: displayUrl);

  await Get.dialog(
    AlertDialog(
      icon: const Icon(Icons.edit_rounded, size: 28),
      title: const Text('编辑自定义 WebView'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: titleController,
            decoration: const InputDecoration(
              labelText: '面板标题',
              prefixIcon: Icon(Icons.title_rounded),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: urlController,
            decoration: const InputDecoration(
              labelText: 'URL 地址',
              helperText: '默认自动补全 http://127.0.0.1:',
              prefixIcon: Icon(Icons.link_rounded),
            ),
            keyboardType: TextInputType.url,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final title = titleController.text.trim();
            var url = urlController.text.trim();

            if (title.isEmpty || url.isEmpty) {
              Get.snackbar(
                '输入错误',
                '标题和 URL 不能为空',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: Colors.orange,
                colorText: Colors.white,
              );
              return;
            }
            // 如果URL不包含协议前缀,自动添加 http://127.0.0.1:
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              url = 'http://127.0.0.1:$url';
            }

            final parsedUri = Uri.tryParse(url);
            if (parsedUri == null || (parsedUri.scheme != 'http' && parsedUri.scheme != 'https')) {
              Get.snackbar(
                'URL 格式无效',
                '请输入有效的 http 或 https 地址',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: Colors.orange,
                colorText: Colors.white,
              );
              return;
            }
            controller.updateCustomWebView(index, title, url);
            Get.back();

            Get.snackbar(
              '更新成功',
              '自定义 WebView 已更新',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  titleController.dispose();
  urlController.dispose();
}

// 确认删除自定义 WebView
void showConfirmDeleteWebView(
    WebviewController controller, int index, String title) {
  Get.dialog(
    AlertDialog(
      icon: const Icon(Icons.delete_outline_rounded, size: 28, color: Colors.red),
      title: const Text('确认删除'),
      content: Text('确定要删除自定义 WebView "$title" 吗？'),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            controller.removeCustomWebView(index);
            Get.back();

            Get.snackbar(
              '删除成功',
              '自定义 WebView "$title" 已删除',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
          },
          child: const Text('删除'),
        ),
      ],
    ),
  );
}
