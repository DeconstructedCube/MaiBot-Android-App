import 'package:xterm/xterm.dart';
import '../utils/file_utils.dart';

/// 安装进度跟踪器（由 [AppLifecycleStateMachine] 归一化进度与描述驱动）
class ProgressTracker {
  ProgressTracker({
    required this.onChanged,
    this.onNapcatInstalled,
  });

  /// 进度变化时回调（通常为 GetX 的 update）
  final void Function() onChanged;

  /// NapCat 安装完成回调
  final void Function()? onNapcatInstalled;

  /// 总安装步骤数（兼容保留）
  final double step = 10.0;

  double progress = 0.0;
  String currentProgress = '';
  int _currentStepCount = 0;

  /// 需要被写入进度/清屏的终端（由控制器注入）
  Terminal? terminal;

  /// 直接同步来自状态机的精确归一化进度与描述
  void updateFromStateMachine(double normalizedProgress, String description) {
    final prevDescription = currentProgress;
    progress = normalizedProgress.clamp(0.0, 1.0);
    currentProgress = description;
    if (description.isNotEmpty && description != prevDescription) {
      terminal?.writeProgress(description);
    }
    onChanged();
  }

  /// 进度 +1（纯内存操作）
  void bump() {
    _currentStepCount++;
    progress = (_currentStepCount / step).clamp(0.0, 1.0);
    onChanged();
  }

  /// 重置状态
  void startWatching() {
    _currentStepCount = 0;
    progress = 0.0;
    currentProgress = '';
    onChanged();
  }

  /// 设置当前进度描述，同步到内存并向终端打印
  void setProgress(String description) {
    currentProgress = description;
    terminal?.writeProgress(currentProgress);

    if (description.contains('Napcat 已安装') || description.contains('Napcat Installed')) {
      bump();
      onNapcatInstalled?.call();
    }
    if (description.trim().contains('MaiBot Core 配置中')) {
      terminal?.buffer.clear();
      terminal?.buffer.setCursor(0, 0);
    }

    onChanged();
  }

  /// 释放资源
  void dispose() {
    terminal = null;
  }
}
