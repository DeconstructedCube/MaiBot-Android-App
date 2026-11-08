import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';

import '../config/app_config.dart';
import '../constants/scripts.dart' as scripts;
import '../state/app_lifecycle_state_machine.dart';
import 'proot_runner.dart';

class InstallerService {
  /// 记录当前流水线是否为首次/全新安装
  static bool lastInstallWasFresh = false;

  /// NapCat 重装时的一次性临时备份文件路径
  static String get napcatTempBackupPath =>
      '${RuntimeEnvir.homePath}/.napcat_reinstall_backup.tar.gz';

  /// 检查 Ubuntu 根文件系统是否已就绪
  static bool isRootfsReady() {
    final ubuntuDir = Directory(scripts.ubuntuPath);
    final rootfsMarker = File('${scripts.ubuntuPath}/.rootfs_ready');
    if (ubuntuDir.existsSync() && rootfsMarker.existsSync()) {
      final coreFile = File('${scripts.ubuntuPath}/bin/bash');
      return coreFile.existsSync();
    }
    return false;
  }
  /// 检查容器、核心组件、MaiBot、NapCat 以及 Python 虚拟环境是否已经全量就绪
  static bool isEnvironmentFullyInstalled() {
    if (!isRootfsReady()) return false;

    final uvExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uv');
    final maibotDir = Directory('${scripts.ubuntuPath}/root/MaiBot');
    final botPy = File('${maibotDir.path}/bot.py');
    final pyproject = File('${maibotDir.path}/pyproject.toml');
    final adapterDir = Directory('${scripts.ubuntuPath}/root/MaiBot/plugins/MaiBot-Napcat-Adapter');
    final venvDir = Directory('${scripts.ubuntuPath}/root/MaiBot/.venv');
    final venvMarker = File('${scripts.ubuntuPath}/root/MaiBot/.venv_sync_ready');
    final napcatDir = Directory('${scripts.ubuntuPath}/root/napcat');
    final napcatEntry = File('${napcatDir.path}/napcat.mjs');
    final qqBinary = File('${scripts.ubuntuPath}/opt/QQ/qq');
    final launcherSh = File('${scripts.ubuntuPath}/root/launcher.sh');

    return uvExecutable.existsSync() &&
        maibotDir.existsSync() &&
        botPy.existsSync() &&
        pyproject.existsSync() &&
        adapterDir.existsSync() &&
        venvDir.existsSync() &&
        venvMarker.existsSync() &&
        napcatDir.existsSync() &&
        napcatEntry.existsSync() &&
        qqBinary.existsSync() &&
        launcherSh.existsSync();
  }


  static const int totalRootfsFiles = 12684;

