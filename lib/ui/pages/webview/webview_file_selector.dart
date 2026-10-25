import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// WebView 原生文件选择与 MIME 类型推断助手
class WebViewFileSelector {
  static const List<String> _imageExtensions = [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  ];

  static const List<String> _videoExtensions = [
    'mp4', 'avi', 'mov', 'mkv', 'flv', 'wmv',
    '.mp4', '.avi', '.mov', '.mkv', '.flv', '.wmv',
  ];

  static const List<String> _audioExtensions = [
    'mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac',
    '.mp3', '.wav', '.ogg', '.flac', '.m4a', '.aac',
  ];

  /// 处理 Android WebView 的文件选择请求并返回 `file://` URI 列表
  static Future<List<String>> handleFileSelection(
    FileSelectorParams params,
  ) async {
    try {
      List<PlatformFile> pickedFiles = [];
      final bool allowMultiple = params.mode == FileSelectorMode.openMultiple;

      FileType pickingType = FileType.any;
      List<String>? allowedExtensions;

      if (params.acceptTypes.isNotEmpty) {
        final acceptTypes = params.acceptTypes;

        final bool isImageOnly = acceptTypes.every(
          (type) =>
              type.startsWith('image/') ||
              _imageExtensions.contains(type.toLowerCase()),
        );
        final bool isVideoOnly = acceptTypes.every(
          (type) =>
              type.startsWith('video/') ||
              _videoExtensions.contains(type.toLowerCase()),
        );
        final bool isAudioOnly = acceptTypes.every(
          (type) =>
              type.startsWith('audio/') ||
              _audioExtensions.contains(type.toLowerCase()),
        );

        if (isImageOnly) {
          pickingType = FileType.image;
        } else if (isVideoOnly) {
          pickingType = FileType.video;
        } else if (isAudioOnly) {
          pickingType = FileType.audio;
        } else {
          final List<String> extensions = [];
          for (final type in acceptTypes) {
            if (type.startsWith('.')) {
              extensions.add(type.substring(1));
            } else if (!type.contains('/')) {
              extensions.add(type);
            }
          }
          if (extensions.isNotEmpty) {
            pickingType = FileType.custom;
            allowedExtensions = extensions;
          }
        }
      }

      if (allowMultiple) {
        final List<PlatformFile> result = await FilePicker.pickFiles(
          type: pickingType,
          allowedExtensions: allowedExtensions,
        );
        if (result.isNotEmpty) {
          pickedFiles = result;
        }
      } else {
        final PlatformFile? file = await FilePicker.pickFile(
          type: pickingType,
          allowedExtensions: allowedExtensions,
        );
        if (file != null) {
          pickedFiles = [file];
        }
      }

      if (pickedFiles.isNotEmpty) {
        final List<String> filePaths = pickedFiles
            .where((file) => file.path != null)
            .map((file) {
          final path = file.path!;
          if (path.startsWith('file://')) {
            return path;
          }
          final normalizedPath = path.replaceAll('\\', '/');
          return 'file://$normalizedPath';
        }).toList();

        debugPrint('Selected files: $filePaths');
        return filePaths;
      }

      return [];
    } catch (e) {
      debugPrint('File selection error: $e');
      return [];
    }
  }
}
