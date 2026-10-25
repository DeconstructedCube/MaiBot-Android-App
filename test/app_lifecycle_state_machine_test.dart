import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/services/port_probe_service.dart';
import 'package:maibot_android/core/state/app_lifecycle_state_machine.dart';

void main() {
  group('AppLifecycleStateMachine', () {
    test('initial state is uninitialized with zero progress', () {
      final sm = AppLifecycleStateMachine();
      expect(sm.phase, AppPhase.uninitialized);
      expect(sm.progress, 0.0);
      expect(sm.canEnterWebview, isFalse);
    });

    test('transitions monotonically through extraction and configuration stages', () {
      final sm = AppLifecycleStateMachine();

      sm.beginExtraction();
      expect(sm.phase, AppPhase.extracting);
      expect(sm.progress, InstallStage.extractingRootfs.progressWeight);

      sm.beginConfiguration(stage: InstallStage.installingUv);
      expect(sm.phase, AppPhase.configuring);
      expect(sm.progress, InstallStage.installingUv.progressWeight);

      sm.beginConfiguration(stage: InstallStage.syncingPythonEnv);
      expect(sm.phase, AppPhase.configuring);
      expect(sm.progress, InstallStage.syncingPythonEnv.progressWeight);
    });

    test('reaches ready only when both portsReady and loginReady are true', () {
      final sm = AppLifecycleStateMachine();

      sm.markBackendRequested();
      expect(sm.phase, AppPhase.backendStarting);
      expect(sm.canEnterWebview, isFalse);

      sm.markPortsReady();
      expect(sm.phase, AppPhase.waitingLogin);
      expect(sm.portsReady, isTrue);
      expect(sm.canEnterWebview, isFalse);

      sm.markLoginReady();
      expect(sm.phase, AppPhase.ready);
      expect(sm.progress, 1.0);
      expect(sm.canEnterWebview, isTrue);
    });

    test('login fact is sticky across backend restarts while port fact resets', () {
      final sm = AppLifecycleStateMachine();

      sm.markLoginReady();
      sm.markPortsReady();
      expect(sm.phase, AppPhase.ready);

      // Re-requesting backend resets portsReady but preserves loginReady
      sm.markBackendRequested();
      expect(sm.portsReady, isFalse);
      expect(sm.loginReady, isTrue);
      expect(sm.phase, AppPhase.backendStarting);

      // Once ports come back up, immediately transitions to ready
      sm.markPortsReady();
      expect(sm.phase, AppPhase.ready);
      expect(sm.canEnterWebview, isTrue);
    });

    test('fail transitions to error and recovers on subsequent stage', () {
      final sm = AppLifecycleStateMachine();
      sm.beginExtraction();
      sm.fail('Network timeout');
      expect(sm.phase, AppPhase.error);
      expect(sm.errorMessage, 'Network timeout');

      sm.beginConfiguration(stage: InstallStage.checkingSystemDeps);
      expect(sm.phase, AppPhase.configuring);
      expect(sm.errorMessage, isNull);
    });
  });

  group('PortProbeService', () {
    test('detects open port and returns null when port is closed', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;

      final openHit = await PortProbeService.probeAnyPort(
        [port],
        timeout: const Duration(milliseconds: 200),
      );
      expect(openHit, port);

      await server.close();

      final closedHit = await PortProbeService.probeAnyPort(
        [port],
        timeout: const Duration(milliseconds: 100),
      );
      expect(closedHit, isNull);
    });

    test('waitForAnyPort cancels cleanly via generation bump', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = server.port;
      await server.close();

      final prober = PortProbeService();
      final future = prober.waitForAnyPort(
        [closedPort],
        timeout: const Duration(milliseconds: 50),
        interval: const Duration(milliseconds: 80),
        maxAttempts: 20,
      );

      Future.delayed(const Duration(milliseconds: 60), prober.cancel);
      final result = await future;
      expect(result, isNull);
      prober.dispose();
    });
  });
}
