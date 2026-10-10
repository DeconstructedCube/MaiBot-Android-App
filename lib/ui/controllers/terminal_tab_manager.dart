import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:xterm/xterm.dart';

import '../../../core/services/proot_runner.dart';
import '../../../core/utils/file_utils.dart';

/// 终端标签页类型
enum TerminalTabType {
  fixed, // 固定的MaiBot/NapCat终端（只读）
  system, // 自定义交互终端（可写、可交互、可关闭）
}

/// 终端标签页数据模型
class TerminalTab {
  final String id;
  final String title;
  final TerminalTabType type;
  final Terminal terminal;
  bool isActive;
  final StreamSubscription? outputSubscription;
  final StreamSubscription? stderrSubscription;
  final Process? process;

  TerminalTab({
    required this.id,
    required this.title,
    required this.type,
    required this.terminal,
    this.isActive = false,
    this.outputSubscription,
    this.stderrSubscription,
    this.process,
  });

  void dispose() {
    outputSubscription?.cancel();
    stderrSubscription?.cancel();
    try {
      process?.stdin.close();
    } catch (_) {}
    try {
      process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }
}

/// 多终端标签页管理器
class TerminalTabManager extends GetxController {
  // 所有终端标签页列表
  final RxList<TerminalTab> tabs = <TerminalTab>[].obs;

  // 当前激活的标签页索引
  final RxInt activeTabIndex = 0.obs;


  /// 初始化固定的终端标签页
  void initializeFixedTabs(Terminal maibotTerminal, Terminal napcatTerminal) {
    // 清空现有标签页
    tabs.clear();

    // 添加固定的MaiBot终端标签页
    final maibotTab = TerminalTab(
      id: 'fixed_maibot',
      title: 'MaiBot',
      type: TerminalTabType.fixed,
      terminal: maibotTerminal,
      isActive: true,
    );

    // 添加固定的NapCat终端标签页
    final napcatTab = TerminalTab(
      id: 'fixed_napcat',
      title: 'NapCat',
      type: TerminalTabType.fixed,
      terminal: napcatTerminal,
      isActive: false,
    );

    tabs.add(maibotTab);
    tabs.add(napcatTab);
    activeTabIndex.value = 0;
  }


  /// 切换到指定标签页
  void switchToTab(int index) {
    if (index >= 0 && index < tabs.length) {
      // 将所有标签页设为非激活状态
      for (var tab in tabs) {
        tab.isActive = false;
      }

      // 激活指定标签页
      tabs[index].isActive = true;
      activeTabIndex.value = index;

      Log.i('切换到标签页: ${tabs[index].title} (索引: $index)', tag: 'TerminalTabManager');
    }
  }

  /// 关闭指定标签页
  void closeTab(int index) {
    if (index < 0 || index >= tabs.length) {
      return;
    }

    final tab = tabs[index];

    // 固定标签页不能关闭
    if (tab.type == TerminalTabType.fixed) {
      Get.snackbar('提示', 'MaiBot终端不能关闭');
      return;
    }

    try {
      tab.dispose();
      tabs.removeAt(index);

      if (index == activeTabIndex.value) {
        final newIndex = (index > 0) ? index - 1 : 0;
        if (tabs.isNotEmpty) {
          switchToTab(newIndex);
        }
      } else if (index < activeTabIndex.value) {
        activeTabIndex.value = activeTabIndex.value - 1;
      }

      Log.i('关闭标签页: ${tab.title}', tag: 'TerminalTabManager');
    } catch (e) {
      Log.e('关闭标签页失败: $e', tag: 'TerminalTabManager');
    }
  }

  /// 创建新的系统交互终端
  Future<void> createNewSystemTab() async {
    final newId = 'system_${DateTime.now().millisecondsSinceEpoch}';
    final newTitle = '终端 ${tabs.length + 1}';
    final newTerminal = Terminal(maxLines: 5000);
    final prootPath = '${RuntimeEnvir.binPath}/proot';
    final args = ProotRunner.buildProotArgs(isInteractive: true);
    final env = ProotRunner.getProotEnv();
    try {
      newTerminal.write('正在启动系统交互终端 (Ubuntu PRoot 环境)...\r\n\r\n');
      final process = await Process.start(prootPath, args, environment: env);

      newTerminal.onOutput = (data) {
        process.stdin.add(utf8.encode(data));
      };

      final subStdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        newTerminal.write(data.toTerminalCrlf());
      });
      final subStderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((data) {
        newTerminal.write(data.toTerminalCrlf());
      });

      process.exitCode.then((code) {
        Log.d('System tab process exited with code $code', tag: 'TerminalTabManager');
      });

      final newTab = TerminalTab(
        id: newId,
        title: newTitle,
        type: TerminalTabType.system,
        terminal: newTerminal,
        isActive: false,
        outputSubscription: subStdout,
        stderrSubscription: subStderr,
      );

      tabs.add(newTab);
      switchToTab(tabs.length - 1);
    } catch (e) {
      Log.e('创建系统终端失败: $e', tag: 'TerminalTabManager');
      Get.snackbar('创建失败', '无法拉起交互终端: $e', snackPosition: SnackPosition.BOTTOM);
    }
  }

  /// 获取当前激活的标签页
  TerminalTab? get activeTab {
    if (activeTabIndex.value >= 0 && activeTabIndex.value < tabs.length) {
      return tabs[activeTabIndex.value];
    }
    return null;
  }

  @override
  void onClose() {
    // 清理资源

    // 关闭所有系统终端的进程与订阅
    for (var tab in tabs) {
      if (tab.type == TerminalTabType.system) {
        try {
          tab.dispose();
        } catch (e) {
          Log.e('清理终端资源失败: $e', tag: 'TerminalTabManager');
        }
      }
    }
    super.onClose();
  }
}
