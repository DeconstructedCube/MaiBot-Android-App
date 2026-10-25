import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:global_repository/global_repository.dart';
import '../config/app_config.dart';
import '../constants/scripts.dart' as scripts;
import '../utils/file_utils.dart';

/// PRoot 执行结果封装
class ProotExecResult {
  final bool success;
  final int exitCode;
  final String stdout;
  final String stderr;
  final String output;

  const ProotExecResult({
    required this.success,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.output,
  });
}

/// 统一 PRoot 环境参数构建与进程执行服务（单一事实源 SSOT）
class ProotRunner {
  /// 虚拟 /proc 映射表（供 Dart 与 Native 容器环境统一遵循）
  static const List<List<String>> fakeProcEntries = [
    ['.loadavg', '/proc/loadavg'],
    ['.stat', '/proc/stat'],
    ['.uptime', '/proc/uptime'],
    ['.version', '/proc/version'],
    ['.vmstat', '/proc/vmstat'],
    ['.sysctl_entry_cap_last_cap', '/proc/sys/kernel/cap_last_cap'],
    ['.sysctl_inotify_max_user_watches', '/proc/sys/fs/inotify/max_user_watches'],
  ];

  /// 收集并构建虚拟 /proc 文件挂载列表，避免 Android 内核权限限制导致 Python/uv 崩溃
  static List<String> getFakeProcBindings() {
    final binds = <String>[];
    for (final pair in fakeProcEntries) {
      final fakeFile = File('${scripts.ubuntuPath}/proc/${pair.first}');
      if (fakeFile.existsSync()) {
        binds.addAll(['-b', '${fakeFile.path}:${pair.last}']);
      }
    }
    return binds;
  }

  /// 获取宿主机代理环境变量导出脚本片段（支持 VPN / 代理穿透）
  static String getProxyExportScript() {
    const envKeys = [
      'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
      'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    ];
    final proxyExports = StringBuffer();
    for (final key in envKeys) {
      final val = Platform.environment[key];
      if (val != null && val.isNotEmpty) {
        proxyExports.write('export $key="$val"; ');
      }
    }
    return proxyExports.toString();
  }

  /// 获取统一的 PRoot 环境变量映射（强制对齐 COLUMNS=45 与镜像源配置）
  static Map<String, String> getProotEnv({Map<String, String>? extraEnv}) {
    final env = <String, String>{
      'PROOT_TMP_DIR': RuntimeEnvir.tmpPath,
      'LD_LIBRARY_PATH': RuntimeEnvir.binPath,
      'PROOT_LOADER': '${RuntimeEnvir.binPath}/loader',
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'FORCE_COLOR': '1',
      'CLICOLOR_FORCE': '1',
      'CLICOLOR': '1',
      'PYTHONUNBUFFERED': '1',
      'PYTHONIOENCODING': 'utf-8',
      'PYTHON_COLORS': '1',
      'RICH_FORCE_COLOR': '1',
      'LOGURU_COLORIZE': 'true',
      'UV_COLOR': 'always',
      'UV_PROGRESS_MODE': 'visual',
      'UV_NO_PROGRESS': '0',
      'UV_INDEX_URL': MirrorRegistry.pypiPrimaryMirror,
      'PIP_NO_COLOR': '0',
      'COLUMNS': '45',
      'LINES': '24',
      'LANG': 'C.UTF-8',
      'LC_ALL': 'C.UTF-8',
      'DEBIAN_FRONTEND': 'noninteractive',
      'GIT_TERMINAL_PROMPT': '0',
      'UV_LINK_MODE': 'copy',
      'MAIBOT_LEGACY_0X_UPGRADE_CONFIRMED': '1',
      'TMPDIR': '/tmp',
      'TEMP': '/tmp',
      'TMP': '/tmp',
    };
    if (extraEnv != null) {
      env.addAll(extraEnv);
    }
    return env;
  }

  /// 构建完整的 PRoot CLI 启动参数列表
  static List<String> buildProotArgs({
    String scriptCommand = '',
    String workingDir = '/root',
    bool isInteractive = false,
  }) {
    Directory(RuntimeEnvir.tmpPath).createSync(recursive: true);
    final procBinds = getFakeProcBindings();
    final proxyScript = getProxyExportScript();

    final innerShellCommand = StringBuffer();
    innerShellCommand.write('export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ');
    innerShellCommand.write(proxyScript);
    innerShellCommand.write('mkdir -p /tmp /var/tmp; ');
    innerShellCommand.write('cd $workingDir; ');

    if (isInteractive) {
      innerShellCommand.write(
        'export HOME=/root; '
        'export PS1="\\u@maibot:\\w# "; '
        'if command -v script >/dev/null 2>&1; then '
        '    exec script -q -e -c "/bin/bash -i" /dev/null; '
        'elif [ -x /bin/bash ]; then '
        '    exec /bin/bash -i; '
        'else '
        '    exec /bin/sh -i; '
        'fi'
      );
    } else {
      innerShellCommand.write(scriptCommand);
    }

    return [
      '-0',
      '-r',
      scripts.ubuntuPath,
      '--link2symlink',
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '${RuntimeEnvir.tmpPath}:/tmp',
      '-b', '${RuntimeEnvir.tmpPath}:/dev/shm',
      ...procBinds,
      '-w', workingDir,
      '/bin/sh', '-c',
      innerShellCommand.toString(),
    ];
  }

  /// 在 PRoot 中执行单次命令并获取完整执行结果与流式日志
  static Future<ProotExecResult> runCommand(
    String command, {
    Function(String)? onLog,
    Duration timeout = const Duration(minutes: 10),
    String workingDir = '/root',
    Map<String, String>? extraEnv,
  }) async {
    final prootPath = '${RuntimeEnvir.binPath}/proot';
    final args = buildProotArgs(
      scriptCommand: command,
      workingDir: workingDir,
      isInteractive: false,
    );
    final env = getProotEnv(extraEnv: extraEnv);

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final allOutputBuffer = StringBuffer();

    try {
      if (onLog != null) {
        final process = await Process.start(prootPath, args, environment: env);

        process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
          (data) {
            stdoutBuffer.write(data);
            allOutputBuffer.write(data);
            onLog(data.toTerminalCrlf());
          },
          onError: (e) => Log.w('PRoot stdout read error: $e', tag: 'ProotRunner'),
        );

        process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
          (data) {
            stderrBuffer.write(data);
            allOutputBuffer.write(data);
            onLog(data.toTerminalCrlf());
          },
          onError: (e) => Log.w('PRoot stderr read error: $e', tag: 'ProotRunner'),
        );

        final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        });

        return ProotExecResult(
          success: exitCode == 0,
          exitCode: exitCode,
          stdout: stdoutBuffer.toString().trim(),
          stderr: stderrBuffer.toString().trim(),
          output: allOutputBuffer.toString().trim(),
        );
      } else {
        final res = await Process.run(prootPath, args, environment: env).timeout(timeout, onTimeout: () {
          return ProcessResult(-1, -1, '', 'Timed out');
        });

        return ProotExecResult(
          success: res.exitCode == 0,
          exitCode: res.exitCode,
          stdout: res.stdout.toString().trim(),
          stderr: res.stderr.toString().trim(),
          output: '${res.stdout}\n${res.stderr}'.trim(),
        );
      }
    } catch (e) {
      return ProotExecResult(
        success: false,
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        output: '执行失败: $e',
      );
    }
  }
}
