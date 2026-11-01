import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/state/app_lifecycle_state_machine.dart';

void main() {
  group('Login & Navigation Guard Logic', () {
    test('presence of webui token alone does not prematurely mark loginReady in state machine', () {
      final sm = AppLifecycleStateMachine();
      sm.markBackendRequested();
      sm.markPortsReady();

      // 当 Web 端口已就绪时，若 QQ 扫码尚未完成，状态应为 waitingLogin，严禁提前进入 webview
      expect(sm.phase, AppPhase.waitingLogin);
      expect(sm.canEnterWebview, isFalse);

      // 只有在明确确认登录就绪时，才允许进入 webview
      sm.markLoginReady();
      expect(sm.phase, AppPhase.ready);
      expect(sm.canEnterWebview, isTrue);
    });

    test('extract targets filter matches only existing modules in archive inspection', () {
      final inspectResult = {
        'data': true,
        'config': true,
        'plugins': false,
        'napcat': false,
      };

      final requestedData = true;
      final requestedConfig = true;
      final requestedPlugins = true;
      final requestedNapcat = true;

      final extractTargets = <String>[];
      if (requestedData && inspectResult['data'] == true) extractTargets.add('MaiBot/data');
      if (requestedConfig && inspectResult['config'] == true) extractTargets.add('MaiBot/config');
      if (requestedPlugins && inspectResult['plugins'] == true) extractTargets.add('MaiBot/plugins');
      if (requestedNapcat && inspectResult['napcat'] == true) extractTargets.add('napcat/config');

      // 即使用户全选，也必须被实际归档模块过滤，防止 tar 找不到目录失败
      expect(extractTargets, ['MaiBot/data', 'MaiBot/config']);
    });
  });
}
