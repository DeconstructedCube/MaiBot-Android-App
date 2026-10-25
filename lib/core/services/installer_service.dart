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

  static Future<bool> runInstallPipeline({
    required Function(String) onProgress,
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

    if (!isExtracted) {
      if (await ubuntuDir.exists()) {
        try {
          await ubuntuDir.delete(recursive: true);
        } catch (_) {}
      }
      reportStage(InstallStage.extractingRootfs, '正在解压 Ubuntu 根文件系统...');
      try {
        final archivePath = '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}';
        final targetPath = '${scripts.prootDistroPath}/installed-rootfs';

        await Directory(targetPath).create(recursive: true);

        final args = ['tar', '-xJvf', archivePath, '-C', targetPath];
        if (onLog != null) {
          final process = await Process.start('${RuntimeEnvir.binPath}/busybox', args);
          int extractedFiles = 0;
          process.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen((line) {
            extractedFiles++;
            if (extractedFiles % 300 == 0) {
              // 采用渐近式平滑估算展示进度，不再受限于硬编码文件数
              final double ratio = extractedFiles / (extractedFiles + 3200.0);
              final pct = (ratio * 99.5).clamp(1.0, 99.5).toStringAsFixed(1);
              onLog('\x1b[32m[解压进度]\x1b[0m $pct% (已释放 $extractedFiles 个文件)\r\n');
            }
          });
          process.stderr
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen((line) {
            if (!line.contains('chown') &&
                !line.contains('mknod') &&
                !line.contains('Operation not permitted')) {
              onLog('\x1b[31m[tar]\x1b[0m $line\r\n');
            }
          });
          await process.exitCode;
          onLog('\x1b[32m[解压进度]\x1b[0m 100.0% (共释放 $extractedFiles 个文件)\r\n');
        } else {
          await Process.run('${RuntimeEnvir.binPath}/busybox', args);
        }

        final extractedDir = Directory('$targetPath/${scripts.ubuntuName}');
        if (await extractedDir.exists()) {
          await extractedDir.rename(scripts.ubuntuPath);
        }

        await rootfsMarker.writeAsString('ready');
        try {
          final archiveFile = File(archivePath);
          if (await archiveFile.exists()) {
            await archiveFile.delete();
            onLog?.call('\x1b[32m[系统]\x1b[0m 已清理安装包归档，释放存储空间\r\n');
          }
        } catch (_) {}

        // 2. DNS 与系统环境注入
        reportStage(InstallStage.configuringNetwork, '配置网络代理与系统参数...');
        await _writeNetworkConfigs(onLog);
      } catch (e) {
        Log.e('解压过程发生异常: $e', tag: 'InstallerService');
        return false;
      }
    }

    // 2. 独立自愈校验系统依赖（git, curl, wget, sudo, aria2）
    final depSuccess = await _ensureSystemDependencies(
      (msg) => reportStage(InstallStage.checkingSystemDeps, msg),
      onLog,
    );
    if (!depSuccess) {
      Log.e('系统基础依赖修复/安装失败', tag: 'InstallerService');
      return false;
    }

    try {
      // 3. 校验并安装 uv
      final uvExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uv');
      final uvxExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uvx');
      if (!await uvExecutable.exists() ||
          await uvExecutable.length() < 10000 ||
          !await uvxExecutable.exists()) {
        reportStage(InstallStage.installingUv, '正在下载并安装 Python 依赖管理器 (uv)...');
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
        reportStage(InstallStage.cloningMaibot, '正在获取 MaiBot 源码...');
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
        reportStage(InstallStage.cloningAdapter, '安装默认适配器插件...');
        for (final mirror in MirrorRegistry.githubPrefixMirrors) {
          final adapterUrl =
              '${mirror}https://github.com/Mai-with-u/MaiBot-Napcat-Adapter.git';
          final res = await _runInProot(
            'git -c gc.auto=0 clone --depth=1 --branch main $adapterUrl /root/MaiBot/plugins/MaiBot-Napcat-Adapter',
            onLog: onLog,
          );
          if (res) break;
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
          '正在同步 Python 依赖库 (国内镜像加速)...',
        );
        final uvSyncCmd = 'cd /root/MaiBot && '
            'if command -v script >/dev/null 2>&1; then '
            '  script -q -e -c "stty cols 45 rows 24 2>/dev/null; /root/.local/bin/uv sync --color always --index-url ${MirrorRegistry.pypiPrimaryMirror}" /dev/null; '
            'else '
            '  /root/.local/bin/uv sync --color always --index-url ${MirrorRegistry.pypiPrimaryMirror}; '
            'fi';
        final success = await _runInProot(uvSyncCmd, onLog: onLog);
        if (!success) return false;
        await venvMarker.writeAsString('ready');
      }

      // 6. 安装 NapCat
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
            onLog?.call('\x1b[33m[NapCat]\x1b[0m 检测到未暂存的 NapCat 配置，正在暂存数据...\r\n');
            await Process.run('${RuntimeEnvir.binPath}/busybox', [
              'tar',
              '-czf',
              napcatTempBackupPath,
              '-C',
              '${scripts.ubuntuPath}/root',
              'napcat/config',
            ]);
          }
          onLog?.call('\x1b[33m[NapCat]\x1b[0m 清理旧版 NapCat 目录以供全新安装...\r\n');
          await Process.run(
              '${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', napcatDir.path]);
        }

        reportStage(InstallStage.installingNapcat, '正在清理依赖并下载 NapCatQQ 组件...');
        await _runInProot(
          'echo "[APT] 检查并修复破损的系统包..." && dpkg --configure -a || true && apt-get --fix-broken install -y',
          onLog: onLog,
        );
        reportStage(InstallStage.installingNapcat, '正在部署并执行 NapCatQQ 安装脚本...');
        final targetNapcatSh = '${scripts.ubuntuPath}/root/napcat.sh';
        await _deployAssetScript('assets/scripts/napcat_install.sh', targetNapcatSh);

        if (!await File(targetNapcatSh).exists() ||
            await File(targetNapcatSh).length() < 100) {
          bool downloaded = false;
          for (final mirror in MirrorRegistry.githubPrefixMirrors) {
            final url =
                '${mirror}https://raw.githubusercontent.com/DeconstructedCube/napcat-linux-installer/refs/heads/main/install.sh';
            final res = await _runInProot(
              'echo "[网络] 尝试获取安装脚本: $url" && curl -sL -f --connect-timeout 10 --max-time 30 -o /root/napcat.sh $url',
              onLog: onLog,
            );
            if (res) {
              downloaded = true;
              break;
            }
          }
          if (!downloaded) return false;
        }

        final success = await _runInProot('bash /root/napcat.sh', onLog: onLog);
        if (!success) return false;

        await _restoreAndCleanNapcatTempBackup(
          (msg) => reportStage(InstallStage.restoringBackup, msg),
          onLog,
        );
      }

      reportStage(InstallStage.completed, '初始化完成，正在准备启动...');
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

      onLog?.call('\x1b[32m[DNS]\x1b[0m 正在写入 resolv.conf...\r\n');
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

      // 部署外置化的 apt-fast、curl/wget 透明加速包装器与 Git 运维脚本
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
        'index-url = ${MirrorRegistry.pypiPrimaryMirror}\n'
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
        'url = "${MirrorRegistry.pypiPrimaryMirror}"\n'
        'default = true\n',
      );

      // 保持 fake proc 节点初始化
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

      await _writeSourcesList(MirrorRegistry.aptPortMirrors.first, onLog);
    } catch (e) {
      Log.e('Failed to write network configs: $e', tag: 'InstallerService');
    }
  }

  static Future<void> _writeSourcesList(String mirrorUrl, Function(String)? onLog) async {
    try {
      onLog?.call('\x1b[32m[APT]\x1b[0m 配置镜像源 -> $mirrorUrl\r\n');
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
      await _writeNetworkConfigs(onLog);
      return true;
    }

    onProgress('正在检查并安装系统运行依赖 (git/curl/aria2)...');
    await _writeNetworkConfigs(onLog);

    for (final mirror in MirrorRegistry.aptPortMirrors) {
      await _writeSourcesList(mirror, onLog);

      const repairCmd =
          'mkdir -p /tmp /var/tmp /etc/ssl/certs && chmod 1777 /tmp /var/tmp; '
          'export TMPDIR=/tmp; export TEMP=/tmp; export TMP=/tmp; export DEBIAN_FRONTEND=noninteractive; '
          'dpkg --configure -a || true; '
          'apt-get --fix-broken install -y || true; '
          'apt-get update && apt-get install -y --no-install-recommends sudo wget git curl ca-certificates aria2';

      final success = await _runInProot(
        repairCmd,
        onLog: onLog,
        timeout: const Duration(minutes: 5),
      );
      if (success && await gitBinary.exists() && await curlBinary.exists()) {
        await _writeNetworkConfigs(onLog);
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
    for (final mirror in MirrorRegistry.githubPrefixMirrors) {
      final target = '$mirror$releaseUrl';
      onLog?.call('\x1b[32m[UV]\x1b[0m 尝试从 ${mirror.isEmpty ? "官方直连" : mirror} 下载...\r\n');

      if (onLog != null) {
        final process = await Process.start(
            '${RuntimeEnvir.binPath}/busybox', ['wget', '-O', tmpArchive, target]);
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
            '${RuntimeEnvir.binPath}/busybox', ['wget', '-O', tmpArchive, target]);
        if (res.exitCode == 0) {
          downloaded = true;
          break;
        }
      }
    }

    if (!downloaded) {
      onLog?.call('\x1b[31m[UV]\x1b[0m 所有镜像源下载均失败！\r\n');
      return false;
    }

    onLog?.call('\x1b[32m[UV]\x1b[0m 下载完成，正在解压...\r\n');
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
      return true;
    }
    return false;
  }

  static Future<bool> _cloneMaibot(Function(String)? onLog) async {
    final Setting customGitCloneSetting = 'custom_git_clone_url'.setting;
    final String customRepoUrl = customGitCloneSetting.get() ?? '';

    final mirrors = customRepoUrl.isNotEmpty
        ? ['']
        : [
            'https://ghfast.top/',
            'https://ghproxy.vip/',
            'https://gh-proxy.com/',
            '',
          ];
    final tmpDir = '${scripts.ubuntuPath}/root/MaiBot_tmp';

    for (final mirror in mirrors) {
      final repo = customRepoUrl.isNotEmpty
          ? customRepoUrl
          : '${mirror}https://github.com/Mai-with-u/MaiBot.git';
      await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', tmpDir]);

      final success = await _runInProot(
        'git -c gc.auto=0 clone --depth=1 --branch main $repo /root/MaiBot_tmp && '
        'cd /root/MaiBot_tmp && '
        'git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"',
        onLog: onLog,
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
      onProgress('正在恢复 NapCat 数据与配置...');
      onLog?.call('\x1b[32m[NapCat]\x1b[0m 发现一次性暂存备份，正在恢复配置...\r\n');

      await Directory('${scripts.ubuntuPath}/root/napcat').create(recursive: true);
      final res = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-xzf',
        napcatTempBackupPath,
        '-C',
        '${scripts.ubuntuPath}/root',
      ]);

      if (res.exitCode == 0) {
        onLog?.call('\x1b[32m[NapCat]\x1b[0m NapCat 配置数据恢复成功！\r\n');
        Log.i('NapCat 临时数据已成功恢复', tag: 'InstallerService');
      } else {
        onLog?.call('\x1b[31m[NapCat]\x1b[0m 恢复 NapCat 配置数据失败: ${res.stderr}\r\n');
        Log.e('恢复 NapCat 配置数据失败: ${res.stderr}', tag: 'InstallerService');
      }
    } catch (e) {
      Log.e('恢复 NapCat 临时备份异常: $e', tag: 'InstallerService');
    } finally {
      try {
        if (await tempBackupFile.exists()) {
          await tempBackupFile.delete();
          onLog?.call('\x1b[32m[NapCat]\x1b[0m 一次性暂存备份已清理。\r\n');
          Log.i('已清理 NapCat 一次性临时备份: $napcatTempBackupPath', tag: 'InstallerService');
        }
      } catch (e) {
        Log.e('清理 NapCat 一次性临时备份失败: $e', tag: 'InstallerService');
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
          Log.i('NapCat 配置已暂存至: $napcatTempBackupPath', tag: 'InstallerService');
        } else {
          Log.w('NapCat 配置暂存失败: ${tarRes.stderr}', tag: 'InstallerService');
        }
      }

      Log.i('正在卸载 LinuxQQ（保留系统依赖）...', tag: 'InstallerService');
      await _runInProot(
        'dpkg -P --force-depends linuxqq 2>/dev/null || dpkg -r --force-depends linuxqq 2>/dev/null || true',
        timeout: const Duration(seconds: 30),
      );

      final qqDir = Directory('${scripts.ubuntuPath}/opt/QQ');
      if (await qqDir.exists()) {
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', qqDir.path]);
      }

      Log.i('正在清理 NapCat 目录与启动脚本...', tag: 'InstallerService');
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

      Log.i('NapCat 与 LinuxQQ 卸载完成，配置已暂存', tag: 'InstallerService');
      return true;
    } catch (e) {
      Log.e('准备重新安装 NapCat 异常: $e', tag: 'InstallerService');
      return false;
    }
  }
}
