import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/utils/version_utils.dart';
import 'package:maibot_android/ui/controllers/maibot_log_parser.dart';

void main() {
  group('MaibotLogParser', () {
    test('strips ANSI color escape sequences cleanly', () {
      const raw = '\x1B[32m[INFO]\x1B[0m WebUI 登录 Token: \x1B[36mmySecretToken123\x1B[0m';
      final clean = MaibotLogParser.stripAnsi(raw);
      expect(clean, '[INFO] WebUI 登录 Token: mySecretToken123');
    });
    test('parses MaiBot WebUI hex and custom tokens', () {
      const line = '2026-10-25 [INFO] 🔑 WebUI 登录 Token: deadbeef0123456789abcdef';
      expect(MaibotLogParser.parseMaibotToken(line), 'deadbeef0123456789abcdef');
      const customLine = '2026-10-25 [INFO] 🔑 WebUI 登录 Token: MaiBot_Custom#2026!';
      expect(MaibotLogParser.parseMaibotToken(customLine), 'MaiBot_Custom#2026!');
      expect(MaibotLogParser.parseMaibotToken('无关日志行'), isNull);
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
