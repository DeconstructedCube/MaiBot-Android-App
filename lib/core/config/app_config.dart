import 'dart:io';

const bool product = bool.fromEnvironment('dart.vm.product');

class Config {
  // 应用包名
  static const String packageName = 'com.maibot.maibot_android';

  // 与原生侧通信的 MethodChannel 名称
  static const String methodChannel = 'maibot_channel';

  // Ubuntu系统镜像文件名
  static const String ubuntuFileName = 'ubuntu-noble-aarch64-pd-v4.18.0.tar.xz';

  // GitHub 仓库信息
  static const String githubOwner = 'DeconstructedCube';
  static const String githubRepo = 'MaiBot-Android-App';
  static const String githubReleasesPath =
      '/repos/$githubOwner/$githubRepo/releases/latest';

  // GitHub API 镜像源列表（按优先级排序）
  static const List<String> githubApiMirrors = [
    'https://ghfast.top',
    'https://gh-proxy.com',
    'https://mirror.ghproxy.com',
    'https://hub.gitmirror.com',
  ];

  // GitHub 官方 API
  static const String githubApi = 'https://api.github.com';

  // GitHub 官方下载地址
  static const String githubDownloadBase =
      'https://github.com/$githubOwner/$githubRepo/releases/download';

  // 下载镜像源列表
  static const List<Map<String, String>> downloadMirrors = [
    {
      'name': 'Ghfast镜像下载',
      'icon': 'speed',
      'url': 'https://ghfast.top',
    },
    {
      'name': 'GHProxy镜像下载',
      'icon': 'speed',
      'url': 'https://gh-proxy.com',
    },
    {
      'name': 'Mirror GHProxy镜像下载',
      'icon': 'speed',
      'url': 'https://mirror.ghproxy.com',
    },
    {
      'name': 'Hub Gitmirror镜像下载',
      'icon': 'speed',
      'url': 'https://hub.gitmirror.com',
    },
  ];
}

/// 全局镜像源与网络加速注册中心（单一事实源 SSOT）
class MirrorRegistry {
  /// GitHub 原始资源/克隆加速前缀（末尾含 `/` 或为空代表官方直连）
  static const List<String> githubPrefixMirrors = [
    'https://gh-proxy.com/',
    'https://mirror.ghproxy.com/',
    'https://ghfast.top/',
    '',
  ];

  static List<String> _activeGithubPrefixMirrors = List.from(githubPrefixMirrors);
  static List<String> get activeGithubPrefixMirrors => _activeGithubPrefixMirrors;

  static String _activePypiMirror = pypiPrimaryMirror;
  static String get activePypiMirror => _activePypiMirror;

  static bool _isDirectNetwork = false;
  static bool get isDirectNetwork => _isDirectNetwork;

  /// Ubuntu Ports (ARM64) APT 软件源镜像列表
  static const List<String> aptPortMirrors = [
    'http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/',
    'http://mirrors.ustc.edu.cn/ubuntu-ports/',
    'http://mirrors.aliyun.com/ubuntu-ports/',
    'http://mirrors.volces.com/ubuntu-ports/',
    'http://ports.ubuntu.com/ubuntu-ports/',
  ];

  /// Python PyPI 主镜像源
  static const String pypiPrimaryMirror =
      'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple';

  /// Python PyPI 备用镜像源
  static const String pypiExtraMirrors =
      'https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple/';

  /// 容器默认公共 DNS 列表
  static const List<String> dnsNameservers = [
    '223.5.5.5',
    '119.29.29.29',
    '114.114.114.114',
    '8.8.8.8',
  ];

  /// 在安装流水线开始前，并发探测 GitHub 与 PyPI 线路，优选最佳网络线路（挂梯子优先直连）
  static Future<void> probeFastestMirrors({void Function(String)? onLog}) async {
    onLog?.call('\x1b[36m[网络]\x1b[0m 测试网络连接...\r\n');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);

