import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/services/host_rescue_service.dart';

void main() {
  group('HostRescueService', () {
    test('resets host/webui.json and clears stale sessions.sqlite3', () async {
      final tmp = Directory.systemTemp.createTempSync('maibot_rescue_');
      try {
        final hostDir = Directory('${tmp.path}/host')..createSync(recursive: true);
        final webuiJson = File('${hostDir.path}/webui.json')
          ..writeAsStringSync(jsonEncode({
            'access_token': 'old_secret_token',
            'token_source': 'configured',
            'first_setup_completed': true,
          }));
        final sessions = File('${hostDir.path}/sessions.sqlite3')
          ..writeAsStringSync('dummy');

        final newToken = await HostRescueService.resetWebUiCredentials(
          maibotRoot: tmp.path,
          restartIfRunning: false,
        );

        expect(newToken.length, 64);
        expect(sessions.existsSync(), isFalse);

        final parsed = jsonDecode(webuiJson.readAsStringSync()) as Map<String, dynamic>;
        expect(parsed['access_token'], newToken);
        expect(parsed['token_source'], 'temporary');
        expect(parsed['first_setup_completed'], isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('repairs host/config.toml and cleans stale lock files', () async {
      final tmp = Directory.systemTemp.createTempSync('maibot_rescue_lock_');
      try {
        final hostDir = Directory('${tmp.path}/host')..createSync(recursive: true);
        final configToml = File('${hostDir.path}/config.toml')
          ..writeAsStringSync('[webui]\nport = 9999\nanti_crawler_mode = "strict"\n');
        final runLock = File('${hostDir.path}/run.lock')..createSync();
        final controlJson = File('${hostDir.path}/control.json')..createSync();
        final botLock = File('${tmp.path}/bots/abc123/instance.lock')
          ..createSync(recursive: true);

        await HostRescueService.repairHostWebUiConfig(
          maibotRoot: tmp.path,
          restartIfRunning: false,
        );
        expect(File('${configToml.path}.bak').existsSync(), isTrue);
        expect(configToml.readAsStringSync(), contains('port = 8001'));
        expect(configToml.readAsStringSync(), contains('anti_crawler_mode = "basic"'));

        final removed = await HostRescueService.cleanStaleLocks(
          maibotRoot: tmp.path,
          restartAfter: false,
        );
        expect(removed, 3);
        expect(runLock.existsSync(), isFalse);
        expect(controlJson.existsSync(), isFalse);
        expect(botLock.existsSync(), isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
