/// 安装流水线阶段
enum InstallStage {
  extractingRootfs(0.05, '解压 Ubuntu 系统...'),
  configuringNetwork(0.25, '配置系统环境...'),
  checkingSystemDeps(0.40, '检查系统依赖...'),
  installingUv(0.52, '安装 uv 工具...'),
  cloningMaibot(0.64, '下载 MaiBot 源码...'),
  cloningAdapter(0.72, '安装适配器插件...'),
  syncingPythonEnv(0.84, '安装 Python 依赖...'),
  installingNapcat(0.92, '安装 NapCat 组件...'),
  restoringBackup(0.95, '恢复数据与配置...'),
  completed(0.96, '准备启动服务...');

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

/// 应用启动生命周期状态机
class AppLifecycleStateMachine {
  AppPhase _phase = AppPhase.uninitialized;
  InstallStage? _installStage;
  bool _backendRequested = false;
  bool _portsReady = false;
  bool _loginReady = false;
  String _statusMessage = '准备环境中...';
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

  /// 是否已满足进入主界面的条件
  bool get canEnterWebview => _phase == AppPhase.ready && _portsReady && _loginReady;

  /// 上报开始解压根文件系统
  void beginExtraction({String? message}) {
    _errorMessage = null;
    _installStage = InstallStage.extractingRootfs;
    _statusMessage = message ?? InstallStage.extractingRootfs.defaultLabel;
    _progress = InstallStage.extractingRootfs.progressWeight;
    _recomputePhase();
  }

  /// 上报解压根文件系统实时进度 (ratio: 0.0 ~ 1.0)
  void updateExtractionProgress({required double ratio, String? message}) {
    _errorMessage = null;
    _installStage = InstallStage.extractingRootfs;
    if (message != null && message.isNotEmpty) {
      _statusMessage = message;
    }
    final computed = (0.05 + ratio.clamp(0.0, 1.0) * 0.17);
    if (computed > _progress) {
      _progress = computed;
    }
    _recomputePhase();
  }

  /// 仅更新状态描述文本
  void updateStatus(String message) {
    if (message.isNotEmpty) {
      _statusMessage = message;
    }
  }

  /// 上报进入配置阶段
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

  /// 上报请求启动后台服务
  void markBackendRequested({String? message}) {
    _errorMessage = null;
    _backendRequested = true;
    _portsReady = false;
    _statusMessage = message ?? '启动后台服务...';
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
      _statusMessage = '服务已就绪，等待登录 QQ';
    } else {
      _statusMessage = '全部服务已就绪';
    }
    _progress = _loginReady ? 1.0 : 0.98;
    _recomputePhase();
  }

  /// 上报登录就绪
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

  /// 上报发生错误
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
