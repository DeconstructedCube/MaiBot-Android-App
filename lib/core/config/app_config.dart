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
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://mirror.ghproxy.com/',
    '',
  ];

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
}

/// 本地服务端口常量
class Ports {
  // PTY 输出转发 Socket（前台服务监听，UI 侧连接）
  static const int maibotPtySocket = 20001;
  static const int napcatPtySocket = 20002;

  // Web 服务端口
  static const int maibotWeb = 8001;
  static const int napcatWebUi = 6099;
  static const int onebotWsDefault = 8095;

  // 原生守护进程 PTY 存活探测端口
  static const List<int> ptyProbePorts = [maibotPtySocket, napcatPtySocket];

  // 业务 Web 就绪探测端口（MaiBot 启动完成后任一端口可连即视为 Web 就绪）
  static const List<int> localhostProbePorts = [maibotWeb, 6185];
}
