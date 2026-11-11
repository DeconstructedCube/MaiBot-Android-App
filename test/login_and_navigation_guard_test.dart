import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/state/app_lifecycle_state_machine.dart';

void main() {
  group('Navigation & Backup Guard Logic', () {
    test('transitions directly to ready and allows entering webview once ports are ready', () {
      final sm = AppLifecycleStateMachine();
      sm.markBackendRequested();
      expect(sm.canEnterWebview, isFalse);

      sm.markPortsReady();
      expect(sm.phase, AppPhase.ready);
      expect(sm.canEnterWebview, isTrue);
    });

    test('extract targets filter matches only existing modules in archive inspection', () {
      final inspectResult = {
        'data': true,
        'config': true,
        'plugins': false,
      };

      final requestedData = true;
      final requestedConfig = true;
      final requestedPlugins = true;

      final extractTargets = <String>[];
      if (requestedData && inspectResult['data'] == true) extractTargets.add('MaiBot/data');
      if (requestedConfig && inspectResult['config'] == true) extractTargets.add('MaiBot/config');
      if (requestedPlugins && inspectResult['plugins'] == true) extractTargets.add('MaiBot/plugins');

      // 即使用户全选，也必须被实际归档模块过滤，防止 tar 找不到目录失败
      expect(extractTargets, ['MaiBot/data', 'MaiBot/config']);
    });
  });
}
