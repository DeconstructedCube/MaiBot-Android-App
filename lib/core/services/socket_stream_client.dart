import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_config.dart';
import 'backend_process_manager.dart';

/// 前台服务 PTY 转发 Socket 客户端。
///
/// 负责连接前台服务监听的本地 Socket、按行缓冲输出、
/// 解析状态变更事件（__STATE_CHANGE__）、剥离历史回放标记（__HIST_START__/__HIST_END__）并在断线后自动重连。
class SocketStreamClient {
  SocketStreamClient({
    required this.port,
    this.onData,
    this.onLine,
  });

  /// 本地监听端口（见 [Ports]）
  final int port;

  /// 每收到一个数据块时回调（标记已剥离），通常用于写入终端
  final void Function(String event)? onData;

  /// 每收到一行完整输出时回调
  final void Function(String line)? onLine;

  Socket? _socket;
  String _lineBuffer = '';
  String _frameBuffer = '';
  bool _lastCharWasCr = false;
  bool _replaying = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  StreamSubscription? _subscription;

  bool _isConnecting = false;
  /// 当前是否处于历史缓冲区回放阶段
  bool get isReplaying => _replaying;

  /// 是否已建立连接
  bool get isConnected => _socket != null;

  /// 底层 Socket（供终端输入回写）
  Socket? get socket => _socket;

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
      _subscription = _socket!
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_onStringChunk, onDone: _handleDisconnect, onError: (_) => _handleDisconnect());
    } catch (_) {
      _handleDisconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _onStringChunk(String chunk) {
    if (_disposed) return;

    String event = _frameBuffer + chunk;
    _frameBuffer = '';

    // 处理基于 STX (\x02) 和 ETX (\x03) 封包的原生控制帧与分包缓冲
    final sb = StringBuffer();
    int cursor = 0;

    while (cursor < event.length) {
      final stx = event.indexOf('\x02', cursor);
      if (stx == -1) {
        sb.write(event.substring(cursor));
        cursor = event.length;
        break;
      }

      // 将 STX 之前的内容追加到输出
      if (stx > cursor) {
        sb.write(event.substring(cursor, stx));
      }

      final etx = event.indexOf('\x03', stx + 1);
      if (etx == -1) {
        // 未收到结束符 \x03，属于跨包分片，将未闭合部分留存到下一次分包
        final unclosed = event.substring(stx);
        if (unclosed.length < 4096) {
          _frameBuffer = unclosed;
        } else {
          // 异常超长未闭合帧，放弃缓冲以防内存溢出
          sb.write(unclosed);
        }
        cursor = event.length;
        break;
      }

      // 提取完整的控制帧内容
      final framePayload = event.substring(stx + 1, etx);
      cursor = etx + 1;

      if (framePayload.startsWith('__STATE_CHANGE__:')) {
        final jsonStr = framePayload.substring('__STATE_CHANGE__:'.length);
        try {
          final Map<String, dynamic> data = jsonDecode(jsonStr);
          final service = data['service']?.toString() ?? '';
          final stateStr = data['state']?.toString() ?? '';
          final retry = data['retry'] as int? ?? 0;
          final pid = data['pid'] as int? ?? -1;
          if (service.isNotEmpty && stateStr.isNotEmpty) {
            BackendProcessManager.updateServiceState(service, stateStr, retry: retry, pid: pid);
          }
        } catch (_) {}
      } else if (framePayload == '__HIST_START__') {
        _replaying = true;
      } else if (framePayload == '__HIST_END__') {
        _replaying = false;
      }
    }

    final outputText = sb.toString();
    if (outputText.isEmpty) return;

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
    _frameBuffer = '';
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
    _socket?.destroy();
    _socket = null;
  }
}
