/// MaiBot 日志行解析器（纯逻辑，无 UI 依赖）。
///
/// 负责从 PTY 输出行中剥离 ANSI 颜色码并识别 WebUI 访问地址与登录 Token。
class MaibotLogParser {
  static final _ansiColorRegExp = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _legacyTokenRegExp = RegExp(r'WebUI 登录 Token:\s+(\S+)');
  static final _hostTempTokenRegExp = RegExp(r'WebUI 临时登录密码[：:]\s*(\S+)');
  static final _webUiUrlRegExp = RegExp(r'(?:WebUI|访问地址)[：:]\s*(https?://[^\s（(]+)');

  /// 剥离 ANSI 颜色代码，防止颜色字符干扰正则表达式匹配
  static String stripAnsi(String event) =>
      event.replaceAll(_ansiColorRegExp, '');

  /// 解析 MaiBot 日志中的 WebUI 登录 Token（兼容 1.4.x 宿主临时密码与旧版 Token 格式），未命中返回 null
  static String? parseMaibotToken(String cleanEvent) {
    final hostMatches = _hostTempTokenRegExp.allMatches(cleanEvent);
    if (hostMatches.isNotEmpty) {
      return hostMatches.last.group(1);
    }
    if (!cleanEvent.contains('WebUI 登录 Token:')) return null;
    final legacyMatches = _legacyTokenRegExp.allMatches(cleanEvent);
    if (legacyMatches.isEmpty) return null;
    return legacyMatches.last.group(1);
  }

  /// 解析 MaiBot 启动日志打印的 WebUI URL（支持 1.4.x 宿主一次性 #ticket= 免密链接与旧版访问地址）
  static String? parseWebUiUrl(String cleanEvent) {
    final matches = _webUiUrlRegExp.allMatches(cleanEvent);
    if (matches.isEmpty) return null;
    return matches.last.group(1);
  }
}
