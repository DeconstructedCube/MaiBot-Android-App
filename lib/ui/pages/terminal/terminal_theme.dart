import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

/// 根据当前 Material 3 主题动态生成终端色彩配置（统一采用深色/纯黑沉浸画布，杜绝亮白刺眼）
TerminalTheme getAppTerminalTheme(BuildContext context) {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;

  // 终端统一使用深黑/纯黑画布背景，防止浅色主题下终端背景变为亮白刺眼
  final Color darkBg = theme.colorScheme.surface == Colors.black
      ? Colors.black
      : const Color(0xFF121214);
  final Color terminalBg = isDark ? darkBg : const Color(0xFF161618);

  return TerminalTheme(
    cursor: theme.colorScheme.primary,
    selection: theme.colorScheme.primary.withValues(alpha: 0.35),
    foreground: const Color(0xFFECEFF4),
    background: terminalBg,
    black: const Color(0xFF2E3440),
    white: const Color(0xFFE5E9F0),
    red: const Color(0xFFFF6B6B),
    green: const Color(0xFF51CF66),
    yellow: const Color(0xFFFCC419),
    blue: const Color(0xFF339AF0),
    magenta: const Color(0xFFCC5DE8),
    cyan: const Color(0xFF22B8CF),
    brightBlack: const Color(0xFF7B889B),
    brightRed: const Color(0xFFFF8787),
    brightGreen: const Color(0xFF69DB7C),
    brightYellow: const Color(0xFFFFD43B),
    brightBlue: const Color(0xFF4DABF7),
    brightMagenta: const Color(0xFFDA77F2),
    brightCyan: const Color(0xFF3BC9DB),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: theme.colorScheme.primary,
    searchHitBackgroundCurrent: theme.colorScheme.secondary,
    searchHitForeground: Colors.black,
  );
}

class ManjaroTerminalTheme extends TerminalTheme {
  const ManjaroTerminalTheme({
    super.cursor = const Color(0xaaf6f5f4),
    super.selection = const Color(0XAAAEAFAD),
    super.foreground = const Color(0xffe5e5e5),
    super.background = const Color(0xff141416),
    super.black = const Color(0xff241f31),
    super.white = const Color(0xffc0bfbc),
    super.red = const Color(0xffc01c28),
    super.green = const Color(0xff2ec27e),
    super.yellow = const Color(0xfff5c211),
    super.blue = const Color(0xff1e78e4),
    super.magenta = const Color(0xff9841bb),
    super.cyan = const Color(0xff0ab9dc),
    super.brightBlack = const Color(0xff5e5c64),
    super.brightRed = const Color(0xffed333b),
    super.brightGreen = const Color(0xff57e389),
    super.brightYellow = const Color(0xfff8e45c),
    super.brightBlue = const Color(0xff51a1ff),
    super.brightMagenta = const Color(0xffc061cb),
    super.brightCyan = const Color(0xff4fd2fd),
    super.brightWhite = const Color(0xfff6f5f4),
    super.searchHitBackground = const Color(0XFF000000),
    super.searchHitBackgroundCurrent = const Color(0XFF31FF26),
    super.searchHitForeground = const Color(0XFF000000),
  });
}
