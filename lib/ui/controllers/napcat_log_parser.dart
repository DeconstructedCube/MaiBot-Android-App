/// NapCat / MaiBot 日志行解析器（纯逻辑，无 UI 依赖）。
///
/// 负责从 PTY 输出行中剥离 ANSI 颜色码并识别登录/Token 事件，
/// 供 [NapcatController] 消费后做出 UI 响应。
class NapcatLogParser {
  static final _ansiColorRegExp = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _napcatTokenRegExp = RegExp(r'WebUi Token:\s+(\S+)');
  static final _maibotTokenRegExp = RegExp(r'WebUI 登录 Token:\s+(\S+)');
  static final _errorMsgRegExp = RegExp(r'"message":"([^"]+)"');
  static final _qqNumRegExp = RegExp(r'^\d+$');

  /// 剥离 ANSI 颜色代码，防止颜色字符干扰正则表达式匹配
  static String stripAnsi(String event) =>
      event.replaceAll(_ansiColorRegExp, '');

  /// 解析一条 NapCat 日志行，按出现顺序返回命中的所有事件
  static List<NapcatLogEvent> parseNapcat(String cleanEvent) {
    final events = <NapcatLogEvent>[];

    // 检测自动快速登录成功
    if (cleanEvent.contains('自动快速登录成功')) {
      events.add(const NapcatLogEvent(NapcatLogEventType.autoLoginSuccess));
    }

    // 捕获 NapCat WebUI Token
    if (cleanEvent.contains('WebUi Token:')) {
      final matches = _napcatTokenRegExp.allMatches(cleanEvent);
      if (matches.isNotEmpty) {
        final token = matches.last.group(1);
        if (token != null) {
          events.add(NapcatLogEvent(NapcatLogEventType.napcatToken, token));
        }
      }
    }

    // 检测指令1显示二维码
    if (cleanEvent.contains('二维码已保存到')) {
      events.add(const NapcatLogEvent(NapcatLogEventType.qrcodeSaved));
    }

    // 检测指令2关闭二维码
    if (cleanEvent.contains('配置加载')) {
      events.add(const NapcatLogEvent(NapcatLogEventType.configLoaded));
    }

    // 检测指令3处理登录错误
    if (cleanEvent.contains('Login Error')) {
      String errorMsg = '登录失败';
      final match = _errorMsgRegExp.firstMatch(cleanEvent);
      if (match != null) {
        errorMsg = match.group(1) ?? errorMsg;
      }
      events.add(NapcatLogEvent(NapcatLogEventType.loginError, errorMsg));
    }

    return events;
  }

  /// 解析 MaiBot 日志中的 WebUI 登录 Token（支持 64 位 hex 与自定义混合字符 Token），未命中返回 null
  static String? parseMaibotToken(String cleanEvent) {
    if (!cleanEvent.contains('WebUI 登录 Token:')) return null;
    final matches = _maibotTokenRegExp.allMatches(cleanEvent);
    if (matches.isEmpty) return null;
    return matches.last.group(1);
  }

  /// 判断是否为纯数字 QQ 号
  static bool isQQNumber(String value) => _qqNumRegExp.hasMatch(value);
}

/// NapCat 日志事件类型
enum NapcatLogEventType {
  /// 自动快速登录成功
  autoLoginSuccess,

  /// 捕获到 NapCat WebUI Token
  napcatToken,

  /// 二维码已保存（需展示二维码登录界面）
  qrcodeSaved,

  /// 配置加载完成（关闭二维码并标记登录处理完成）
  configLoaded,

  /// 登录错误
  loginError,
}

/// NapCat 日志事件（type + 可选载荷）
class NapcatLogEvent {
  const NapcatLogEvent(this.type, [this.payload]);

  final NapcatLogEventType type;

  /// token 或错误信息等载荷
  final String? payload;
}
