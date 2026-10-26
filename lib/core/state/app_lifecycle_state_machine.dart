/// 安装流水线细分阶段
enum InstallStage {
  extractingRootfs(0.15, '正在解压 Ubuntu 根文件系统...'),
  configuringNetwork(0.25, '配置网络代理与系统参数...'),
  checkingSystemDeps(0.40, '正在检查并安装系统运行依赖...'),
  installingUv(0.52, '正在下载并安装 uv...'),
  cloningMaibot(0.64, '正在获取 MaiBot 源码...'),
  cloningAdapter(0.72, '安装默认适配器插件...'),
  syncingPythonEnv(0.84, '正在同步 Python 依赖库...'),
  installingNapcat(0.92, '正在安装 NapCatQQ 组件...'),
  restoringBackup(0.95, '正在恢复配置与历史数据...'),
  completed(0.96, '初始化完成，正在准备启动...');

  const InstallStage(this.progressWeight, this.defaultLabel);
  final double progressWeight;
  final String defaultLabel;
}

/// 应用启动与运行生命周期主阶段
enum AppPhase {
  uninitialized,
  extracting,
  configuring,
  backendStarting,
  waitingLogin,
  ready,
  error,
}

/// 确定性应用启动生命周期状态机
///
/// 外界仅上报客观事实（开始解压、配置阶段推进、请求启动后端、Web 端口就绪、登录完成、发生错误），
/// 内部通过纯逻辑确定性推导当前 [AppPhase] 与归一化进度 [progress]。
class AppLifecycleStateMachine {
  AppPhase _phase = AppPhase.uninitialized;
  InstallStage? _installStage;
  bool _backendRequested = false;
  bool _portsReady = false;
  bool _loginReady = false;
  String _statusMessage = '正在准备环境...';
  String? _errorMessage;
  double _progress = 0.0;

  AppPhase get phase => _phase;
  InstallStage? get installStage => _installStage;
  bool get backendRequested => _backendRequested;
  bool get portsReady => _portsReady;
  bool get loginReady => _loginReady;
  String get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  double get progress => _progress;

  /// 是否已满足全部进入主控制台的条件（Web 端口已就绪 且 登录已处理）
  bool get canEnterWebview => _phase == AppPhase.ready && _portsReady && _loginReady;

  /// 上报开始解压根文件系统
  void beginExtraction({String? message}) {
    _errorMessage = null;
    _installStage = InstallStage.extractingRootfs;
    _statusMessage = message ?? InstallStage.extractingRootfs.defaultLabel;
    _progress = InstallStage.extractingRootfs.progressWeight;
    _recomputePhase();
  }

  /// 上报进入安装与环境配置子阶段
  void beginConfiguration({InstallStage? stage, String? message}) {
    _errorMessage = null;
    final targetStage = stage ?? InstallStage.configuringNetwork;
    _installStage = targetStage;
    _statusMessage = message ?? targetStage.defaultLabel;
    if (targetStage.progressWeight > _progress) {
      _progress = targetStage.progressWeight;
    }
    _recomputePhase();
  }

  /// 上报已请求拉起后台守护进程（重置端口就绪事实，保留进程内粘性登录事实）
  void markBackendRequested({String? message}) {
    _errorMessage = null;
    _backendRequested = true;
    _portsReady = false;
    _statusMessage = message ?? '正在启动后台运行环境...';
    if (_progress < 0.96) {
      _progress = 0.96;
    }
    _recomputePhase();
  }

  /// 上报本地 Web 服务端口已可连接
  void markPortsReady({String? message}) {
    _errorMessage = null;
    _backendRequested = true;
    _portsReady = true;
    if (message != null && message.isNotEmpty) {
      _statusMessage = message;
    } else if (!_loginReady) {
      _statusMessage = '后台核心已就绪，等待 QQ 登录确认...';
    } else {
      _statusMessage = '全部服务已就绪';
    }
    _progress = _loginReady ? 1.0 : 0.98;
    _recomputePhase();
  }

  /// 上报 NapCat 登录流程已完成或已具备可用凭证（进程内粘性）
  void markLoginReady({String? message}) {
    _errorMessage = null;
    _loginReady = true;
    if (message != null && message.isNotEmpty) {
      _statusMessage = message;
    } else if (_portsReady) {
      _statusMessage = '全部服务已就绪';
    }
    if (_portsReady) {
      _progress = 1.0;
    }
    _recomputePhase();
  }

  /// 上报流程发生致命错误
  void fail(String error) {
    _errorMessage = error;
    _statusMessage = error;
    _phase = AppPhase.error;
  }

  void _recomputePhase() {
    if (_errorMessage != null) {
      _phase = AppPhase.error;
      return;
    }
    if (_portsReady && _loginReady) {
      _phase = AppPhase.ready;
      _progress = 1.0;
      return;
    }
    if (_portsReady && !_loginReady) {
      _phase = AppPhase.waitingLogin;
      return;
    }
    if (_backendRequested) {
      _phase = AppPhase.backendStarting;
      return;
    }
    if (_installStage == InstallStage.extractingRootfs) {
      _phase = AppPhase.extracting;
      return;
    }
    if (_installStage != null) {
      _phase = AppPhase.configuring;
      return;
    }
    _phase = AppPhase.uninitialized;
  }
}
