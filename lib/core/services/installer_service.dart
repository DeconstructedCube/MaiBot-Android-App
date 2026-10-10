import 'dart:io';
import 'dart:convert';

import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';

import '../config/app_config.dart';
import '../constants/scripts.dart' as scripts;
import 'proot_runner.dart';
class InstallerService {
  /// 记录当前流水线是否为首次/全新安装
  static bool lastInstallWasFresh = false;
  /// NapCat 重装时的一次性临时备份文件路径
  static String get napcatTempBackupPath => '${RuntimeEnvir.homePath}/.napcat_reinstall_backup.tar.gz';

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
    Function(String)? onLog,
  }) async {
    final ubuntuDir = Directory(scripts.ubuntuPath);
    
    // 1. 原生解压 (Native Extraction)
    final rootfsMarker = File('${scripts.ubuntuPath}/.rootfs_ready');
    final bool isExtracted = isRootfsReady();
    
    lastInstallWasFresh = !isExtracted;
    
    if (!isExtracted) {
      if (ubuntuDir.existsSync()) {
        try {
          ubuntuDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      onProgress('正在解压 Ubuntu 根文件系统...');
      try {
        final archivePath = '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}';
        final targetPath = '${scripts.prootDistroPath}/installed-rootfs';
        
        Directory(targetPath).createSync(recursive: true);
        
        final args = ['tar', '-xJvf', archivePath, '-C', targetPath];
        if (onLog != null) {
          final process = await Process.start('${RuntimeEnvir.binPath}/busybox', args);
          int extractedFiles = 0;
          final totalFiles = 12684; // 预估包内文件总数
          process.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
            extractedFiles++;
            if (extractedFiles % 300 == 0 || extractedFiles == totalFiles) {
              final pct = (extractedFiles / totalFiles * 100).clamp(0, 100).toStringAsFixed(1);
              onLog('\x1b[32m[解压进度]\x1b[0m $pct% ($extractedFiles/$totalFiles)\r\n');
            }
          });
          process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
            if (!line.contains('chown') && !line.contains('mknod') && !line.contains('Operation not permitted')) {
              onLog('\x1b[31m[tar]\x1b[0m $line\r\n');
            }
          });
          await process.exitCode;
        } else {
          await Process.run('${RuntimeEnvir.binPath}/busybox', args);
        }

        // 移动内容
        final extractedDir = Directory('$targetPath/${scripts.ubuntuName}');
        if (extractedDir.existsSync()) {
          extractedDir.renameSync(scripts.ubuntuPath);
        }

        // 标记 Rootfs 解压完成
        rootfsMarker.writeAsStringSync('ready');
        // 解压完成后删除 61.2MB 临时归档压缩包以节省手机存储
        try {
          final archiveFile = File(archivePath);
          if (archiveFile.existsSync()) {
            archiveFile.deleteSync();
            onLog?.call('\x1b[32m[系统]\x1b[0m 已清理安装包归档，释放存储空间\r\n');
          }
        } catch (_) {}

        // 2. DNS 与系统环境注入
        onProgress('配置网络代理与系统参数...');
        _writeNetworkConfigs(onLog);
      } catch (e) {
        Log.e('解压过程发生异常: $e', tag: 'InstallerService');
        return false;
      }
    }

    // 2. 独立自愈校验系统依赖（git, curl, wget, sudo 等）
    final depSuccess = await _ensureSystemDependencies(onProgress, onLog);
    if (!depSuccess) {
      Log.e('系统基础依赖修复/安装失败', tag: 'InstallerService');
      return false;
    }
    try {
      // 3. 校验并安装 uv
    final uvExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uv');
    final uvxExecutable = File('${scripts.ubuntuPath}/root/.local/bin/uvx');
    if (!uvExecutable.existsSync() || uvExecutable.lengthSync() < 10000 || !uvxExecutable.existsSync()) {
      onProgress('正在下载并安装 Python 依赖管理器 (uv)...');
      final success = await _downloadAndInstallUv(onLog);
      if (!success) return false;
    }

    // 4. 克隆 MaiBot
    final maibotDir = Directory('${scripts.ubuntuPath}/root/MaiBot');
    final botPy = File('${maibotDir.path}/bot.py');
    final pyproject = File('${maibotDir.path}/pyproject.toml');
    if (!maibotDir.existsSync() || !botPy.existsSync() || !pyproject.existsSync()) {
      if (maibotDir.existsSync()) {
        await _runInProot('rm -rf /root/MaiBot');
      }
      onProgress('正在获取 MaiBot 源码...');
      final success = await _cloneMaibot(onLog);
      if (!success) return false;
    }

    // 4.5 默认适配器克隆
    final pluginsDir = Directory('${scripts.ubuntuPath}/root/MaiBot/plugins');
    final adapterDir = Directory('${pluginsDir.path}/MaiBot-Napcat-Adapter');
    final adapterMain = File('${adapterDir.path}/adapter.py');
    final adapterInit = File('${adapterDir.path}/__init__.py');
    
    if (!adapterDir.existsSync() || (!adapterMain.existsSync() && !adapterInit.existsSync())) {
      if (adapterDir.existsSync()) {
        await _runInProot('rm -rf /root/MaiBot/plugins/MaiBot-Napcat-Adapter');
      }
      onProgress('安装默认适配器插件...');
      for (final mirror in ['https://ghfast.top/', 'https://gh-proxy.com/', 'https://mirror.ghproxy.com/', '']) {
        final adapterUrl = '${mirror}https://github.com/MaiM-with-u/MaiBot-Napcat-Adapter.git';
        final res = await _runInProot('git -c gc.auto=0 clone --depth=1 --branch main $adapterUrl /root/MaiBot/plugins/MaiBot-Napcat-Adapter', onLog: onLog);
        if (res) break;
      }
      final adapterConfig = File('${adapterDir.path}/config.toml');
      if (adapterConfig.existsSync()) adapterConfig.deleteSync();
    }
    // 5. 同步 Python 依赖库 (仅在缺失虚拟环境或就绪标记时执行，日常启动 0 耗时秒级跳过)
    final venvDir = Directory('${scripts.ubuntuPath}/root/MaiBot/.venv');
    final venvMarker = File('${scripts.ubuntuPath}/root/MaiBot/.venv_sync_ready');
    final bool hasVenv = venvDir.existsSync() && venvMarker.existsSync();
    if (!hasVenv) {
      if (venvDir.existsSync()) {
        await _runInProot('rm -rf /root/MaiBot/.venv');
      }
      onProgress('正在同步 Python 依赖库 (国内镜像加速)...');
      final uvSyncCmd =
          'cd /root/MaiBot && '
          'if command -v script >/dev/null 2>&1; then '
          '  script -q -e -c "stty cols 45 rows 24 2>/dev/null; /root/.local/bin/uv sync --color always --index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple" /dev/null; '
          'else '
          '  /root/.local/bin/uv sync --color always --index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple; '
          'fi';
      final success = await _runInProot(uvSyncCmd, onLog: onLog);
      if (!success) return false;
      venvMarker.writeAsStringSync('ready');
    }
    // 6. 安装 NapCat
    final napcatDir = Directory('${scripts.ubuntuPath}/root/napcat');
    final qqBinary = File('${scripts.ubuntuPath}/opt/QQ/qq');
    final launcherSh = File('${scripts.ubuntuPath}/root/launcher.sh');
    final napcatEntry = File('${napcatDir.path}/napcat.mjs');
    if (!napcatDir.existsSync() || !qqBinary.existsSync() || !launcherSh.existsSync() || !napcatEntry.existsSync()) {
      // 若 napcat 目录依然存在（安装器会因文件夹已存在而拒绝安装），且存在未暂存的配置，自动备份配置后清理目录
      final tempBackup = File(napcatTempBackupPath);
      final configDir = Directory('${scripts.ubuntuPath}/root/napcat/config');
      if (napcatDir.existsSync()) {
        if (!tempBackup.existsSync() && configDir.existsSync()) {
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
        // 清理 /root/napcat 目录避免安装器冲突拒绝安装
        onLog?.call('\x1b[33m[NapCat]\x1b[0m 清理旧版 NapCat 目录以供全新安装...\r\n');
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', napcatDir.path]);
      }

      onProgress('正在清理依赖并下载 NapCatQQ 组件...');
      await _runInProot('echo "[APT] 检查并修复破损的系统包..." && dpkg --configure -a || true && apt-get --fix-broken install -y', onLog: onLog);
      onProgress('正在下载 NapCatQQ 组件...');
      bool downloaded = false;
      for (final mirror in ['https://ghfast.top/', 'https://gh-proxy.com/', 'https://mirror.ghproxy.com/', '']) {
        final url = '${mirror}https://raw.githubusercontent.com/bsfdsagfadg/napcat-linux-installer/refs/heads/main/install.sh';
        final res = await _runInProot('echo "[网络] 尝试获取安装脚本: $url" && curl -sL -f --connect-timeout 10 --max-time 30 -o /root/napcat.sh $url', onLog: onLog);
        if (res) { downloaded = true; break; }
      }
      if (!downloaded) return false;
      
      final success = await _runInProot(
        r"sed -i 's@apt-get install.*QQ\.deb.*@& || exit 1@g' /root/napcat.sh "
        r"&& sed -i 's@curl -k -L -#@curl -k -L @g' /root/napcat.sh "
        r"&& sed -i 's@curl -k -L @curl -k -L --connect-timeout 10 --max-time 300 @g' /root/napcat.sh "
        r"&& bash /root/napcat.sh", 
        onLog: onLog
      );
      if (!success) return false;

      // 安装完成后，恢复一次性暂存备份并清理
      await _restoreAndCleanNapcatTempBackup(onProgress, onLog);
    }
    onProgress('初始化完成，正在准备启动...');
    return true;
  } catch (e) {
    Log.e('后续配置执行异常: $e', tag: 'InstallerService');
    return false;
  }
  }

  static void _writeNetworkConfigs(Function(String)? onLog) {
    try {
      // 确保系统目录与临时目录存在且权限正确，彻底杜绝 ca-certificates 或 dpkg 找不到路径
      Directory('${scripts.ubuntuPath}/tmp').createSync(recursive: true);
      Directory('${scripts.ubuntuPath}/var/tmp').createSync(recursive: true);
      Directory('${scripts.ubuntuPath}/etc/ssl/certs').createSync(recursive: true);
      Directory('${scripts.ubuntuPath}/var/cache/apt/archives/partial').createSync(recursive: true);
      Directory('${scripts.ubuntuPath}/var/lib/apt/lists/partial').createSync(recursive: true);
      Directory(RuntimeEnvir.tmpPath).createSync(recursive: true);

      onLog?.call('\x1b[32m[DNS]\x1b[0m 正在写入 resolv.conf...\r\n');
      final resolvConf = File('${scripts.ubuntuPath}/etc/resolv.conf');
      resolvConf.writeAsStringSync('nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 114.114.114.114\nnameserver 8.8.8.8\n');

      final aptConfDir = Directory('${scripts.ubuntuPath}/etc/apt/apt.conf.d');
      if (!aptConfDir.existsSync()) aptConfDir.createSync(recursive: true);
      
      // APT 极限加速：全局阻断冗余推荐包风暴、禁用多语言翻译索引下载（节约70%更新体积）、关闭管道深度避免网络卡死、禁用文件系统缓存开销
      final speedupConf = File('${aptConfDir.path}/99speedup');
      speedupConf.writeAsStringSync(
        'APT::Install-Recommends "false";\n'
        'APT::Install-Suggests "false";\n'
        'Acquire::Languages "none";\n'
        'Acquire::Check-Valid-Until "false";\n'
        'Acquire::http::Timeout "10";\n'
        'Acquire::https::Timeout "10";\n'
        'Acquire::Retries "3";\n'
        'Acquire::http::Pipeline-Depth "0";\n'
        'Dir::Cache::pkgcache "";\n'
        'Dir::Cache::srcpkgcache "";\n'
      );

      // DPKG 加速：在 PRoot 虚拟文件系统中跳过耗时的逐文件物理 fsync，并跳过数万个无用文档小文件写入
      final dpkgConfDir = Directory('${scripts.ubuntuPath}/etc/dpkg/dpkg.cfg.d');
      if (!dpkgConfDir.existsSync()) dpkgConfDir.createSync(recursive: true);
      final dpkgSpeedup = File('${dpkgConfDir.path}/02apt-speedup');
      dpkgSpeedup.writeAsStringSync('force-unsafe-io\n');
      
      final dpkgNoDoc = File('${dpkgConfDir.path}/01nodoc');
      dpkgNoDoc.writeAsStringSync(
        'path-exclude /usr/share/doc/*\n'
        'path-exclude /usr/share/man/*\n'
        'path-exclude /usr/share/groff/*\n'
        'path-exclude /usr/share/info/*\n'
        'path-exclude /usr/share/lintian/*\n'
        'path-exclude /usr/share/linda/*\n'
        'path-exclude /usr/share/locale/*\n'
      );

      // 部署 apt-fast (基于 aria2c 的多连接并发下载加速器)
      final localBinDir = Directory('${scripts.ubuntuPath}/usr/local/bin');
      if (!localBinDir.existsSync()) localBinDir.createSync(recursive: true);
      final aptFastScript = File('${localBinDir.path}/apt-fast');
      aptFastScript.writeAsStringSync(
        '#!/bin/bash\n'
        '# apt-fast: high-speed multi-connection wrapper for apt-get using aria2c\n'
        'set -e\n'
        'APT_REAL="/usr/bin/apt-get"\n'
        '[ ! -x "\$APT_REAL" ] && APT_REAL="apt-get"\n\n'
        'if ! command -v aria2c >/dev/null 2>&1 || [ \$# -eq 0 ]; then\n'
        '    exec "\$APT_REAL" "\$@"\n'
        'fi\n\n'
        'case "\$1" in\n'
        '    install|reinstall|dist-upgrade|upgrade|build-dep|source)\n'
        '        TMP_URI_FILE="/tmp/apt-fast-\$\$.uris"\n'
        '        TMP_LIST_FILE="/tmp/apt-fast-\$\$.list"\n'
        '        mkdir -p /var/cache/apt/archives/partial\n'
        '        if "\$APT_REAL" --print-uris -y "\$@" > "\$TMP_URI_FILE" 2>/dev/null; then\n'
        '            awk \'{\n'
        '                gsub(/\\047/, "", \$1);\n'
        '                gsub(/\\047/, "", \$2);\n'
        '                if (\$1 ~ /^https?:\\/\\// || \$1 ~ /^ftp:\\/\\//) {\n'
        '                    print \$1;\n'
        '                    print "  dir=/var/cache/apt/archives";\n'
        '                    print "  out=" \$2;\n'
        '                }\n'
        '            }\' "\$TMP_URI_FILE" > "\$TMP_LIST_FILE"\n'
        '            if [ -s "\$TMP_LIST_FILE" ]; then\n'
            '                echo -e "\\e[32m[apt-fast]\\e[0m 使用 aria2c 多连接并发下载软件包..."\n'
            '                aria2c \\\n'
            '                    --no-conf \\\n'
            '                    --async-dns=false \\\n'
            '                    --disable-ipv6=true \\\n'
            '                    -i "\$TMP_LIST_FILE" \\\n'
            '                    -j 8 \\\n'
            '                    -x 8 \\\n'
            '                    -s 8 \\\n'
            '                    -k 1M \\\n'
            '                    --allow-overwrite=true \\\n'
            '                    --auto-file-renaming=false \\\n'
            '                    --file-allocation=none \\\n'
            '                    --console-log-level=warn \\\n'
            '                    --summary-interval=0 \\\n'
            '                    --connect-timeout=10 \\\n'
            '                    --timeout=30 \\\n'
            '                    --max-tries=5 \\\n'
            '                    --retry-wait=2 \\\n'
            '                    --dir=/var/cache/apt/archives || true\n'
            '            fi\n'
        '            rm -f "\$TMP_URI_FILE" "\$TMP_LIST_FILE"\n'
        '        fi\n'
        '        exec "\$APT_REAL" "\$@"\n'
        '        ;;\n'
        '    *)\n'
        '        exec "\$APT_REAL" "\$@"\n'
        '        ;;\n'
        'esac\n'
      );
      Process.runSync('${RuntimeEnvir.binPath}/busybox', ['chmod', '+x', aptFastScript.path]);
      // 创建 apt-get 与 apt 的覆盖软连接至 /usr/local/bin
      final aptGetLink = Link('${localBinDir.path}/apt-get');
      if (!aptGetLink.existsSync()) {
        try { aptGetLink.createSync('apt-fast'); } catch (_) {}
      }
      final aptLink = Link('${localBinDir.path}/apt');
      if (!aptLink.existsSync()) {
        try { aptLink.createSync('apt-fast'); } catch (_) {}
      }

      // 部署透明高速 curl 包装器（自动为 GitHub Releases/Raw/Zip 加上高速镜像）
      final curlWrapper = File('${localBinDir.path}/curl');
      curlWrapper.writeAsStringSync(
        '#!/bin/bash\n'
        'REAL_CURL="/usr/bin/curl"\n'
        '[ ! -x "\$REAL_CURL" ] && REAL_CURL="curl"\n\n'
        'ARGS=()\n'
        'for arg in "\$@"; do\n'
        '    if [[ "\$arg" =~ ^https://(github\\.com|raw\\.githubusercontent\\.com|objects\\.githubusercontent\\.com)/.* ]] && [[ ! "\$arg" =~ ghfast\\.top ]] && [[ ! "\$arg" =~ gh-proxy\\.com ]] && [[ ! "\$arg" =~ ghproxy ]]; then\n'
        '        ARGS+=("https://ghfast.top/\$arg")\n'
        '    else\n'
        '        ARGS+=("\$arg")\n'
        '    fi\n'
        'done\n\n'
        'exec "\$REAL_CURL" "\${ARGS[@]}"\n'
      );
      Process.runSync('${RuntimeEnvir.binPath}/busybox', ['chmod', '+x', curlWrapper.path]);

      // 部署透明高速 wget 包装器
      final wgetWrapper = File('${localBinDir.path}/wget');
      wgetWrapper.writeAsStringSync(
        '#!/bin/bash\n'
        'REAL_WGET="/usr/bin/wget"\n'
        '[ ! -x "\$REAL_WGET" ] && REAL_WGET="wget"\n\n'
        'ARGS=()\n'
        'for arg in "\$@"; do\n'
        '    if [[ "\$arg" =~ ^https://(github\\.com|raw\\.githubusercontent\\.com|objects\\.githubusercontent\\.com)/.* ]] && [[ ! "\$arg" =~ ghfast\\.top ]] && [[ ! "\$arg" =~ gh-proxy\\.com ]] && [[ ! "\$arg" =~ ghproxy ]]; then\n'
        '        ARGS+=("https://ghfast.top/\$arg")\n'
        '    else\n'
        '        ARGS+=("\$arg")\n'
        '    fi\n'
        'done\n\n'
        'exec "\$REAL_WGET" "\${ARGS[@]}"\n'
      );
      Process.runSync('${RuntimeEnvir.binPath}/busybox', ['chmod', '+x', wgetWrapper.path]);

      // 全局 Git 防卡死与基础配置 (/etc/gitconfig)
      final gitConfig = File('${scripts.ubuntuPath}/etc/gitconfig');
      gitConfig.writeAsStringSync(
        '[http]\n'
        '    lowSpeedLimit = 1000\n'
        '    lowSpeedTime = 20\n'
        '    postBuffer = 524288000\n'
        '[credential]\n'
        '    helper = store\n'
      );

      // 全局 Python Pip 国内镜像源配置 (/etc/pip.conf)
      final pipConfig = File('${scripts.ubuntuPath}/etc/pip.conf');
      pipConfig.writeAsStringSync(
        '[global]\n'
        'index-url = https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple\n'
        'extra-index-url = https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple/\n'
        'timeout = 30\n'
      );

      // 全局 NPM / Node.js 镜像源配置 (/root/.npmrc)
      final npmrc = File('${scripts.ubuntuPath}/root/.npmrc');
      npmrc.writeAsStringSync(
        'registry=https://registry.npmmirror.com\n'
        'disturl=https://npmmirror.com/mirrors/node\n'
        'canvas_binary_host_mirror=https://npmmirror.com/mirrors/canvas\n'
      );

      // UV 国内镜像与加速配置
      final uvConfigDir = Directory('${scripts.ubuntuPath}/root/.config/uv');
      if (!uvConfigDir.existsSync()) uvConfigDir.createSync(recursive: true);
      final uvToml = File('${uvConfigDir.path}/uv.toml');
      uvToml.writeAsStringSync(
        '[[index]]\n'
        'url = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"\n'
        'default = true\n'
      );
      final procDir = Directory('${scripts.ubuntuPath}/proc');
      if (!procDir.existsSync()) procDir.createSync(recursive: true);
      final loadavg = File('${procDir.path}/.loadavg');
      if (!loadavg.existsSync()) loadavg.writeAsStringSync('0.12 0.07 0.02 2/165 765\n');
      final stat = File('${procDir.path}/.stat');
      if (!stat.existsSync()) stat.writeAsStringSync('cpu  1957 0 2877 93280 262 342 254 87 0 0\n');
      final uptime = File('${procDir.path}/.uptime');
      if (!uptime.existsSync()) uptime.writeAsStringSync('12345.67 890.12\n');
      final vmstat = File('${procDir.path}/.vmstat');
      if (!vmstat.existsSync()) vmstat.writeAsStringSync('nr_free_pages 100000\n');

      _writeSourcesList('http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/', onLog);
    } catch (e) {
      Log.e('Failed to write network configs: $e', tag: 'InstallerService');
    }
  }

  static void _writeSourcesList(String mirrorUrl, Function(String)? onLog) {
    try {
      onLog?.call('\x1b[32m[APT]\x1b[0m 配置镜像源 -> $mirrorUrl\r\n');
      final sourcesList = File('${scripts.ubuntuPath}/etc/apt/sources.list');
      sourcesList.writeAsStringSync(
        'deb $mirrorUrl noble main restricted universe multiverse\n'
        'deb $mirrorUrl noble-updates main restricted universe multiverse\n'
        'deb $mirrorUrl noble-security main restricted universe multiverse\n'
      );
    } catch (e) {
      Log.e('Failed to write sources.list: $e', tag: 'InstallerService');
    }
  }

  /// 检查系统核心依赖，缺失时自动多镜像源尝试自愈修复
  static Future<bool> _ensureSystemDependencies(Function(String) onProgress, Function(String)? onLog) async {
    final gitBinary = File('${scripts.ubuntuPath}/usr/bin/git');
    final curlBinary = File('${scripts.ubuntuPath}/usr/bin/curl');
    final wgetBinary = File('${scripts.ubuntuPath}/usr/bin/wget');
    final sudoBinary = File('${scripts.ubuntuPath}/usr/bin/sudo');
    final aria2Binary = File('${scripts.ubuntuPath}/usr/bin/aria2c');

    // 核心依赖全部完好，直接跳过（零耗时，秒级通过）
    if (gitBinary.existsSync() && curlBinary.existsSync() && wgetBinary.existsSync() && sudoBinary.existsSync() && aria2Binary.existsSync()) {
      _writeNetworkConfigs(onLog);
      return true;
    }

    onProgress('正在检查并安装系统运行依赖 (git/curl/aria2)...');
    _writeNetworkConfigs(onLog);

    const aptMirrors = [
      'http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/',
      'http://mirrors.ustc.edu.cn/ubuntu-ports/',
      'http://mirrors.aliyun.com/ubuntu-ports/',
      'http://mirrors.volces.com/ubuntu-ports/',
      'http://ports.ubuntu.com/ubuntu-ports/',
    ];

    for (final mirror in aptMirrors) {
      _writeSourcesList(mirror, onLog);
      
      // 显式在容器内创建临时目录并强制重设 TMPDIR=/tmp，彻底根治 CA 证书安装去宿主 cache 目录寻找临时文件的异常
      final repairCmd = 
          'mkdir -p /tmp /var/tmp /etc/ssl/certs && chmod 1777 /tmp /var/tmp; '
          'export TMPDIR=/tmp; export TEMP=/tmp; export TMP=/tmp; export DEBIAN_FRONTEND=noninteractive; '
          'dpkg --configure -a || true; '
          'apt-get --fix-broken install -y || true; '
          'apt-get update && apt-get install -y --no-install-recommends sudo wget git curl ca-certificates aria2';
      
      final success = await _runInProot(repairCmd, onLog: onLog, timeout: const Duration(minutes: 5));
      if (success && gitBinary.existsSync() && curlBinary.existsSync()) {
        _writeNetworkConfigs(onLog);
        return true;
      }
    }

    return gitBinary.existsSync();
  }

  static Future<bool> _downloadAndInstallUv(Function(String)? onLog) async {
    const mirrors = [
      'https://ghfast.top/',
      'https://gh-proxy.com/',
      'https://mirror.ghproxy.com/',
      ''
    ];
    
    final tmpArchive = '${RuntimeEnvir.tmpPath}/uv-aarch64.tar.gz';
    const releaseUrl = 'https://github.com/astral-sh/uv/releases/download/0.9.9/uv-aarch64-unknown-linux-gnu.tar.gz';
    
    bool downloaded = false;
    for (final mirror in mirrors) {
      final target = '$mirror$releaseUrl';
      onLog?.call('\x1b[32m[UV]\x1b[0m 尝试从 $mirror 下载...\r\n');
      
      if (onLog != null) {
        final process = await Process.start('${RuntimeEnvir.binPath}/busybox', ['wget', '-O', tmpArchive, target]);
        process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((data) => onLog(data.replaceAll('\n', '\r\n')));
        process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((data) => onLog(data.replaceAll('\n', '\r\n')));
        final exitCode = await process.exitCode;
        if (exitCode == 0) {
          downloaded = true;
          break;
        }
      } else {
        final res = await Process.run('${RuntimeEnvir.binPath}/busybox', ['wget', '-O', tmpArchive, target]);
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
      'tar', '-xzf', tmpArchive, '-C', RuntimeEnvir.tmpPath
    ]);
    
    if (extractRes.exitCode == 0) {
      final localBin = Directory('${scripts.ubuntuPath}/root/.local/bin');
      if (!localBin.existsSync()) localBin.createSync(recursive: true);
      
      File('${RuntimeEnvir.tmpPath}/uv-aarch64-unknown-linux-gnu/uv').copySync('${localBin.path}/uv');
      File('${RuntimeEnvir.tmpPath}/uv-aarch64-unknown-linux-gnu/uvx').copySync('${localBin.path}/uvx');
      Process.runSync('${RuntimeEnvir.binPath}/busybox', ['chmod', '+x', '${localBin.path}/uv', '${localBin.path}/uvx']);
      return true;
    }
    return false;
  }

  static Future<bool> _cloneMaibot(Function(String)? onLog) async {
    Setting customGitCloneSetting = 'custom_git_clone_url'.setting;
    String customRepoUrl = customGitCloneSetting.get() ?? '';

    final mirrors = customRepoUrl.isNotEmpty 
      ? [''] // 如果用户自定义了完整 URL，则不再附加前缀镜像
      : [
          'https://ghfast.top/',
          'https://ghproxy.vip/',
          'https://gh-proxy.com/',
          ''
        ];
    final tmpDir = '${scripts.ubuntuPath}/root/MaiBot_tmp';
    
    for (final mirror in mirrors) {
      final repo = customRepoUrl.isNotEmpty ? customRepoUrl : '${mirror}https://github.com/Mai-with-u/MaiBot.git';
      // Cleanup before try (using busybox to bypass Dart read-only file deletion issues in .git)
      await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', tmpDir]);
      
      // Use -c gc.auto=0 to prevent git auto maintenance from hanging the proot process after clone
      final success = await _runInProot(
        'git -c gc.auto=0 clone --depth=1 --branch main $repo /root/MaiBot_tmp && '
        'cd /root/MaiBot_tmp && '
        'git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"',
        onLog: onLog,
      );
      if (success) {
        Directory(tmpDir).renameSync('${scripts.ubuntuPath}/root/MaiBot');
        return true;
      }
    }
    return false;
  }

  static Future<bool> _runInProot(String command, {Function(String)? onLog, Duration timeout = const Duration(minutes: 10)}) async {
    final result = await ProotRunner.runCommand(
      command,
      onLog: onLog,
      timeout: timeout,
    );
    return result.success;
  }

  /// 恢复一次性暂存的 NapCat 配置并在完成后清理临时备份文件
  static Future<void> _restoreAndCleanNapcatTempBackup(Function(String) onProgress, Function(String)? onLog) async {
    final tempBackupFile = File(napcatTempBackupPath);
    if (!tempBackupFile.existsSync()) return;

    try {
      onProgress('正在恢复 NapCat 数据与配置...');
      onLog?.call('\x1b[32m[NapCat]\x1b[0m 发现一次性暂存备份，正在恢复配置...\r\n');
      
      Directory('${scripts.ubuntuPath}/root/napcat').createSync(recursive: true);
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
      // 备份是一次性的，记得清理
      try {
        if (tempBackupFile.existsSync()) {
          tempBackupFile.deleteSync();
          onLog?.call('\x1b[32m[NapCat]\x1b[0m 一次性暂存备份已清理。\r\n');
          Log.i('已清理 NapCat 一次性临时备份: $napcatTempBackupPath', tag: 'InstallerService');
        }
      } catch (e) {
        Log.e('清理 NapCat 一次性临时备份失败: $e', tag: 'InstallerService');
      }
    }
  }

  /// 准备重新安装 NapCat：
  /// 1. 将现有的 NapCat 配置数据备份到一次性临时文件（避免安装器因文件夹已存在而拒绝安装）
  /// 2. 卸载 QQ（使用 dpkg 强制移除 QQ 单包，保留系统库依赖，避免重复耗时下载）
  /// 3. 清理 NapCat 安装目录与相关启动脚本
  static Future<bool> prepareNapcatReinstall() async {
    try {
      final configDir = Directory('${scripts.ubuntuPath}/root/napcat/config');
      final tempBackupFile = File(napcatTempBackupPath);

      // 1. 如果存在 NapCat 配置目录，则打包暂存
      if (configDir.existsSync()) {
        if (tempBackupFile.existsSync()) {
          try {
            tempBackupFile.deleteSync();
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

      // 2. 卸载 QQ（保留依赖）
      Log.i('正在卸载 LinuxQQ（保留系统依赖）...', tag: 'InstallerService');
      await _runInProot(
        'dpkg -P --force-depends linuxqq 2>/dev/null || dpkg -r --force-depends linuxqq 2>/dev/null || true',
        timeout: const Duration(seconds: 30),
      );

      // 清理残留的 QQ 目录
      final qqDir = Directory('${scripts.ubuntuPath}/opt/QQ');
      if (qqDir.existsSync()) {
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', qqDir.path]);
      }

      // 3. 卸载 NapCat（删除 napcat 目录、启动脚本及锁文件）
      Log.i('正在清理 NapCat 目录与启动脚本...', tag: 'InstallerService');
      final napcatDir = Directory('${scripts.ubuntuPath}/root/napcat');
      if (napcatDir.existsSync()) {
        await Process.run('${RuntimeEnvir.binPath}/busybox', ['rm', '-rf', napcatDir.path]);
      }

      final launcherFile = File('${scripts.ubuntuPath}/root/launcher.sh');
      if (launcherFile.existsSync()) {
        launcherFile.deleteSync();
      }

      final installerScript = File('${scripts.ubuntuPath}/root/napcat.sh');
      if (installerScript.existsSync()) {
        installerScript.deleteSync();
      }

      Log.i('NapCat 与 LinuxQQ 卸载完成，配置已暂存', tag: 'InstallerService');
      return true;
    } catch (e) {
      Log.e('准备重新安装 NapCat 异常: $e', tag: 'InstallerService');
      return false;
     }
  }
}
