import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../config/app_config.dart';
import 'backend_process_manager.dart';

/// 前台服务 PTY 转发 Socket 客户端（基于 5 字节长度前缀二进制帧协议）。
///
/// 帧协议格式：
/// - `Byte 0`: 帧类型
///   - `0x01`: 实时终端 PTY 原始字节流 (`framePtyData`)
///   - `0x02`: 历史环形缓冲区回放字节流 (`frameHistoryData`)
///   - `0x03`: JSON 状态控制帧 (`frameControlJson`)
/// - `Bytes 1..4`: Big-Endian Uint32 载荷长度
/// - `Bytes 5..5+len`: 载荷数据
///
/// 彻底解决多字节 UTF-8 中文/Emoji 跨 TCP 分包截断乱码及控制帧混流粘包问题。
class SocketStreamClient {
  static const int framePtyData = 0x01;
  static const int frameHistoryData = 0x02;
  static const int frameControlJson = 0x03;
  static const int maxFramePayloadSize = 4 * 1024 * 1024; // 4MB 安全上限

  SocketStreamClient({
    required this.port,
    this.onData,
    this.onLine,
    this.onStateFrame,
  }) {
    _initUtf8StreamDecoder();
  }

  /// 本地监听端口（见 [Ports]）
  final int port;

  /// 每收到一个解码后的终端数据块时回调，通常用于写入终端
  final void Function(String event)? onData;

  /// 每收到一行完整终端输出时回调
  final void Function(String line)? onLine;

  /// 可选的状态变更回调（默认自动同步至 [BackendProcessManager.updateServiceState]）
  final void Function(String service, String state, int retry, int pid)? onStateFrame;

  Socket? _socket;
  final List<int> _rawBuffer = <int>[];
  late ByteConversionSink _ptyUtf8Sink;
  String _lineBuffer = '';
  bool _lastCharWasCr = false;
  bool _replaying = false;
  bool _disposed = false;
  bool _isConnecting = false;
  Timer? _reconnectTimer;
  StreamSubscription<Uint8List>? _subscription;

  /// 当前是否处于历史缓冲区回放阶段
  bool get isReplaying => _replaying;

  /// 是否已建立连接
  bool get isConnected => _socket != null;

  /// 底层 Socket（供终端输入回写）
  Socket? get socket => _socket;

  /// 将载荷封装为 5 字节长度前缀的二进制帧（供测试或发送端使用）
  static Uint8List encodeFrame(int type, List<int> payload) {
    final len = payload.length;
    final frame = Uint8List(5 + len);
    frame[0] = type & 0xFF;
    frame[1] = (len >> 24) & 0xFF;
    frame[2] = (len >> 16) & 0xFF;
    frame[3] = (len >> 8) & 0xFF;
    frame[4] = len & 0xFF;
    if (len > 0) {
      frame.setRange(5, 5 + len, payload);
    }
    return frame;
  }

  void _initUtf8StreamDecoder() {
    _ptyUtf8Sink = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_CallbackStringSink(_onDecodedPtyText));
  }

  /// 开始连接（幂等，重复调用无副作用）
  void connect() {
    if (_disposed || _socket != null) return;
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed || isConnected || _isConnecting) return;
    _isConnecting = true;
    try {
      _socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      if (_disposed) {
        _socket?.destroy();
        _socket = null;
        return;
      }
      _subscription = _socket!.listen(
        feedRawBytes,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
    } catch (_) {
      _handleDisconnect();
    } finally {
      _isConnecting = false;
    }
  }

  /// 喂入原始字节块并执行二进制解帧（公开以便单元测试直接注入分片字节流）
  void feedRawBytes(List<int> chunk) {
    if (_disposed || chunk.isEmpty) return;
    _rawBuffer.addAll(chunk);

    int offset = 0;
    while (_rawBuffer.length - offset >= 5) {
      final int frameType = _rawBuffer[offset];
      final int payloadLen = ((_rawBuffer[offset + 1] & 0xFF) << 24) |
          ((_rawBuffer[offset + 2] & 0xFF) << 16) |
          ((_rawBuffer[offset + 3] & 0xFF) << 8) |
          (_rawBuffer[offset + 4] & 0xFF);

      if (payloadLen < 0 || payloadLen > maxFramePayloadSize) {
        // 协议失步保护：清空异常缓冲并重置解码器
        _rawBuffer.clear();
        _initUtf8StreamDecoder();
        return;
      }

      if (_rawBuffer.length - offset < 5 + payloadLen) {
        // 载荷尚未收齐，等待后续 TCP 分片
        break;
      }

      final payload = _rawBuffer.sublist(offset + 5, offset + 5 + payloadLen);
      offset += 5 + payloadLen;

      _dispatchFrame(frameType, payload);
    }

    if (offset > 0) {
      _rawBuffer.removeRange(0, offset);
    }
  }

  void _dispatchFrame(int frameType, List<int> payload) {
    switch (frameType) {
      case framePtyData:
        _replaying = false;
        _ptyUtf8Sink.add(payload);
        break;
      case frameHistoryData:
        _replaying = true;
        _ptyUtf8Sink.add(payload);
        _replaying = false;
        break;
      case frameControlJson:
        _handleControlJson(payload);
        break;
      default:
        break;
    }
  }

  void _handleControlJson(List<int> payload) {
    try {
      final jsonStr = utf8.decode(payload, allowMalformed: true);
      final dynamic decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        final service = decoded['service']?.toString() ?? '';
        final stateStr = decoded['state']?.toString() ?? '';
        final retry = decoded['retry'] is int ? decoded['retry'] as int : 0;
        final pid = decoded['pid'] is int ? decoded['pid'] as int : -1;
        if (service.isNotEmpty && stateStr.isNotEmpty) {
          onStateFrame?.call(service, stateStr, retry, pid);
          BackendProcessManager.updateServiceState(service, stateStr, retry: retry, pid: pid);
        }
      }
    } catch (_) {}
  }

  void _onDecodedPtyText(String outputText) {
    if (_disposed || outputText.isEmpty) return;

    // 采用有状态换行规范化，防止 \r\n 跨包拆分时破坏动态进度条的单行 \r 原地重绘
    final normalizedEvent = _normalizeNewlines(outputText);
    onData?.call(normalizedEvent);

    _lineBuffer += outputText;
    final lines = _lineBuffer.split('\n');
    _lineBuffer = lines.removeLast();
    for (final line in lines) {
      onLine?.call(line);
    }
  }

  void _handleDisconnect() {
    _lineBuffer = '';
    _rawBuffer.clear();
    _initUtf8StreamDecoder();
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), connect);
  }

  String _normalizeNewlines(String chunk) {
    if (chunk.isEmpty) return chunk;
    final buffer = StringBuffer();
    for (int i = 0; i < chunk.length; i++) {
      final char = chunk[i];
      if (char == '\n') {
        if (!_lastCharWasCr && (i == 0 || chunk[i - 1] != '\r')) {
          buffer.write('\r\n');
        } else {
          buffer.write('\n');
        }
      } else {
        buffer.write(char);
      }
      _lastCharWasCr = (char == '\r');
    }
    return buffer.toString();
  }

  /// 关闭连接并停止自动重连
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    try {
      _ptyUtf8Sink.close();
    } catch (_) {}
    _socket?.destroy();
    _socket = null;
  }
}

class _CallbackStringSink implements Sink<String> {
  final void Function(String) onChunk;
  const _CallbackStringSink(this.onChunk);

  @override
  void add(String data) => onChunk(data);

  @override
  void close() {}
}
