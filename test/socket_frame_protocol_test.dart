import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/services/backend_process_manager.dart';
import 'package:maibot_android/core/services/socket_stream_client.dart';

void main() {
  group('SocketStreamClient Binary Frame Protocol', () {
    test('decodes live PTY frames, history frames, and control state frames', () {
      final receivedChunks = <String>[];
      final receivedLines = <String>[];
      final stateEvents = <String>[];
      bool wasReplayingDuringHistory = false;

      late SocketStreamClient client;
      client = SocketStreamClient(
        port: 20001,
        onData: (chunk) {
          if (client.isReplaying) {
            wasReplayingDuringHistory = true;
          }
          receivedChunks.add(chunk);
        },
        onLine: receivedLines.add,
        onStateFrame: (service, state, retry, pid) {
          stateEvents.add('$service:$state:$retry:$pid');
        },
      );

      final histFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.frameHistoryData,
        utf8.encode('History line 1\n'),
      );
      final stateFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.frameControlJson,
        utf8.encode('{"service":"maibot","state":"RUNNING","retry":2,"pid":4321}'),
      );
      final ptyFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.framePtyData,
        utf8.encode('访问地址: http://127.0.0.1:8001\n'),
      );

      client.feedRawBytes([...histFrame, ...stateFrame, ...ptyFrame]);

      expect(wasReplayingDuringHistory, isTrue);
      expect(client.isReplaying, isFalse);
      expect(stateEvents, ['maibot:RUNNING:2:4321']);
      expect(BackendProcessManager.maibotState.value, ProcessState.running);
      expect(BackendProcessManager.maibotRetryCount.value, 2);
      expect(BackendProcessManager.maibotPid.value, 4321);
      expect(receivedLines, [
        'History line 1',
        '访问地址: http://127.0.0.1:8001',
      ]);
      expect(receivedChunks.join(), contains('\r\n'));

      client.dispose();
    });

    test('reassembles multi-byte UTF-8 characters split across PTY frames and 1-byte TCP chunks', () {
      final receivedLines = <String>[];
      final stateEvents = <String>[];

      final client = SocketStreamClient(
        port: 20001,
        onLine: receivedLines.add,
        onStateFrame: (service, state, retry, pid) {
          stateEvents.add('$service:$state');
        },
      );

      final fullTextBytes = utf8.encode('🔑 WebUI 登录 Token: a1b2c3d4 麦麦启动成功 🎉\n');
      // Split right in the middle of a multi-byte Chinese character
      final splitIndex = 15;
      final part1 = fullTextBytes.sublist(0, splitIndex);
      final part2 = fullTextBytes.sublist(splitIndex);

      final frame1 = SocketStreamClient.encodeFrame(
        SocketStreamClient.framePtyData,
        part1,
      );
      // Interleave a control frame right between the two split UTF-8 byte chunks!
      final controlFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.frameControlJson,
        utf8.encode('{"service":"napcat","state":"STARTING","retry":0,"pid":99}'),
      );
      final frame2 = SocketStreamClient.encodeFrame(
        SocketStreamClient.framePtyData,
        part2,
      );

      final combinedWireBytes = [...frame1, ...controlFrame, ...frame2];
      // Feed 3 bytes at a time to simulate extreme TCP fragmentation
      for (int i = 0; i < combinedWireBytes.length; i += 3) {
        final end = (i + 3 < combinedWireBytes.length) ? i + 3 : combinedWireBytes.length;
        client.feedRawBytes(combinedWireBytes.sublist(i, end));
      }

      expect(stateEvents, ['napcat:STARTING']);
      expect(receivedLines, ['🔑 WebUI 登录 Token: a1b2c3d4 麦麦启动成功 🎉']);

      client.dispose();
    });
  });
}
