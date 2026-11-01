import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class AssetsUtils {
  AssetsUtils._();
  static Future<void> copyAssetToPath(String key, String path, {bool forceCopy = false}) async {
    final ByteData byteData = await rootBundle.load(key);
    final Uint8List picBytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final File file = File(path);
    bool needCopy = forceCopy || !file.existsSync() || file.lengthSync() != picBytes.length;
    if (!needCopy) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(picBytes, flush: true);
  }
}
