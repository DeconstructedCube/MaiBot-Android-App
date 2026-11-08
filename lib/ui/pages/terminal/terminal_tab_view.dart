import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:xterm/xterm.dart';

import '../../../core/utils/file_utils.dart';
import '../../controllers/home_controller.dart';
import '../../controllers/terminal_tab_manager.dart';
import 'terminal_theme.dart';
import 'widgets/terminal_extra_keys_bar.dart';
class TerminalTabView extends StatefulWidget {
  const TerminalTabView({super.key});

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  final HomeController homeController = Get.find<HomeController>();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final manager = homeController.terminalTabManager;
      final tabs = manager.tabs;
      final activeIndex = manager.activeTabIndex.value;

      if (tabs.isEmpty) {
        final theme = Theme.of(context);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(Icons.terminal_rounded, size: 40, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text(
                '暂无运行中的终端',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => manager.createNewSystemTab(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建终端'),
              ),
            ],
          ),
        );
      }

      return Column(
        children: [
          // 标签页头部
          _buildTabBar(tabs, activeIndex, manager),

          // 终端内容区域
          Expanded(
            child: IndexedStack(
              index: activeIndex,
              children: tabs.map((tab) {
                return _buildTerminalContent(tab);
              }).toList(),
            ),
          ),

          // Termux 同款快捷按键底边栏（ESC, TAB, CTRL, ALT, 方向键等）
          TerminalExtraKeysBar(manager: manager),
        ],
      );
    });
  }

  /// 构建标签页栏
  Widget _buildTabBar(
    List<TerminalTab> tabs,
    int activeIndex,
    TerminalTabManager manager,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // 标签页列表（可滚动）
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                return _buildTabItem(
                  tab: tabs[index],
                  isActive: index == activeIndex,
                  onTap: () => manager.switchToTab(index),
                  onClose: tabs[index].type == TerminalTabType.system
                      ? () => _showCloseConfirmDialog(index, manager)
                      : null,
                );
              },
            ),
          ),
          IconButton(
            icon: Icon(Icons.add_rounded, size: 20, color: colorScheme.onSurfaceVariant),
            tooltip: '新建终端',
            onPressed: () => manager.createNewSystemTab(),
          ),
          IconButton(
            icon: Icon(Icons.copy_all_rounded, size: 19, color: colorScheme.onSurfaceVariant),
            tooltip: '复制终端内容',
            onPressed: () {
              unawaited(() async {
                final activeTab = manager.activeTab;
                if (activeTab != null) {
                  final text = activeTab.terminal.getPlainText();
                  if (text.isNotEmpty) {
                    await Clipboard.setData(ClipboardData(text: text));
                    Get.snackbar(
                      '已复制',
                      '${activeTab.title} 终端内容已复制到剪贴板',
                      snackPosition: SnackPosition.BOTTOM,
                      duration: const Duration(seconds: 2),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    );
                  } else {
                    Get.snackbar(
                      '提示',
                      '当前终端无内容',
                      snackPosition: SnackPosition.BOTTOM,
                      duration: const Duration(seconds: 2),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    );
                  }
                }
              }());
            },
          ),
          IconButton(
            icon: Icon(Icons.save_alt_rounded, size: 19, color: colorScheme.onSurfaceVariant),
            tooltip: '保存日志文件',
            onPressed: () {
              unawaited(() async {
                final activeTab = manager.activeTab;
                if (activeTab != null) {
                  final text = activeTab.terminal.getPlainText();
                  try {
                    final dir = getMaiBotBackupDirectory();
                    final now = DateTime.now();
                    final timestamp =
                        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
                    final logFile = File('${dir.path}/terminal_${activeTab.id}_$timestamp.log');
                    await logFile.writeAsString(text);
                    Get.snackbar(
                      '保存成功',
                      '日志已导出至: ${logFile.path}',
                      snackPosition: SnackPosition.BOTTOM,
                      duration: const Duration(seconds: 3),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    );
                  } catch (e) {
                    Get.snackbar(
                      '保存失败',
                      '写入日志文件异常: $e',
                      snackPosition: SnackPosition.BOTTOM,
                      backgroundColor: Colors.red,
                      colorText: Colors.white,
                      duration: const Duration(seconds: 3),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    );
                  }
                }
              }());
            },
          ),
          IconButton(
            icon: Icon(Icons.cleaning_services_rounded, size: 19, color: colorScheme.onSurfaceVariant),
            tooltip: '清屏',
            onPressed: () {
              final activeTab = manager.activeTab;
              if (activeTab != null) {
                activeTab.terminal.buffer.clear();
                activeTab.terminal.buffer.setCursor(0, 0);
              }
            },
          ),
        ],
      ),
    );
  }


  /// 构建单个标签页项
  Widget _buildTabItem({
    required TerminalTab tab,
    required bool isActive,
    required VoidCallback onTap,
    VoidCallback? onClose,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final activeBg = colorScheme.secondaryContainer;
    final activeFg = colorScheme.onSecondaryContainer;
    final inactiveFg = colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: isActive ? activeBg : colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive ? colorScheme.primary.withValues(alpha: 0.25) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标签页图标
              Icon(
                tab.type == TerminalTabType.fixed
                    ? Icons.lock_outline_rounded
                    : Icons.terminal_rounded,
                size: 14,
                color: isActive ? activeFg : inactiveFg,
              ),
              const SizedBox(width: 6),

              // 标签页标题
              Flexible(
                child: Text(
                  tab.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    color: isActive ? activeFg : inactiveFg,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // 关闭按钮（只有系统终端才显示）
              if (onClose != null) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: isActive ? activeFg : inactiveFg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 构建终端内容
  Widget _buildTerminalContent(TerminalTab tab) {
    return ClipRect(
      child: TerminalView(
        tab.terminal,
        readOnly: tab.type == TerminalTabType.fixed,
        backgroundOpacity: 1,
        theme: getAppTerminalTheme(context),
      ),
    );
  }

  /// 显示关闭确认对话框
  void _showCloseConfirmDialog(int index, TerminalTabManager manager) {
    Get.dialog(
      AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 28),
        title: const Text('确认关闭终端'),
        content: const Text('关闭该系统终端将终止其正在运行的进程，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Get.back();
              manager.closeTab(index);
            },
            child: const Text('确定关闭'),
          ),
        ],
      ),
    );
  }
}
