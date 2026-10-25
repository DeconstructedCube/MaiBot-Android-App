import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../controllers/home_controller.dart';
import '../dialogs/webview_crud_dialogs.dart';

/// 设置页：控制面板开关、登录 Token 管理与自定义 WebView 面板列表卡片
class TokenAndWebviewCard extends StatelessWidget {
  final HomeController homeController;

  const TokenAndWebviewCard({
    super.key,
    required this.homeController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: theme.cardTheme.color ?? colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: colorScheme.outlineVariant
              .withValues(alpha: isDark ? 0.35 : 0.45),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            final enabled =
                homeController.napcatController.napCatWebUiEnabledRx.value;
            return SwitchListTile(
              secondary: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.web_rounded,
                  color: Colors.teal,
                  size: 22,
                ),
              ),
              title: const Text(
                'NapCat 控制面板',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              subtitle: Text(
                enabled
                    ? '已开启：可在底部导航栏访问 NapCat 控制台'
                    : '已关闭：底部导航栏不显示 NapCat 面板',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              value: enabled,
              onChanged: (bool value) {
                homeController.napcatController.setNapCatWebUiEnabled(value);
                Get.snackbar(
                  value ? 'WebUI 已启用' : 'WebUI 已禁用',
                  value ? 'NapCat 标签页已显示，可直接访问控制面板' : 'NapCat 标签页已隐藏',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 2),
                );
              },
            );
          }),
          const Divider(height: 1, indent: 56),
          Obx(() {
            final token =
                homeController.napcatController.maiBotWebUiToken.value;
            return _buildTokenTile(
              context: context,
              icon: Icons.key_rounded,
              iconColor: Colors.purple,
              title: 'MaiBot 登录 Token',
              token: token,
            );
          }),
          const Divider(height: 1, indent: 56),
          Obx(() {
            final token =
                homeController.napcatController.napCatWebUiToken.value;
            return _buildTokenTile(
              context: context,
              icon: Icons.vpn_key_rounded,
              iconColor: Colors.deepPurple,
              title: 'NapCat 登录 Token',
              token: token,
            );
          }),
          const Divider(height: 1, indent: 56),
          _buildCustomWebViewsSection(context),
        ],
      ),
    );
  }

  Widget _buildTokenTile({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String token,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final bool hasToken = token.isNotEmpty;
    final String tokenDisplay =
        token.length > 20 ? '${token.substring(0, 16)}••••' : token;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        hasToken ? tokenDisplay : '暂未捕获到 Token',
        style: TextStyle(
          fontSize: 12,
          color: hasToken
              ? colorScheme.onSurface
              : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          fontFamily: hasToken ? 'monospace' : null,
        ),
      ),
      trailing: hasToken
          ? OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.copy_rounded, size: 14),
              label: const Text('复制', style: TextStyle(fontSize: 12)),
              onPressed: () => _copyToken(title, token),
            )
          : null,
      onTap: hasToken ? () => _copyToken(title, token) : null,
    );
  }

  void _copyToken(String title, String token) {
    unawaited(() async {
      await Clipboard.setData(ClipboardData(text: token));
      Get.snackbar(
        '已复制',
        '$title 已复制到剪贴板',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }());
  }

  Widget _buildCustomWebViewsSection(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Obx(() {
      final customWebViews = homeController.webviewController.customWebViews;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.language_rounded,
                    color: Colors.blue,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '自定义 WebView 面板',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                  onPressed: () =>
                      showAddWebViewDialog(homeController.webviewController),
                ),
              ],
            ),
          ),
          if (customWebViews.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                '可添加外部插件的 Web 控制面板并显示在底部导航栏',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            )
          else
            ...List.generate(customWebViews.length, (index) {
              final webview = customWebViews[index];
              return Column(
                children: [
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                    title: Text(
                      webview['title'] ?? 'WebUI',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      webview['url'] ?? '',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.edit_rounded,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () => showEditWebViewDialog(
                            homeController.webviewController,
                            index,
                            webview,
                          ),
                          tooltip: '编辑',
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: colorScheme.error,
                          ),
                          onPressed: () => showConfirmDeleteWebView(
                            homeController.webviewController,
                            index,
                            webview['title'] ?? 'WebUI',
                          ),
                          tooltip: '删除',
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
        ],
      );
    });
  }
}
