import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:global_repository/global_repository.dart';
import 'package:maibot_android/core/services/proot_runner.dart';
import 'package:maibot_android/ui/controllers/terminal_tab_manager.dart';

void main() {
  group('TerminalTabManager.transformKeyInput', () {
    test('transforms CTRL+char and CTRL+arrow and resets sticky modifier', () {
      final manager = TerminalTabManager();

      manager.isCtrlActive.value = true;
      expect(manager.transformKeyInput('c'), '\x03');
      expect(manager.isCtrlActive.value, isFalse);

      manager.isCtrlActive.value = true;
      expect(manager.transformKeyInput('\x1b[A'), '\x1b[1;5A');
      expect(manager.isCtrlActive.value, isFalse);

      manager.isCtrlActive.value = true;
      expect(manager.transformKeyInput('\x1b[D'), '\x1b[1;5D');
      expect(manager.isCtrlActive.value, isFalse);
    });

    test('transforms ALT and SHIFT modifiers cleanly', () {
      final manager = TerminalTabManager();

      manager.isAltActive.value = true;
      expect(manager.transformKeyInput('x'), '\x1bx');
      expect(manager.isAltActive.value, isFalse);

      manager.isAltActive.value = true;
      expect(manager.transformKeyInput('\x1b[C'), '\x1b[1;3C');
      expect(manager.isAltActive.value, isFalse);

      manager.isShiftActive.value = true;
      expect(manager.transformKeyInput('a'), 'A');
      expect(manager.isShiftActive.value, isFalse);
    });
  });

  group('ProotRunner', () {
    test('builds proot env and args cleanly with temp RuntimeEnvir', () {
      final tmp = Directory.systemTemp.createTempSync('maibot_proot_test_');
      try {
        RuntimeEnvir.initEnvirFromMap({
          'BIN': '${tmp.path}/bin',
          'TMP': '${tmp.path}/tmp',
          'HOME': '${tmp.path}/home',
          'USR': '${tmp.path}/usr',
          'FILES': tmp.path,
          'DATA': tmp.path,
          'CONFIG': tmp.path,
          'PATH': '/usr/bin:/bin',
        });

        final env = ProotRunner.getProotEnv();
        expect(env['PROOT_TMP_DIR'], '${tmp.path}/tmp');
        expect(env['PROOT_LOADER'], '${tmp.path}/bin/loader');
        expect(env['MAIBOT_LEGACY_0X_UPGRADE_CONFIRMED'], '1');

        final args = ProotRunner.buildProotArgs(
          scriptCommand: 'echo ok',
          workingDir: '/root/MaiBot',
          isInteractive: false,
        );
        expect(args, containsAllInOrder(['-w', '/root/MaiBot', '/bin/sh', '-c']));
        expect(args.last, contains('cd /root/MaiBot; echo ok'));

        final interactiveArgs = ProotRunner.buildProotArgs(isInteractive: true);
        expect(interactiveArgs.last, contains('shopt -s checkwinsize'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
