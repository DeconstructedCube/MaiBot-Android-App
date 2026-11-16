import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

class Log {
  const Log._();

  static void d(Object? message, {String tag = 'MaiBot'}) {
    if (kDebugMode) {
      _emit('D', tag, message, 500);
    }
  }

  static void i(Object? message, {String tag = 'MaiBot'}) {
    _emit('I', tag, message, 800);
  }

  static void w(Object? message, {String tag = 'MaiBot'}) {
    _emit('W', tag, message, 900);
  }

  static void e(Object? message, {String tag = 'MaiBot'}) {
    _emit('E', tag, message, 1000);
  }

  static void _emit(String level, String tag, Object? message, int devLevel) {
    final text = message?.toString() ?? 'null';
    developer.log(text, name: tag, level: devLevel);
    if (!kReleaseMode) {
      debugPrint('[$level][$tag] $text');
    }
  }
}
