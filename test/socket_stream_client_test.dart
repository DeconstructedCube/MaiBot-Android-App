import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maibot_android/core/services/socket_stream_client.dart';

void main() {
  group('SocketStreamClient Frame Protocol', () {
    test('encodeFrame packs 5-byte length prefix header correctly', () {
      final payload = utf8.encode('Hello MaiBot');
      final frame = SocketStreamClient.encodeFrame(
        SocketStreamClient.framePtyData,
        payload,
      );

      expect(frame.length, 5 + payload.length);
      expect(frame[0], SocketStreamClient.framePtyData);

      final payloadLen = ((frame[1] & 0xFF) << 24) |
          ((frame[2] & 0xFF) << 16) |
          ((frame[3] & 0xFF) << 8) |
          (frame[4] & 0xFF);
      expect(payloadLen, payload.length);
      expect(frame.sublist(5), payload);
    });

    test('feedRawBytes correctly reassembles split TCP chunks and control frames', () {
      final receivedData = <String>[];
      final controlFrames = <({String service, String state, int retry, int pid})>[];

      final client = SocketStreamClient(
        port: 29999,
        onData: (text) => receivedData.add(text),
        onStateFrame: (service, state, retry, pid) {
          controlFrames.add((
            service: service,
            state: state,
            retry: retry,
            pid: pid,
          ));
        },
      );

      // 1. 测试控制帧解析
      const jsonStr = '{"service":"maibot","state":"RUNNING","retry":0,"pid":12345}';
      final ctrlPayload = utf8.encode(jsonStr);
      final ctrlFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.frameControlJson,
        ctrlPayload,
      );

      client.feedRawBytes(ctrlFrame);
      expect(controlFrames.length, 1);
      expect(controlFrames.first.service, 'maibot');
      expect(controlFrames.first.state, 'RUNNING');
      expect(controlFrames.first.pid, 12345);

      // 2. 测试跨分包 TCP 字节流（模拟中文字符跨包截断与拼接）
      const ptyText = '正在初始化 MaiBot 容器环境 🚀\n';
      final ptyPayload = utf8.encode(ptyText);
      final ptyFrame = SocketStreamClient.encodeFrame(
        SocketStreamClient.framePtyData,
        ptyPayload,
      );

      // 故意按 7 字节一片进行切片喂入
      for (int i = 0; i < ptyFrame.length; i += 7) {
        final end = (i + 7 < ptyFrame.length) ? i + 7 : ptyFrame.length;
        client.feedRawBytes(Uint8List.fromList(ptyFrame.sublist(i, end)));
      }

      final combined = receivedData.join('');
      expect(combined.contains('正在初始化 MaiBot 容器环境 🚀'), isTrue);

      client.dispose();
    });
  });
}
