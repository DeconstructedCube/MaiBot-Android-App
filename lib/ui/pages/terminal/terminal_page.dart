import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:xterm/xterm.dart';
import '../../../core/utils/file_utils.dart';

import '../../controllers/home_controller.dart';
import 'terminal_theme.dart';

/// MaiBot 启动加载与初始终端监视页面
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final HomeController controller = Get.find<HomeController>();

  // 0: 看板模式, 1: MaiBot 终端
  int _displayMode = 0;
  DateTime? _lastBackPressTime;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _displayMode = 1;
    }
  }

  void _cycleNextMode() {
    setState(() {
      _displayMode = _displayMode == 0 ? 1 : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isTerminalVisible = _displayMode != 0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_displayMode != 0) {
          setState(() {
            _displayMode = 0;
          });
          return;
        }

        final now = DateTime.now();
        if (_lastBackPressTime == null ||
            now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          Get.snackbar(
            '提示',
            '再次按返回键退出应用',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 2),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          );
          return;
        }

        SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: SafeArea(
          child: GestureDetector(
            onTap: isTerminalVisible ? null : _cycleNextMode,
            behavior: HitTestBehavior.translucent,
            child: Stack(
              children: [
                // 1. 终端视图层
                if (isTerminalVisible)
                  Positioned.fill(
                    child: Column(
                      children: [
                        // 顶栏控制条
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                              Flexible(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SegmentedButton<int>(
                                    showSelectedIcon: false,
                                    segments: [
                                      const ButtonSegment<int>(
                                        value: 0,
                                        icon: Icon(Icons.dashboard_rounded, size: 15),
                                        label: Text('看板', style: TextStyle(fontSize: 12)),
                                      ),
                                      const ButtonSegment<int>(
                                        value: 1,
                                        icon: Icon(Icons.smart_toy_rounded, size: 15),
                                        label: Text('MaiBot', style: TextStyle(fontSize: 12)),
                                      ),
                                    ],
                                    selected: {_displayMode},
                                    onSelectionChanged: (Set<int> newSelection) {
                                      setState(() {
                                        _displayMode = newSelection.first;
                                      });
                                    },
                                    style: const ButtonStyle(
                                      visualDensity: VisualDensity.compact,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                padding: const EdgeInsets.all(6),
                                icon: Icon(Icons.copy_all_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                                tooltip: '复制日志',
                                onPressed: () {
                                  unawaited(() async {
                                    final text = controller.terminal.getPlainText();
                                    if (text.isNotEmpty) {
                                      await Clipboard.setData(ClipboardData(text: text));
                                      Get.snackbar(
                                        '已复制',
                                        'MaiBot 终端内容已复制到剪贴板',
                                        snackPosition: SnackPosition.BOTTOM,
                                        duration: const Duration(seconds: 2),
                                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      );
                                    }
                                  }());
                                },
                              ),
                              IconButton(
                                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                padding: const EdgeInsets.all(6),
                                icon: Icon(Icons.cleaning_services_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                                tooltip: '清屏',
                                onPressed: () {
                                  controller.terminal.buffer.clear();
                                  controller.terminal.buffer.setCursor(0, 0);
                                },
                              ),
                              IconButton(
                                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                padding: const EdgeInsets.all(6),
                                icon: Icon(Icons.close_fullscreen_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                                tooltip: '返回看板',
                                onPressed: () {
                                  setState(() {
                                    _displayMode = 0;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Container(
                            color: getAppTerminalTheme(context).background,
                            padding: const EdgeInsets.all(8.0),
                            child: TerminalView(
                              controller.terminal,
                              readOnly: true,
                              backgroundOpacity: 1,
                              theme: getAppTerminalTheme(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 2. 形态 0: 核心看板
                if (!isTerminalVisible)
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 92,
                              height: 92,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    colorScheme.primaryContainer,
                                    colorScheme.secondaryContainer,
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(28),
                                boxShadow: [
                                  BoxShadow(
                                    color: colorScheme.primary.withValues(alpha: 0.18),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.smart_toy_rounded,
                                size: 48,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: 24),

                            // 标题与副标题
                            Text(
                              'MaiBot',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.3,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '正在启动后台服务',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                letterSpacing: 0.1,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 32),

                            // 进度展示卡片
                            GetBuilder<HomeController>(
                              builder: (ctrl) {
                                final progressVal = ctrl.progress.clamp(0.0, 1.0);
                                final pct = (progressVal * 100).toInt();
                                final stepText = ctrl.currentProgress.isNotEmpty
                                    ? ctrl.currentProgress.trim()
                                    : '准备环境中...';

                                return Container(
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                                      width: 1,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            pct >= 100 ? Icons.check_circle_rounded : Icons.sync_rounded,
                                            size: 18,
                                            color: colorScheme.primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              stepText,
                                              style: theme.textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w600,
                                                color: colorScheme.onSurface,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primaryContainer,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              '$pct%',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: colorScheme.onPrimaryContainer,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 14),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: LinearProgressIndicator(
                                          value: progressVal > 0 ? progressVal : null,
                                          minHeight: 8,
                                          backgroundColor: colorScheme.surfaceContainerHighest,
                                          valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 28),

                            // 终端日志切换操作组
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    setState(() {
                                      _displayMode = 1;
                                    });
                                  },
                                  icon: const Icon(Icons.terminal_rounded, size: 18),
                                  label: const Text('MaiBot 日志'),
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '点击空白处切换终端',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
