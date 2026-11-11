import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/home_controller.dart';

class WebViewBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;

  const WebViewBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final HomeController homeController = Get.find<HomeController>();

    // 使用 Obx 来响应式监听变化
    return Obx(() {
      // 获取自定义 WebView 列表
      final customWebViews = homeController.webviewController.customWebViews;

      // 动态构建导航栏项目
      final List<NavigationDestination> destinations = [
        const NavigationDestination(
          icon: Icon(Icons.smart_toy_outlined),
          selectedIcon: Icon(Icons.smart_toy_rounded),
          label: 'MaiBot',
        ),
        // 添加自定义 WebView 项
        ...customWebViews.map((webview) => NavigationDestination(
              icon: const Icon(Icons.language_outlined),
              selectedIcon: const Icon(Icons.language_rounded),
              label: webview['title'] ?? 'WebUI',
            )),
        const NavigationDestination(
          icon: Icon(Icons.terminal_outlined),
          selectedIcon: Icon(Icons.terminal_rounded),
          label: '终端',
        ),
        const NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: '设置',
        ),
      ];
      final int selectedIndex = currentIndex.clamp(0, destinations.length - 1);

      final theme = Theme.of(context);

      return Container(
        decoration: BoxDecoration(
          color: theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surfaceContainer,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
        ),
        child: NavigationBar(
          height: 66,
          selectedIndex: selectedIndex,
          onDestinationSelected: onTap,
          destinations: destinations,
        ),
      );
    });
  }
}
