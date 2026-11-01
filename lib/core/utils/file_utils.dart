import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:global_repository/global_repository.dart';
import 'package:xterm/xterm.dart';
import '../config/app_config.dart';

// 为了获取Apk So库路径，我们需要一个MethodChannel
const MethodChannel _channel = MethodChannel(Config.methodChannel);

/// 获取 Apk So 库路径
/// Gets the path of the Apk So library
Future<String> getLibPath() async {
  return await _channel.invokeMethod('lib_path');
}

/// 获取 MaiBot 备份与数据持久化下载目录，按优先级自适应探测不同 Android 分身/主系统路径
Directory getMaiBotBackupDirectory() {
  const candidates = [
    '/storage/emulated/0/Download/MaiBot',
    '/sdcard/Download/MaiBot',
    '/storage/self/primary/Download/MaiBot',
  ];
  for (final path in candidates) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        return dir;
      }
    } catch (_) {}
  }
  // 尝试创建首选公开下载目录
  for (final path in candidates) {
    try {
      final dir = Directory(path);
      dir.createSync(recursive: true);
      if (dir.existsSync()) {
        return dir;
      }
    } catch (_) {}
  }
  // 若外部公共存储受限无法写入，安全回退至应用内部持久化目录
  final fallback = Directory('${RuntimeEnvir.homePath}/backups');
  try {
    if (!fallback.existsSync()) {
      fallback.createSync(recursive: true);
    }
  } catch (_) {}
  return fallback;
}

extension TerminalExt on Terminal {
  void writeProgress(String data) {
    write('\x1b[31m- $data\x1b[0m\r\n');
  }

  /// 提取终端当前缓冲区的纯文本内容
  String getPlainText() {
    final buf = buffer;
    final lines = <String>[];
    for (int i = 0; i < buf.lines.length; i++) {
      lines.add(buf.lines[i].toString().trimRight());
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }
}

extension TerminalStringExt on String {
  /// 将字符串中的独立 \n 统一转换为 xterm 终端换行所需的 \r\n（保留已有的 \r\n）
  String toTerminalCrlf() {
    if (isEmpty) return this;
    return replaceAllMapped(RegExp(r'(?<!\r)\n'), (m) => '\r\n');
  }
}
