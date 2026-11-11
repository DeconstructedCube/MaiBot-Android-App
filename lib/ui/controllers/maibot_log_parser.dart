/// MaiBot 日志行解析器（纯逻辑，无 UI 依赖）。
///
/// 负责从 PTY 输出行中剥离 ANSI 颜色码并识别 WebUI 登录 Token。
class MaibotLogParser {
  static final _ansiColorRegExp = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _maibotTokenRegExp = RegExp(r'WebUI 登录 Token:\s+(\S+)');

  /// 剥离 ANSI 颜色代码，防止颜色字符干扰正则表达式匹配
  static String stripAnsi(String event) =>
      event.replaceAll(_ansiColorRegExp, '');

  /// 解析 MaiBot 日志中的 WebUI 登录 Token（支持 64 位 hex 与自定义混合字符 Token），未命中返回 null
  static String? parseMaibotToken(String cleanEvent) {
    if (!cleanEvent.contains('WebUI 登录 Token:')) return null;
    final matches = _maibotTokenRegExp.allMatches(cleanEvent);
    if (matches.isEmpty) return null;
    return matches.last.group(1);
  }
}
