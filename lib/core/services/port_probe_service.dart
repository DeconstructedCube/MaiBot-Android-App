import 'dart:async';
import 'dart:io';

/// 本地端口有界重试探测服务（代际计数、可取消、无 Timer.periodic 泄漏）
class PortProbeService {
  int _generation = 0;
  bool _disposed = false;

  /// 当前探测代际号
  int get generation => _generation;

  /// 单次探测给定端口列表中是否有任一端口已处于监听状态，返回首个命中的端口号，未命中返回 null
  static Future<int?> probeAnyPort(
    List<int> ports, {
    String host = '127.0.0.1',
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    for (final port in ports) {
      try {
        final socket = await Socket.connect(host, port, timeout: timeout);
        await socket.close();
        return port;
      } catch (_) {}
    }
    return null;
  }

  /// 单次探测给定端口列表中是否有任一端口可连接
  static Future<bool> isAnyPortOpen(
    List<int> ports, {
    String host = '127.0.0.1',
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final hit = await probeAnyPort(ports, host: host, timeout: timeout);
    return hit != null;
  }

  /// 启动有界重试探测：直到任一端口就绪、达到最大尝试次数或被 [cancel] 取消
  Future<int?> waitForAnyPort(
    List<int> ports, {
    String host = '127.0.0.1',
    Duration timeout = const Duration(milliseconds: 600),
    Duration interval = const Duration(milliseconds: 1500),
    int maxAttempts = 240,
    void Function(int port)? onReady,
  }) async {
    if (_disposed || ports.isEmpty || maxAttempts <= 0) return null;
    final currentGen = ++_generation;

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (_disposed || currentGen != _generation) return null;

      final hitPort = await probeAnyPort(ports, host: host, timeout: timeout);
      if (_disposed || currentGen != _generation) return null;

      if (hitPort != null) {
        onReady?.call(hitPort);
        return hitPort;
      }

      if (attempt + 1 < maxAttempts) {
        await Future.delayed(interval);
      }
    }
    return null;
  }

  /// 取消当前正在进行的探测循环
  void cancel() {
    _generation++;
  }

  /// 彻底释放探测服务
  void dispose() {
    _disposed = true;
    _generation++;
  }
}
