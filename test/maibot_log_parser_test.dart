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
    test('parses legacy and MaiBot 1.4.x WebUI tokens and ticket URLs', () {
      const line = '2026-10-25 [INFO] 🔑 WebUI 登录 Token: deadbeef0123456789abcdef';
      expect(MaibotLogParser.parseMaibotToken(line), 'deadbeef0123456789abcdef');
      const customLine = '2026-10-25 [INFO] 🔑 WebUI 登录 Token: MaiBot_Custom#2026!';
      expect(MaibotLogParser.parseMaibotToken(customLine), 'MaiBot_Custom#2026!');
      const hostLine = 'WebUI 临时登录密码：abcdef1234567890';
      expect(MaibotLogParser.parseMaibotToken(hostLine), 'abcdef1234567890');
      expect(MaibotLogParser.parseMaibotToken('无关日志行'), isNull);

      const urlLine = 'WebUI：http://127.0.0.1:8001/bots#ticket=xyz123（登录链接一分钟内有效）';
      expect(MaibotLogParser.parseWebUiUrl(urlLine), 'http://127.0.0.1:8001/bots#ticket=xyz123');
      const legacyUrl = '2026-10-25 访问地址: http://127.0.0.1:8001';
      expect(MaibotLogParser.parseWebUiUrl(legacyUrl), 'http://127.0.0.1:8001');
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
