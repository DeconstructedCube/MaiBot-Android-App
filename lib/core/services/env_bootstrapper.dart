import 'dart:io';

import 'package:global_repository/global_repository.dart';

import '../utils/file_utils.dart';

/// 环境引导器：负责将原生动态库链接到数据目录可执行路径、创建 busybox 软链接。
class EnvBootstrapper {
  /// 初始化环境，将原生库文件符号链接到应用运行环境 bin 目录
  static Future<void> initEnvir() async {
    await Directory(RuntimeEnvir.binPath).create(recursive: true);
    final List<({String soName, String targetName})> nativeFiles = [
      (soName: 'libbash.so', targetName: 'bash'),
      (soName: 'libbusybox.so', targetName: 'busybox'),
      (soName: 'liblibtalloc.so.2.so', targetName: 'libtalloc.so.2'),
      (soName: 'libloader.so', targetName: 'loader'),
      (soName: 'libproot.so', targetName: 'proot'),
      (soName: 'libsudo.so', targetName: 'sudo'),
    ];
    final String libPath = await getLibPath();
    Log.i('Native library directory -> $libPath', tag: 'EnvBootstrapper');

    for (final item in nativeFiles) {
      final sourcePath = '$libPath/${item.soName}';
      final filePath = '${RuntimeEnvir.binPath}/${item.targetName}';

      final file = File(filePath);
      final FileSystemEntityType type = await FileSystemEntity.type(filePath);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.link) {
        Log.i('Found regular file at link target -> ${item.targetName}, removing', tag: 'EnvBootstrapper');
        try {
          await file.delete();
        } catch (e) {
          Log.e('Failed to delete regular file -> $e', tag: 'EnvBootstrapper');
        }
      }

      final link = Link(filePath);
      if (await link.exists()) {
        try {
          await link.delete();
        } catch (e) {
          Log.w('Failed to delete existing link -> $e', tag: 'EnvBootstrapper');
        }
      }

      try {
        await link.create(sourcePath);
      } catch (e) {
        Log.e('Failed to create link for ${item.targetName} -> $e', tag: 'EnvBootstrapper');
      }
    }

    // 处理 busybox 相关的符号链接，确保 proot 依赖的命令可用
    await createBusyboxLink();
  }

  /// 创建 busybox 常用命令符号链接，确保 proot 运行时环境可用
  static Future<void> createBusyboxLink() async {
    try {
      const List<String> links = [
        'awk', 'ash', 'basename', 'bzip2', 'curl', 'cp', 'chmod', 'cut',
        'cat', 'du', 'dd', 'find', 'grep', 'gzip', 'hexdump', 'head', 'id',
        'lscpu', 'mkdir', 'realpath', 'rm', 'sed', 'stat', 'sh', 'tr',
        'tar', 'uname', 'xargs', 'xz', 'xxd',
      ];

      final busyboxTarget = '${RuntimeEnvir.binPath}/busybox';
      for (final linkName in links) {
        final linkPath = '${RuntimeEnvir.binPath}/$linkName';
        final link = Link(linkPath);
        if (await link.exists()) {
          try {
            await link.delete();
          } catch (_) {}
        }
        try {
          await link.create(busyboxTarget);
        } catch (e) {
          Log.w('Failed to link busybox tool $linkName -> $e', tag: 'EnvBootstrapper');
        }
      }

      final fileLinkPath = '${RuntimeEnvir.binPath}/file';
      final fileLink = Link(fileLinkPath);
      if (await fileLink.exists()) {
        try {
          await fileLink.delete();
        } catch (_) {}
      }
      try {
        await fileLink.create('/system/bin/file');
      } catch (_) {}
    } catch (e) {
      Log.e('Create busybox links failed -> $e', tag: 'EnvBootstrapper');
    }
  }
}
