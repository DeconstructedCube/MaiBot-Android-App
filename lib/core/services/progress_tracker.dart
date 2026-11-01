import 'package:xterm/xterm.dart';
import '../utils/file_utils.dart';

/// 安装进度跟踪器（由 [AppLifecycleStateMachine] 归一化进度与描述驱动）
class ProgressTracker {
  ProgressTracker({
    required this.onChanged,
  });

  /// 进度变化时回调（通常为 GetX 的 update）
  final void Function() onChanged;

  double progress = 0.0;
  String currentProgress = '';

  /// 需要被写入进度/清屏的终端（由控制器注入）
  Terminal? terminal;

  /// 直接同步来自状态机的精确归一化进度与描述
  void updateFromStateMachine(double normalizedProgress, String description) {
    final prevDescription = currentProgress;
    progress = normalizedProgress.clamp(0.0, 1.0);
    currentProgress = description;
    if (description.isNotEmpty &&
        description != prevDescription &&
        !description.contains('%') &&
        !description.contains('已释放')) {
      terminal?.writeProgress(description);
    }
    onChanged();
  }

  /// 释放资源
  void dispose() {
    terminal = null;
  }
}
