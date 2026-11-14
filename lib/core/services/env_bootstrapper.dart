import 'dart:io';

import 'package:global_repository/global_repository.dart';

import '../utils/file_utils.dart';

/// 环境引导器：负责将原生动态库链接到数据目录可执行路径、创建 busybox 软链接。
class EnvBootstrapper {
  static Future<void> _ensureSymlink(
    String linkPath,
    String targetPath, {
    String? label,
  }) async {
    final type = await FileSystemEntity.type(linkPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      try {
        final currentTarget = await Link(linkPath).target();
        if (currentTarget == targetPath) {
          return;
        }
        await Link(linkPath).delete();
      } catch (e) {
        Log.w('Failed to inspect/delete link $linkPath -> $e', tag: 'EnvBootstrapper');
      }
    } else if (type != FileSystemEntityType.notFound) {
      if (label != null) {
        Log.i('Found regular file at link target -> $label, removing', tag: 'EnvBootstrapper');
      }
      try {
        await File(linkPath).delete(recursive: true);
      } catch (e) {
        Log.e('Failed to delete regular file $linkPath -> $e', tag: 'EnvBootstrapper');
      }
    }

    try {
      await Link(linkPath).create(targetPath);
    } catch (e) {
      Log.e('Failed to create link ${label ?? linkPath} -> $e', tag: 'EnvBootstrapper');
    }
  }

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

    await Future.wait(
      nativeFiles.map(
        (item) => _ensureSymlink(
          '${RuntimeEnvir.binPath}/${item.targetName}',
          '$libPath/${item.soName}',
          label: item.targetName,
        ),
      ),
    );

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
      await Future.wait([
        ...links.map(
          (linkName) => _ensureSymlink(
            '${RuntimeEnvir.binPath}/$linkName',
            busyboxTarget,
            label: linkName,
          ),
        ),
        _ensureSymlink(
          '${RuntimeEnvir.binPath}/file',
          '/system/bin/file',
          label: 'file',
        ),
      ]);
    } catch (e) {
      Log.e('Create busybox links failed -> $e', tag: 'EnvBootstrapper');
    }
  }
}
