import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/utils/version_utils.dart';
import 'package:maibot_android/ui/controllers/napcat_log_parser.dart';

void main() {
  group('NapcatLogParser', () {
    test('strips ANSI color escape sequences cleanly', () {
      const raw = '\x1B[32m[INFO]\x1B[0m WebUi Token: \x1B[36mmySecretToken123\x1B[0m';
      final clean = NapcatLogParser.stripAnsi(raw);
      expect(clean, '[INFO] WebUi Token: mySecretToken123');
    });

    test('parses NapCat token, QR code, auto-login, and error events', () {
      final events = NapcatLogParser.parseNapcat(
        '二维码已保存到 /root/napcat/cache/qrcode.png\n'
        'WebUi Token: napcat_tok_998\n'
        '自动快速登录成功\n'
        '配置加载完成\n'
        'Login Error: {"message":"扫码超时"}',
      );

      expect(
        events.map((e) => e.type).toList(),
        containsAll([
          NapcatLogEventType.autoLoginSuccess,
          NapcatLogEventType.napcatToken,
          NapcatLogEventType.qrcodeSaved,
          NapcatLogEventType.configLoaded,
          NapcatLogEventType.loginError,
        ]),
      );

      final tokenEvent = events.firstWhere((e) => e.type == NapcatLogEventType.napcatToken);
      expect(tokenEvent.payload, 'napcat_tok_998');

      final errorEvent = events.firstWhere((e) => e.type == NapcatLogEventType.loginError);
      expect(errorEvent.payload, '扫码超时');
    });

    test('parses MaiBot WebUI hex token and validates QQ numbers', () {
      const line = '2026-10-25 [INFO] 🔑 WebUI 登录 Token: deadbeef0123456789abcdef';
      expect(NapcatLogParser.parseMaibotToken(line), 'deadbeef0123456789abcdef');
      expect(NapcatLogParser.parseMaibotToken('无关日志行'), isNull);

      expect(NapcatLogParser.isQQNumber('918272281'), isTrue);
      expect(NapcatLogParser.isQQNumber('12345a'), isFalse);
    });
  });

  group('compareVersions', () {
    test('compares semantic versions with v prefix and build metadata', () {
      expect(compareVersions('v1.5.0', '1.4.0+140'), 1);
      expect(compareVersions('1.4.0+140', 'v1.4.0'), 0);
      expect(compareVersions('1.3.9', '1.4.0'), -1);
    });
  });
}
