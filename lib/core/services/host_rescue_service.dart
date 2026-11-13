import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:global_repository/global_repository.dart';

import '../constants/scripts.dart' as scripts;
import '../utils/file_utils.dart';
import 'backend_process_manager.dart';

/// 宿主级文件急救与诊断服务：专门处理 WebUI 无法启动/被锁死时必须在宿主文件系统侧完成的恢复操作
class HostRescueService {
  static String get _defaultMaibotRoot => '${scripts.ubuntuPath}/root/MaiBot';

  static String generateHexToken({int byteLength = 32}) {
    final rng = Random.secure();
    final buffer = StringBuffer();
    for (int i = 0; i < byteLength; i++) {
      buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// 离线重置 WebUI 登录凭据与过期会话（解决忘记固定密码或会话库损坏导致的锁死问题）
  static Future<String> resetWebUiCredentials({
    String? maibotRoot,
    bool restartIfRunning = true,
  }) async {
    final root = maibotRoot ?? _defaultMaibotRoot;
    final hostDir = Directory('$root/host');
    final hostWebui = File('${hostDir.path}/webui.json');
    final legacyWebui = File('$root/data/webui.json');
    final sessionsDb = File('${hostDir.path}/sessions.sqlite3');
    final targetFile = await hostDir.exists() || !await legacyWebui.exists()
        ? hostWebui
        : legacyWebui;

    final newToken = generateHexToken();
    final payload = <String, dynamic>{
      'access_token': newToken,
      'token_source': 'temporary',
      'first_setup_completed': false,
    };

    Future<void> applyWrite() async {
      await targetFile.parent.create(recursive: true);
      final tmpFile = File('${targetFile.path}.tmp');
      await tmpFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tmpFile.rename(targetFile.path);
      if (await sessionsDb.exists()) {
        await sessionsDb.delete();
      }
    }

    if (restartIfRunning && await BackendProcessManager.isDaemonRunning()) {
      await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: true,
        action: applyWrite,
      );
    } else {
      await applyWrite();
    }

    return newToken;
  }

  /// 修复宿主 `host/config.toml`（恢复本机 127.0.0.1:8001 访问、重置过严的反爬拦截与错误 SSL 配置）
  static Future<void> repairHostWebUiConfig({
    String? maibotRoot,
    bool restartIfRunning = true,
  }) async {
    final root = maibotRoot ?? _defaultMaibotRoot;
    final configFile = File('$root/host/config.toml');

    const safeDefaultConfig = '''[webui]
enabled = true
hosts = ["127.0.0.1", "::1"]
port = 8001
public_base_url = ""
ssl_certfile = ""
ssl_keyfile = ""
secure_cookie = false
anti_crawler_mode = "basic"
allowed_ips = "127.0.0.1"
trusted_proxies = ""
trust_xff = false
''';

    Future<void> applyWrite() async {
      await configFile.parent.create(recursive: true);
      if (await configFile.exists()) {
        await configFile.copy('${configFile.path}.bak');
      }
      await configFile.writeAsString(safeDefaultConfig);
    }

    if (restartIfRunning && await BackendProcessManager.isDaemonRunning()) {
      await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: true,
        action: applyWrite,
      );
    } else {
      await applyWrite();
    }
  }

  /// 清理容器异常退出或 OOM 后残留的租约锁与控制描述文件
  static Future<int> cleanStaleLocks({
    String? maibotRoot,
    bool restartAfter = true,
  }) async {
    final root = maibotRoot ?? _defaultMaibotRoot;
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return 0;

    Future<int> removeLocks() async {
      int removed = 0;
      const explicitTargets = [
        'host/run.lock',
        'host/control.json',
        'host/model-config.lock',
        'data/.a_memorix_runtime_writer.lock',
      ];
      for (final rel in explicitTargets) {
        final f = File('$root/$rel');
        if (await f.exists()) {
          await f.delete();
          removed++;
        }
      }

      final botsDir = Directory('$root/bots');
      if (await botsDir.exists()) {
        await for (final entity in botsDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final name = entity.uri.pathSegments.last;
            if (name.endsWith('.lock') || name == 'instance.lock') {
              try {
                await entity.delete();
                removed++;
              } catch (_) {}
            }
          }
        }
      }
      return removed;
    }

    if (restartAfter && await BackendProcessManager.isDaemonRunning()) {
      return await BackendProcessManager.runMaintenanceTransaction(
        autoRestart: true,
        action: removeLocks,
      );
    }
    return await removeLocks();
  }

  /// 导出脱敏诊断日志包至公共下载目录（自动排除 webui.json 密钥与 sessions.sqlite3 会话库）
  static Future<File?> exportDiagnosticsBundle({
    String? maibotRoot,
    String? terminalLogText,
  }) async {
    final root = maibotRoot ?? _defaultMaibotRoot;
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return null;

    final outDir = getMaiBotBackupDirectory();
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final now = DateTime.now();
    final ts =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final stagingDir = Directory('${RuntimeEnvir.tmpPath}/diag_$ts');
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    try {
      if (terminalLogText != null && terminalLogText.isNotEmpty) {
        await File('${stagingDir.path}/app_terminal.log')
            .writeAsString(terminalLogText);
      }

      for (final rel in ['host/config.toml', 'host/registry.sqlite3']) {
        final src = File('$root/$rel');
        if (await src.exists()) {
          final dst = File('${stagingDir.path}/$rel');
          await dst.parent.create(recursive: true);
          await src.copy(dst.path);
        }
      }

      Future<void> copyRecentLogs(Directory srcLogDir, String targetPrefix) async {
        if (!await srcLogDir.exists()) return;
        final logFiles = <({File file, DateTime modified})>[];
        await for (final entity in srcLogDir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.log')) {
            try {
              final stat = await entity.stat();
              logFiles.add((file: entity, modified: stat.modified));
            } catch (_) {}
          }
        }
        logFiles.sort((a, b) => b.modified.compareTo(a.modified));
        for (final entry in logFiles.take(5)) {
          final rel = entry.file.path.substring(srcLogDir.path.length + 1);
          final dst = File('${stagingDir.path}/$targetPrefix/$rel');
          await dst.parent.create(recursive: true);
          await entry.file.copy(dst.path);
        }
      }

      await copyRecentLogs(Directory('$root/logs'), 'root_logs');

      final botsDir = Directory('$root/bots');
      if (await botsDir.exists()) {
        await for (final botDir in botsDir.list(followLinks: false)) {
          if (botDir is! Directory) continue;
          final botId = botDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
          for (final rel in ['temp/worker-console.log', 'temp/host-status.json']) {
            final src = File('${botDir.path}/$rel');
            if (await src.exists()) {
              final dst = File('${stagingDir.path}/bots/$botId/$rel');
              await dst.parent.create(recursive: true);
              await src.copy(dst.path);
            }
          }
          await copyRecentLogs(Directory('${botDir.path}/logs'), 'bots/$botId/logs');
        }
      }

      final outFilePath = '${outDir.path}/MaiBot-diagnostics-$ts.tar.gz';
      final res = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-czf',
        outFilePath,
        '-C',
        stagingDir.path,
        '.',
      ]);

      if (res.exitCode == 0) {
        final outFile = File(outFilePath);
        if (await outFile.exists()) return outFile;
      }
      return null;
    } finally {
      try {
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