  static Future<bool> runInstallPipeline({
    required void Function(String message, [double? ratio]) onProgress,
    void Function(InstallStage stage, String message)? onStage,
    Function(String)? onLog,
  }) async {
    void reportStage(InstallStage stage, [String? customMessage]) {
      final msg = customMessage ?? stage.defaultLabel;
      onStage?.call(stage, msg);
      onProgress(msg);
    }

    final ubuntuDir = Directory(scripts.ubuntuPath);

    // 1. 原生解压 (Native Extraction)
    final rootfsMarker = File('${scripts.ubuntuPath}/.rootfs_ready');
    final bool isExtracted = isRootfsReady();

    lastInstallWasFresh = !isExtracted;
    // 核心优化：若系统已经全量就绪（非初次安装且所有核心组件完好），直接跳过冗余的网络测速与依赖检查
    if (isExtracted && isEnvironmentFullyInstalled()) {
      // 启动前确保 uv 和 pip 软链接自愈就绪
      try {
        final uvGlobal = File('${scripts.ubuntuPath}/usr/local/bin/uv');
        final uvLocal = File('${scripts.ubuntuPath}/root/.local/bin/uv');
        if (uvLocal.existsSync() && !uvGlobal.existsSync()) {
          await Process.run('${RuntimeEnvir.binPath}/busybox', ['ln', '-sf', '/root/.local/bin/uv', '${scripts.ubuntuPath}/usr/local/bin/uv']);
          await Process.run('${RuntimeEnvir.binPath}/busybox', ['ln', '-sf', '/root/.local/bin/uvx', '${scripts.ubuntuPath}/usr/local/bin/uvx']);
        }
        final pipGlobal = File('${scripts.ubuntuPath}/usr/local/bin/pip');
        final pipVenv = File('${scripts.ubuntuPath}/root/MaiBot/.venv/bin/pip');
        if (pipVenv.existsSync() && !pipGlobal.existsSync()) {
          await Process.run('${RuntimeEnvir.binPath}/busybox', ['ln', '-sf', '/root/MaiBot/.venv/bin/pip', '${scripts.ubuntuPath}/usr/local/bin/pip']);
        }
      } catch (_) {}
      reportStage(InstallStage.completed, '准备启动服务...');
      return true;
    }


    if (!isExtracted) {
      if (await ubuntuDir.exists()) {
        try {
          await ubuntuDir.delete(recursive: true);
        } catch (_) {}
      }
      reportStage(InstallStage.extractingRootfs, '解压 Ubuntu 系统...');
      try {
        final archivePath = '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}';
        final archiveFile = File(archivePath);
        final targetPath = '${scripts.prootDistroPath}/installed-rootfs';

        await Directory(targetPath).create(recursive: true);

        // 1.1 校验或从应用 assets 释放镜像归档
        if (!await archiveFile.exists() || await archiveFile.length() < 1000000) {
          onLog?.call('\x1b[36m[系统]\x1b[0m 准备镜像文件 (62MB)...\r\n');
          onProgress('准备镜像文件...', 0.0);
          try {
            final ByteData byteData = await rootBundle.load('assets/${Config.ubuntuFileName}');
            final Uint8List picBytes = byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            );
            await archiveFile.parent.create(recursive: true);
            await archiveFile.writeAsBytes(picBytes, flush: true);
            final mb = (picBytes.length / (1024 * 1024)).toStringAsFixed(1);
            onLog?.call('\x1b[32m[系统]\x1b[0m 镜像已就绪 (${mb}MB)\r\n');
          } catch (e) {
            onLog?.call('\x1b[31m[错误]\x1b[0m 读取镜像文件失败: $e\r\n');
            return false;
          }
        }

        // 1.2 执行 tar 解压并实时流式输出日志与平滑进度
        final args = ['tar', '-xJvf', archivePath, '-C', targetPath];
        onLog?.call('\x1b[36m[解压]\x1b[0m 解压系统文件...\r\n');

        final busyboxPath = '${RuntimeEnvir.binPath}/busybox';
        if (onLog != null) {
          final process = await Process.start(busyboxPath, args);
          int extractedFiles = 0;
          int lastLoggedPct = 0;

          process.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen((_) {
            extractedFiles++;
            final double ratio = (extractedFiles / totalRootfsFiles).clamp(0.0, 1.0);
            final int currentPctInt = (ratio * 100).toInt();

            if (extractedFiles % 100 == 0 || extractedFiles == totalRootfsFiles) {
              final String pct = (ratio * 100).toStringAsFixed(1);
              onProgress('解压系统文件 $pct%...', ratio);
            }

            if ((currentPctInt > lastLoggedPct && currentPctInt % 10 == 0) ||
                extractedFiles == totalRootfsFiles) {
              lastLoggedPct = currentPctInt;
              final String pct = (ratio * 100).toStringAsFixed(1);
              onLog('\x1b[32m[解压]\x1b[0m $pct% ($extractedFiles/$totalRootfsFiles)\r\n');
            }
          });

          process.stderr
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen((line) {
            if (!line.contains('chown') &&
                !line.contains('mknod') &&
                !line.contains('Operation not permitted')) {
              onLog('\x1b[33m[警告]\x1b[0m $line\r\n');
            }
          });

          final exitCode = await process.exitCode;
          if (exitCode != 0) {
            onLog('\x1b[31m[错误]\x1b[0m 解压失败，退出码: $exitCode\r\n');
            return false;
          }
          onLog('\x1b[32m[解压]\x1b[0m 解压完成\r\n');
          onProgress('解压完成', 1.0);
        } else {
          final res = await Process.run(busyboxPath, args);
          if (res.exitCode != 0) {
            return false;
          }
        }

        // 1.3 目录重命名与完整性校验
        final extractedDir = Directory('$targetPath/${scripts.ubuntuName}');
        final targetDir = Directory(scripts.ubuntuPath);
        if (await targetDir.exists()) {
          try {
            await targetDir.delete(recursive: true);
          } catch (_) {}
        }
        if (await extractedDir.exists()) {
          await extractedDir.rename(scripts.ubuntuPath);
          onLog?.call('\x1b[32m[系统]\x1b[0m 安装路径: ${scripts.ubuntuPath}\r\n');
        }

        final bashCheck = File('${scripts.ubuntuPath}/bin/bash');
        if (!await bashCheck.exists()) {
          onLog?.call('\x1b[31m[错误]\x1b[0m 校验失败: 未找到 bin/bash\r\n');
          return false;
        }

        await rootfsMarker.writeAsString('ready');
        onLog?.call('\x1b[32m[系统]\x1b[0m 校验通过\r\n');

        // 1.4 清理 62MB 安装包归档
        try {
          if (await archiveFile.exists()) {
            await archiveFile.delete();
            onLog?.call('\x1b[32m[系统]\x1b[0m 清理临时镜像文件\r\n');
          }
        } catch (_) {}
      } catch (e) {
        onLog?.call('\x1b[31m[错误]\x1b[0m 解压异常: $e\r\n');
        Log.e('解压过程发生异常: $e', tag: 'InstallerService');
        return false;
      }
    }