    // 1. 并发探测 GitHub 线路（直连 vs 镜像）
    Future<({String prefix, int latency, bool ok})> testGithubPrefix(String prefix) async {
      final sw = Stopwatch()..start();
      try {
        final url = prefix.isEmpty
            ? 'https://raw.githubusercontent.com/Mai-with-u/MaiBot/main/pyproject.toml'
            : '${prefix}https://raw.githubusercontent.com/Mai-with-u/MaiBot/main/pyproject.toml';
        final uri = Uri.parse(url);
        final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
        req.followRedirects = true;
        req.maxRedirects = 3;
        final res = await req.close().timeout(const Duration(seconds: 4));
        sw.stop();
        final ok = res.statusCode >= 200 && res.statusCode < 400;
        await res.drain();
        return (prefix: prefix, latency: ok ? sw.elapsedMilliseconds : 99999, ok: ok);
      } catch (_) {
        return (prefix: prefix, latency: 99999, ok: false);
      }
    }

    final candidatePrefixes = [
      '', // 官方源
      'https://gh-proxy.com/',
      'https://mirror.ghproxy.com/',
      'https://ghfast.top/',
    ];

    try {
      final githubResults = await Future.wait(candidatePrefixes.map(testGithubPrefix));
      final directResult = githubResults.firstWhere((r) => r.prefix == '', orElse: () => (prefix: '', latency: 99999, ok: false));

      if (directResult.ok && directResult.latency <= 2000) {
        _isDirectNetwork = true;
        _activeGithubPrefixMirrors = ['', ...candidatePrefixes.where((p) => p.isNotEmpty)];
        onLog?.call('\x1b[32m[网络]\x1b[0m GitHub: 官方源 (${directResult.latency}ms)\r\n');
      } else {
        _isDirectNetwork = false;
        final validMirrors = githubResults.where((r) => r.ok).toList()
          ..sort((a, b) => a.latency.compareTo(b.latency));

        if (validMirrors.isNotEmpty) {
          final sortedPrefixes = validMirrors.map((m) => m.prefix).toList();
          for (final p in candidatePrefixes) {
            if (!sortedPrefixes.contains(p)) sortedPrefixes.add(p);
          }
          _activeGithubPrefixMirrors = sortedPrefixes;
          final best = validMirrors.first;
          final label = best.prefix.isEmpty ? '官方源' : best.prefix;
          onLog?.call('\x1b[32m[网络]\x1b[0m GitHub: $label (${best.latency}ms)\r\n');
        } else {
          onLog?.call('\x1b[33m[网络]\x1b[0m 测速超时，使用默认源\r\n');
        }
      }
    } catch (_) {}

    // 2. 探测 PyPI 线路
    Future<({String url, int latency, bool ok})> testPypi(String pypiUrl) async {
      final sw = Stopwatch()..start();
      try {
        final uri = Uri.parse(pypiUrl);
        final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
        final res = await req.close().timeout(const Duration(seconds: 4));
        sw.stop();
        final ok = res.statusCode >= 200 && res.statusCode < 400;
        await res.drain();
        return (url: pypiUrl, latency: ok ? sw.elapsedMilliseconds : 99999, ok: ok);
      } catch (_) {
        return (url: pypiUrl, latency: 99999, ok: false);
      }
    }

    final pypiCandidates = [
      pypiPrimaryMirror, // 清华源
      'https://mirrors.aliyun.com/pypi/simple/', // 阿里源
      'https://pypi.org/simple/', // 官方源
    ];

    try {
      final pypiResults = await Future.wait(pypiCandidates.map(testPypi));
      final validPypi = pypiResults.where((r) => r.ok).toList()
        ..sort((a, b) => a.latency.compareTo(b.latency));
      if (validPypi.isNotEmpty) {
        _activePypiMirror = validPypi.first.url;
        onLog?.call('\x1b[32m[PyPI]\x1b[0m 软件源: $_activePypiMirror (${validPypi.first.latency}ms)\r\n');
      }
    } catch (_) {} finally {
      client.close();
    }
  }
}

/// 本地服务端口常量
class Ports {
  // PTY 输出转发 Socket（前台服务监听，UI 侧连接）
  static const int maibotPtySocket = 20001;

  // Web 服务端口
  static const int maibotWeb = 8001;

  // 原生守护进程 PTY 存活探测端口
  static const List<int> ptyProbePorts = [maibotPtySocket];

  // 业务 Web 就绪探测端口（MaiBot 启动完成后任一端口可连即视为 Web 就绪）
  static const List<int> localhostProbePorts = [maibotWeb, 6185];
}