    // 2. 配置环境（仅单次执行）
    reportStage(InstallStage.configuringNetwork, '配置系统环境...');
    await _writeNetworkConfigs(onLog);

    // 2.1 测速选线
    await MirrorRegistry.probeFastestMirrors(onLog: onLog);

    // 2.2 基础依赖安装
    final depSuccess = await _ensureSystemDependencies(
      (msg) => reportStage(InstallStage.checkingSystemDeps, msg),
      onLog,
    );
    if (!depSuccess) {
      Log.e('系统基础依赖安装失败', tag: 'InstallerService');
      return false;
    }

    try {
      // 3. 安装 uv
      final uvExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uv');
      final uvxExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uvx');
      if (!await uvExecutable.exists() ||
          await uvExecutable.length() < 10000 ||
          !await uvxExecutable.exists()) {
        reportStage(InstallStage.installingUv, '安装 uv 工具...');
        final success = await _downloadAndInstallUv(onLog);
        if (!success) return false;
      }

      // 4. 克隆 MaiBot
      final maibotDir = Directory('${scripts.ubuntuPath}/root/MaiBot');
      final botPy = File('${maibotDir.path}/bot.py');
      final pyproject = File('${maibotDir.path}/pyproject.toml');
      if (!await maibotDir.exists() ||
          !await botPy.exists() ||
          !await pyproject.exists()) {
        if (await maibotDir.exists()) {
          await _runInProot('rm -rf /root/MaiBot');
        }
        reportStage(InstallStage.cloningMaibot, '下载 MaiBot 源码...');
        final success = await _cloneMaibot(onLog);
        if (!success) return false;
      }

      // 4.5 默认适配器克隆
      final pluginsDir = Directory('${scripts.ubuntuPath}/root/MaiBot/plugins');
      final adapterDir = Directory('${pluginsDir.path}/MaiBot-Napcat-Adapter');
      final adapterMain = File('${adapterDir.path}/adapter.py');
      final adapterPlugin = File('${adapterDir.path}/plugin.py');
      final adapterManifest = File('${adapterDir.path}/_manifest.json');
      final adapterInit = File('${adapterDir.path}/__init__.py');

      if (!await adapterDir.exists() ||
          (!await adapterMain.exists() &&
              !await adapterPlugin.exists() &&
              !await adapterManifest.exists() &&
              !await adapterInit.exists())) {
        if (await adapterDir.exists()) {
          await _runInProot('rm -rf /root/MaiBot/plugins/MaiBot-Napcat-Adapter');
        }
        reportStage(InstallStage.cloningAdapter, '安装适配器插件...');
        bool cloneSuccess = false;
        for (final mirror in MirrorRegistry.activeGithubPrefixMirrors) {
          final adapterUrl =
              '${mirror}https://github.com/Mai-with-u/MaiBot-Napcat-Adapter.git';
          final label = mirror.isEmpty ? '官方源' : mirror;
          onLog?.call('\x1b[36m[下载]\x1b[0m 适配器 ($label)...\r\n');
          await _runInProot('rm -rf /root/MaiBot/plugins/MaiBot-Napcat-Adapter');
          final res = await _runInProot(
            'git -c gc.auto=0 clone --depth=1 --branch main $adapterUrl /root/MaiBot/plugins/MaiBot-Napcat-Adapter',
            onLog: onLog,
            timeout: const Duration(minutes: 3),
          );
          if (res) {
            cloneSuccess = true;
            break;
          }
        }
        if (!cloneSuccess) {
          onLog?.call('\x1b[31m[错误]\x1b[0m 适配器安装失败，请检查网络\r\n');
          return false;
        }

        final adapterConfig = File('${adapterDir.path}/config.toml');
        if (await adapterConfig.exists()) {
          await adapterConfig.delete();
        }
      }

      // 5. 同步 Python 依赖库
      final venvDir = Directory('${scripts.ubuntuPath}/root/MaiBot/.venv');
      final venvMarker = File('${scripts.ubuntuPath}/root/MaiBot/.venv_sync_ready');
      final bool hasVenv = await venvDir.exists() && await venvMarker.exists();
      if (!hasVenv) {
        if (await venvDir.exists()) {
          await _runInProot('rm -rf /root/MaiBot/.venv');
        }
        reportStage(
          InstallStage.syncingPythonEnv,
          '安装 Python 依赖...',
        );
        final pypiPrimary = MirrorRegistry.activePypiMirror;
        final uvSyncCmd = 'export UV_HTTP_TIMEOUT=60; cd /root/MaiBot && '
            'if command -v script >/dev/null 2>&1; then '
            '  script -q -e -c "stty cols 45 rows 24 2>/dev/null; /root/.local/bin/uv sync --color always --default-index $pypiPrimary --extra-index-url https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://pypi.org/simple" /dev/null; '
            'else '
            '  /root/.local/bin/uv sync --color always --default-index $pypiPrimary --extra-index-url https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://pypi.org/simple; '
            'fi';
        var success = await _runInProot(uvSyncCmd, onLog: onLog, timeout: const Duration(minutes: 8));
        if (!success) {
          onLog?.call('\x1b[33m[Python]\x1b[0m 依赖同步重试中...\r\n');
          final fallbackCmd = 'export UV_HTTP_TIMEOUT=90; cd /root/MaiBot && /root/.local/bin/uv sync --color always --default-index https://pypi.org/simple --extra-index-url https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple';
          success = await _runInProot(fallbackCmd, onLog: onLog, timeout: const Duration(minutes: 8));
        }
        if (!success) return false;
        await venvMarker.writeAsString('ready');
        // 为虚拟环境安装标准的 pip / setuptools / wheel 工具，支持终端中直接 pip install
        onLog?.call('\x1b[36m[Python]\x1b[0m 为虚拟环境配置 pip 工具...\r\n');
        await _runInProot(
          'cd /root/MaiBot && /root/.local/bin/uv pip install pip setuptools wheel --python /root/MaiBot/.venv/bin/python --default-index $pypiPrimary --extra-index-url https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://pypi.org/simple',
          onLog: onLog,
        );
        await _runInProot(
          'ln -sf /root/MaiBot/.venv/bin/pip /usr/local/bin/pip; ln -sf /root/MaiBot/.venv/bin/python /usr/local/bin/python',
        );
      }

      // 6. 安装 NapCat（直接使用 Fork 维护仓库安装脚本）
      final napcatDir = Directory('${scripts.ubuntuPath}/root/napcat');
      final qqBinary = File('${scripts.ubuntuPath}/opt/QQ/qq');
      final launcherSh = File('${scripts.ubuntuPath}/root/launcher.sh');
      final napcatEntry = File('${napcatDir.path}/napcat.mjs');
      if (!await napcatDir.exists() ||
          !await qqBinary.exists() ||
          !await launcherSh.exists() ||
          !await napcatEntry.exists()) {
        final tempBackup = File(napcatTempBackupPath);
        final configDir = Directory('${scripts.ubuntuPath}/root/napcat/config');
        if (await napcatDir.exists()) {
          if (!await tempBackup.exists() && await configDir.exists()) {
            onLog?.call('\x1b[33m[NapCat]\x1b[0m 暂存配置文件...\r\n');
            await Process.run('${RuntimeEnvir.binPath}/busybox', [
              'tar',
              '-czf',
              napcatTempBackupPath,
              '-C',
              '${scripts.ubuntuPath}/root',
              'napcat/config',
            ]);
          }
          onLog?.call('\x1b[33m[NapCat]\x1b[0m 清理旧目录...\r\n');
          await Process.run(
              '${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', napcatDir.path]);
        }

        reportStage(InstallStage.installingNapcat, '安装 NapCat 组件...');
        await _runInProot(
          'dpkg --configure -a || true && apt-get --fix-broken install -y',
          onLog: onLog,
        );

        bool downloaded = false;
        for (final mirror in MirrorRegistry.activeGithubPrefixMirrors) {
          final url =
              '${mirror}https://raw.githubusercontent.com/DeconstructedCube/napcat-linux-installer/refs/heads/main/install.sh';
          final label = mirror.isEmpty ? '官方源' : mirror;
          onLog?.call('\x1b[36m[NapCat]\x1b[0m 正在从 $label 获取安装脚本...\r\n');
          final res = await _runInProot(
            'curl -sL -f --connect-timeout 10 --max-time 30 -o /root/napcat.sh $url',
            onLog: onLog,
            timeout: const Duration(seconds: 40),
          );
          if (res) {
            downloaded = true;
            break;
          }
        }
        if (!downloaded) {
          onLog?.call('\x1b[31m[错误]\x1b[0m 获取 NapCat 安装脚本失败，请检查网络\r\n');
          return false;
        }

        final success = await _runInProot('bash /root/napcat.sh', onLog: onLog);
        if (!success) return false;

        await _restoreAndCleanNapcatTempBackup(
          (msg) => reportStage(InstallStage.restoringBackup, msg),
          onLog,
        );
      }

      reportStage(InstallStage.completed, '准备启动服务...');
      return true;
    } catch (e) {
      Log.e('后续配置执行异常: $e', tag: 'InstallerService');
      return false;
    }
  }

  /// 从 assets/scripts/ 部署外置脚本到容器目录并赋予可执行权限
  static Future<void> _deployAssetScript(
    String assetKey,
    String targetPath,
  ) async {
    try {
      final scriptContent = await rootBundle.loadString(assetKey);
      final targetFile = File(targetPath);
      await targetFile.writeAsString(scriptContent);
      await Process.run('${RuntimeEnvir.binPath}/busybox', ['chmod', '+x', targetPath]);
    } catch (e) {
      Log.w('Failed to deploy script $assetKey: $e', tag: 'InstallerService');
    }
  }

  static Future<void> _writeNetworkConfigs(Function(String)? onLog) async {
    try {
      await Directory('${scripts.ubuntuPath}/tmp').create(recursive: true);
      await Directory('${scripts.ubuntuPath}/var/tmp').create(recursive: true);
      await Directory('${scripts.ubuntuPath}/etc/ssl/certs').create(recursive: true);
      await Directory('${scripts.ubuntuPath}/var/cache/apt/archives/partial').create(recursive: true);
      await Directory('${scripts.ubuntuPath}/var/lib/apt/lists/partial').create(recursive: true);
      await Directory(RuntimeEnvir.tmpPath).create(recursive: true);

      onLog?.call('\x1b[32m[DNS]\x1b[0m 写入域名解析配置\r\n');
      final resolvConf = File('${scripts.ubuntuPath}/etc/resolv.conf');
      final dnsLines =
          '${MirrorRegistry.dnsNameservers.map((ip) => 'nameserver $ip').join('\n')}\n';
      await resolvConf.writeAsString(dnsLines);

      final aptConfDir = Directory('${scripts.ubuntuPath}/etc/apt/apt.conf.d');
      await aptConfDir.create(recursive: true);

      final speedupConf = File('${aptConfDir.path}/99speedup');
      await speedupConf.writeAsString(
        'APT::Install-Recommends "false";\n'
        'APT::Install-Suggests "false";\n'
        'Acquire::Languages "none";\n'
        'Acquire::Check-Valid-Until "false";\n'
        'Acquire::http::Timeout "10";\n'
        'Acquire::https::Timeout "10";\n'
        'Acquire::Retries "3";\n'
        'Acquire::http::Pipeline-Depth "0";\n'
        'Dir::Cache::pkgcache "";\n'
        'Dir::Cache::srcpkgcache "";\n',
      );

      final dpkgConfDir = Directory('${scripts.ubuntuPath}/etc/dpkg/dpkg.cfg.d');
      await dpkgConfDir.create(recursive: true);
      final dpkgSpeedup = File('${dpkgConfDir.path}/02apt-speedup');
      await dpkgSpeedup.writeAsString('force-unsafe-io\n');

      final dpkgNoDoc = File('${dpkgConfDir.path}/01nodoc');
      await dpkgNoDoc.writeAsString(
        'path-exclude /usr/share/doc/*\n'
        'path-exclude /usr/share/man/*\n'
        'path-exclude /usr/share/groff/*\n'
        'path-exclude /usr/share/info/*\n'
        'path-exclude /usr/share/lintian/*\n'
        'path-exclude /usr/share/linda/*\n'
        'path-exclude /usr/share/locale/*\n',
      );

      final localBinDir = Directory('${scripts.ubuntuPath}/usr/local/bin');
      await localBinDir.create(recursive: true);

      await Future.wait([
        _deployAssetScript('assets/scripts/apt_fast.sh', '${localBinDir.path}/apt-fast'),
        _deployAssetScript('assets/scripts/curl_wrapper.sh', '${localBinDir.path}/curl'),
        _deployAssetScript('assets/scripts/wget_wrapper.sh', '${localBinDir.path}/wget'),
        _deployAssetScript('assets/scripts/git_ops.sh', '${localBinDir.path}/maibot-git-ops'),
      ]);

      final aptGetLink = Link('${localBinDir.path}/apt-get');
      if (!await aptGetLink.exists()) {
        try {
          await aptGetLink.create('apt-fast');
        } catch (_) {}
      }
      final aptLink = Link('${localBinDir.path}/apt');
      if (!await aptLink.exists()) {
        try {
          await aptLink.create('apt-fast');
        } catch (_) {}
      }

      final gitConfig = File('${scripts.ubuntuPath}/etc/gitconfig');
      await gitConfig.writeAsString(
        '[http]\n'
        '    lowSpeedLimit = 1000\n'
        '    lowSpeedTime = 20\n'
        '    postBuffer = 524288000\n'
        '[credential]\n'
        '    helper = store\n',
      );

      final pipConfig = File('${scripts.ubuntuPath}/etc/pip.conf');
      await pipConfig.writeAsString(
        '[global]\n'
        'index-url = ${MirrorRegistry.activePypiMirror}\n'
        'extra-index-url = ${MirrorRegistry.pypiExtraMirrors}\n'
        'timeout = 30\n',
      );

      final npmrc = File('${scripts.ubuntuPath}/root/.npmrc');
      await npmrc.writeAsString(
        'registry=https://registry.npmmirror.com\n'
        'disturl=https://npmmirror.com/mirrors/node\n'
        'canvas_binary_host_mirror=https://npmmirror.com/mirrors/canvas\n',
      );

      final uvConfigDir = Directory('${scripts.ubuntuPath}/root/.config/uv');
      await uvConfigDir.create(recursive: true);
      final uvToml = File('${uvConfigDir.path}/uv.toml');
      await uvToml.writeAsString(
        '[[index]]\n'
        'url = "${MirrorRegistry.activePypiMirror}"\n'
        'default = true\n',
      );

      final procDir = Directory('${scripts.ubuntuPath}/proc');
      await procDir.create(recursive: true);
      final loadavg = File('${procDir.path}/.loadavg');
      if (!await loadavg.exists()) {
        await loadavg.writeAsString('0.12 0.07 0.02 2/165 765\n');
      }
      final stat = File('${procDir.path}/.stat');
      if (!await stat.exists()) {
        await stat.writeAsString('cpu  1957 0 2877 93280 262 342 254 87 0 0\n');
      }
      final uptime = File('${procDir.path}/.uptime');
      if (!await uptime.exists()) {
        await uptime.writeAsString('12345.67 890.12\n');
      }
      final vmstat = File('${procDir.path}/.vmstat');
      if (!await vmstat.exists()) {
        await vmstat.writeAsString('nr_free_pages 100000\n');
      }
      final meminfo = File('${procDir.path}/.meminfo');
      if (!await meminfo.exists()) {
        await meminfo.writeAsString(
          'MemTotal:        8192000 kB\n'
          'MemFree:         4096000 kB\n'
          'MemAvailable:    5120000 kB\n'
          'Buffers:          200000 kB\n'
          'Cached:          2000000 kB\n'
          'SwapTotal:             0 kB\n'
          'SwapFree:              0 kB\n',
        );
      }
      final version = File('${procDir.path}/.version');
      if (!await version.exists()) {
        await version.writeAsString(
          'Linux version 5.15.0-maibot (android@container) (gcc 11.2.0) #1 SMP PREEMPT\n',
        );
      }
      final cpuinfo = File('${procDir.path}/.cpuinfo');
      if (!await cpuinfo.exists()) {
        await cpuinfo.writeAsString(
          'processor\t: 0\n'
          'BogoMIPS\t: 38.40\n'
          'Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp\n'
          'CPU implementer\t: 0x41\n'
          'CPU architecture: 8\n'
          'CPU variant\t: 0x1\n'
          'CPU part\t: 0xd05\n'
          'CPU revision\t: 0\n\n'
          'Hardware\t: MaiBot Android Virtual ARM64\n',
        );
      }
      final capLastCap = File('${procDir.path}/.sysctl_entry_cap_last_cap');
      if (!await capLastCap.exists()) {
        await capLastCap.writeAsString('63\n');
      }
      final inotifyWatches = File('${procDir.path}/.sysctl_inotify_max_user_watches');
      if (!await inotifyWatches.exists()) {
        await inotifyWatches.writeAsString('1048576\n');
      }

      await _writeSourcesList(MirrorRegistry.aptPortMirrors.first, onLog);
    } catch (e) {
      Log.e('Failed to write network configs: $e', tag: 'InstallerService');
    }
  }

  static Future<void> _writeSourcesList(String mirrorUrl, Function(String)? onLog) async {
    try {
      onLog?.call('\x1b[32m[源]\x1b[0m 软件源: $mirrorUrl\r\n');
      final sourcesList = File('${scripts.ubuntuPath}/etc/apt/sources.list');
      await sourcesList.writeAsString(
        'deb $mirrorUrl noble main restricted universe multiverse\n'
        'deb $mirrorUrl noble-updates main restricted universe multiverse\n'
        'deb $mirrorUrl noble-security main restricted universe multiverse\n',
      );
    } catch (e) {
      Log.e('Failed to write sources.list: $e', tag: 'InstallerService');
    }
  }

  static Future<bool> _ensureSystemDependencies(
    Function(String) onProgress,
    Function(String)? onLog,
  ) async {
    final gitBinary = File('${scripts.ubuntuPath}/usr/bin/git');
    final curlBinary = File('${scripts.ubuntuPath}/usr/bin/curl');
    final wgetBinary = File('${scripts.ubuntuPath}/usr/bin/wget');
    final sudoBinary = File('${scripts.ubuntuPath}/usr/bin/sudo');
    final aria2Binary = File('${scripts.ubuntuPath}/usr/bin/aria2c');

    if (await gitBinary.exists() &&
        await curlBinary.exists() &&
        await wgetBinary.exists() &&
        await sudoBinary.exists() &&
        await aria2Binary.exists()) {
      return true;
    }

    onProgress('检查系统依赖...');

    for (int i = 0; i < MirrorRegistry.aptPortMirrors.length; i++) {
      final mirror = MirrorRegistry.aptPortMirrors[i];
      if (i > 0) {
        onLog?.call('\x1b[33m[源]\x1b[0m 切换备用源: $mirror\r\n');
        await _writeSourcesList(mirror, null);
      }

      const repairCmd =
          'mkdir -p /tmp /var/tmp /etc/ssl/certs && chmod 1777 /tmp /var/tmp; '
          'export TMPDIR=/tmp; export TEMP=/tmp; export TMP=/tmp; export DEBIAN_FRONTEND=noninteractive; '
          'dpkg --configure -a || true; '
          'apt-get --fix-broken install -y || true; '
          'apt-get update && apt-get install -y --no-install-recommends sudo wget git curl ca-certificates aria2 build-essential';

      final success = await _runInProot(
        repairCmd,
        onLog: onLog,
        timeout: const Duration(minutes: 5),
      );
      if (success && await gitBinary.exists() && await curlBinary.exists()) {
        return true;
      }
    }

    return await gitBinary.exists();
  }

  static Future<bool> _downloadAndInstallUv(Function(String)? onLog) async {
    final tmpArchive = '${RuntimeEnvir.tmpPath}/uv-aarch64.tar.gz';
    const releaseUrl =
        'https://github.com/astral-sh/uv/releases/download/0.9.9/uv-aarch64-unknown-linux-gnu.tar.gz';

    bool downloaded = false;
    for (final mirror in MirrorRegistry.activeGithubPrefixMirrors) {
      final target = '$mirror$releaseUrl';
      final label = mirror.isEmpty ? '官方源' : mirror;
      onLog?.call('\x1b[36m[下载]\x1b[0m uv ($label)...\r\n');

      if (onLog != null) {
        final process = await Process.start(
            '${RuntimeEnvir.binPath}/busybox', ['wget', '-T', '15', '-O', tmpArchive, target]);
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen((data) => onLog(data.replaceAll('\n', '\r\n')));
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen((data) => onLog(data.replaceAll('\n', '\r\n')));
        final exitCode = await process.exitCode;
        if (exitCode == 0) {
          downloaded = true;
          break;
        }
      } else {
        final res = await Process.run(
            '${RuntimeEnvir.binPath}/busybox', ['wget', '-T', '15', '-O', tmpArchive, target]);
        if (res.exitCode == 0) {
          downloaded = true;
          break;
        }
      }
    }

    if (!downloaded) {
      onLog?.call('\x1b[31m[错误]\x1b[0m uv 下载失败，请检查网络\r\n');
      return false;
    }

    onLog?.call('\x1b[32m[解压]\x1b[0m uv 解压中...\r\n');
    final extractRes = await Process.run('${RuntimeEnvir.binPath}/busybox', [
      'tar',
      '-xzf',
      tmpArchive,
      '-C',
      RuntimeEnvir.tmpPath,
    ]);

    if (extractRes.exitCode == 0) {
      final localBin = Directory('${scripts.ubuntuPath}/root/.local/bin');
      await localBin.create(recursive: true);

      await File('${RuntimeEnvir.tmpPath}/uv-aarch64-unknown-linux-gnu/uv')
          .copy('${localBin.path}/uv');
      await File('${RuntimeEnvir.tmpPath}/uv-aarch64-unknown-linux-gnu/uvx')
          .copy('${localBin.path}/uvx');
      await Process.run('${RuntimeEnvir.binPath}/busybox',
          ['chmod', '+x', '${localBin.path}/uv', '${localBin.path}/uvx']);
      // 同时软链至 /usr/local/bin，确保系统任意路径与子进程输入 uv 均立即可用
      try {
        final usrLocalBin = Directory('${scripts.ubuntuPath}/usr/local/bin');
        await usrLocalBin.create(recursive: true);
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['ln', '-sf', '/root/.local/bin/uv', '${scripts.ubuntuPath}/usr/local/bin/uv']);
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['ln', '-sf', '/root/.local/bin/uvx', '${scripts.ubuntuPath}/usr/local/bin/uvx']);
      } catch (_) {}
      return true;
    }
    return false;
  }

  static Future<bool> _cloneMaibot(Function(String)? onLog) async {
    final Setting customGitCloneSetting = 'custom_git_clone_url'.setting;
    final String customRepoUrl = customGitCloneSetting.get() ?? '';

    final mirrors = customRepoUrl.isNotEmpty
        ? ['']
        : MirrorRegistry.activeGithubPrefixMirrors;
    final tmpDir = '${scripts.ubuntuPath}/root/MaiBot_tmp';

    for (final mirror in mirrors) {
      final repo = customRepoUrl.isNotEmpty
          ? customRepoUrl
          : '${mirror}https://github.com/Mai-with-u/MaiBot.git';
      final label = mirror.isEmpty ? '官方源' : mirror;
      onLog?.call('\x1b[36m[下载]\x1b[0m MaiBot 源码 ($label)...\r\n');
      await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', tmpDir]);

      final success = await _runInProot(
        'git -c gc.auto=0 clone --depth=1 --branch main $repo /root/MaiBot_tmp && '
        'cd /root/MaiBot_tmp && '
        'git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"',
        onLog: onLog,
        timeout: const Duration(minutes: 5),
      );
      if (success) {
        await Directory(tmpDir).rename('${scripts.ubuntuPath}/root/MaiBot');
        return true;
      }
    }
    return false;
  }

  static Future<bool> _runInProot(
    String command, {
    Function(String)? onLog,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final result = await ProotRunner.runCommand(
      command,
      onLog: onLog,
      timeout: timeout,
    );
    return result.success;
  }

  static Future<void> _restoreAndCleanNapcatTempBackup(
    Function(String) onProgress,
    Function(String)? onLog,
  ) async {
    final tempBackupFile = File(napcatTempBackupPath);
    if (!await tempBackupFile.exists()) return;

    try {
      onProgress('恢复 NapCat 配置...');
      onLog?.call('\x1b[36m[NapCat]\x1b[0m 恢复配置文件...\r\n');

      await Directory('${scripts.ubuntuPath}/root/napcat').create(recursive: true);
      final res = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-xzf',
        napcatTempBackupPath,
        '-C',
        '${scripts.ubuntuPath}/root',
      ]);

      if (res.exitCode == 0) {
        onLog?.call('\x1b[32m[NapCat]\x1b[0m 配置恢复成功\r\n');
        Log.i('NapCat 配置恢复成功', tag: 'InstallerService');
      } else {
        onLog?.call('\x1b[31m[错误]\x1b[0m NapCat 配置恢复失败: ${res.stderr}\r\n');
        Log.e('NapCat 配置恢复失败: ${res.stderr}', tag: 'InstallerService');
      }
    } catch (e) {
      Log.e('恢复 NapCat 备份异常: $e', tag: 'InstallerService');
    } finally {
      try {
        if (await tempBackupFile.exists()) {
          await tempBackupFile.delete();
          onLog?.call('\x1b[32m[NapCat]\x1b[0m 清理临时备份\r\n');
        }
      } catch (e) {
        Log.e('清理 NapCat 临时备份失败: $e', tag: 'InstallerService');
      }
    }
  }

  static Future<bool> prepareNapcatReinstall() async {
    try {
      final configDir = Directory('${scripts.ubuntuPath}/root/napcat/config');
      final tempBackupFile = File(napcatTempBackupPath);

      if (await configDir.exists()) {
        if (await tempBackupFile.exists()) {
          try {
            await tempBackupFile.delete();
          } catch (_) {}
        }
        final tarRes = await Process.run('${RuntimeEnvir.binPath}/busybox', [
          'tar',
          '-czf',
          napcatTempBackupPath,
          '-C',
          '${scripts.ubuntuPath}/root',
          'napcat/config',
        ]);
        if (tarRes.exitCode == 0) {
          Log.i('NapCat 配置已暂存', tag: 'InstallerService');
        } else {
          Log.w('NapCat 配置暂存失败: ${tarRes.stderr}', tag: 'InstallerService');
        }
      }

      Log.i('卸载 LinuxQQ...', tag: 'InstallerService');
      await _runInProot(
        'dpkg -P --force-depends linuxqq 2>/dev/null || dpkg -r --force-depends linuxqq 2>/dev/null || true',
        timeout: const Duration(seconds: 30),
      );

      final qqDir = Directory('${scripts.ubuntuPath}/opt/QQ');
      if (await qqDir.exists()) {
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', qqDir.path]);
      }

      Log.i('清理 NapCat 目录与脚本...', tag: 'InstallerService');
      final napcatDir = Directory('${scripts.ubuntuPath}/root/napcat');
      if (await napcatDir.exists()) {
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', napcatDir.path]);
      }

      final launcherFile = File('${scripts.ubuntuPath}/root/launcher.sh');
      if (await launcherFile.exists()) {
        await launcherFile.delete();
      }

      final installerScript = File('${scripts.ubuntuPath}/root/napcat.sh');
      if (await installerScript.exists()) {
        await installerScript.delete();
      }

      Log.i('NapCat 与 LinuxQQ 卸载完成', tag: 'InstallerService');
      return true;
    } catch (e) {
      Log.e('准备重新安装 NapCat 异常: $e', tag: 'InstallerService');
      return false;
    }
  }
}
