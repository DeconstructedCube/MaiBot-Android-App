import 'dart:async';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import '../config/app_config.dart';
import '../constants/scripts.dart' as scripts;
import 'config_service.dart';
import 'port_probe_service.dart';
import '../../ui/pages/settings/maintenance_actions.dart';

enum ProcessState {
  stopped,
  starting,
  running,
  stopping,
  restarting,
  error;

  static ProcessState fromString(String val) {
    switch (val.toUpperCase()) {
      case 'STARTING':
        return ProcessState.starting;
      case 'RUNNING':
        return ProcessState.running;
      case 'STOPPING':
        return ProcessState.stopping;
      case 'RESTARTING':
        return ProcessState.restarting;
      case 'ERROR':
        return ProcessState.error;
      case 'STOPPED':
      default:
        return ProcessState.stopped;
    }
  }
}

enum ServiceTarget {
  all,
  maibot,
  napcat,
}

/// 统一后端进程与容器生命周期管理器
class BackendProcessManager {
  static const MethodChannel _channel = MethodChannel(Config.methodChannel);

  // 响应式状态
  static final Rx<ProcessState> maibotState = ProcessState.stopped.obs;
  static final Rx<ProcessState> napcatState = ProcessState.stopped.obs;
  static final RxInt maibotRetryCount = 0.obs;
  static final RxInt napcatRetryCount = 0.obs;
  static final RxInt maibotPid = (-1).obs;
  static final RxInt napcatPid = (-1).obs;

  static bool _userClickedStop = false;
  static bool get userClickedStop => _userClickedStop;

  /// 初始化状态与事件监听
  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'exit_app') {
        Log.i('收到通知栏退出指令，正在退出应用...', tag: 'BackendProcessManager');
        await MaintenanceActions.performExit(showConfirmation: false);
      }
    });
    Log.d('BackendProcessManager initialized', tag: 'BackendProcessManager');
  }

  /// 探测原生后台守护服务（ProotService PTY 转发端口）是否已在运行
  static Future<bool> isDaemonRunning({
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    return await PortProbeService.isAnyPortOpen(
      Ports.ptyProbePorts,
      timeout: timeout,
    );
  }

  /// 探测 MaiBot Web 控制台端口（8001 / 6185）是否已真正就绪可访问
  static Future<bool> isWebServiceReady({
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    return await PortProbeService.isAnyPortOpen(
      Ports.localhostProbePorts,
      timeout: timeout,
    );
  }

  /// 探测后端服务是否已在运行
  static Future<bool> isBackendRunning({
    List<int> probePorts = const [
      Ports.maibotPtySocket,
      Ports.napcatPtySocket,
      Ports.maibotWeb,
      Ports.napcatWebUi,
    ],
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    return await PortProbeService.isAnyPortOpen(
      probePorts,
      timeout: timeout,
    );
  }

  /// 检查特定服务目标是否已就绪
  static Future<bool> isServiceRunning(ServiceTarget target) async {
    switch (target) {
      case ServiceTarget.maibot:
        return await isBackendRunning(probePorts: [Ports.maibotPtySocket, Ports.maibotWeb]);
      case ServiceTarget.napcat:
        return await isBackendRunning(probePorts: [Ports.napcatPtySocket, Ports.napcatWebUi]);
      case ServiceTarget.all:
        return await isBackendRunning();
    }
  }

  /// 处理从 Socket 接收到的原生状态帧
  static void updateServiceState(String service, String stateStr, {int retry = 0, int pid = -1}) {
    final state = ProcessState.fromString(stateStr);
    final pidInfo = pid > 0 ? ' [PID: $pid]' : '';
    if (service.toLowerCase() == 'maibot') {
      maibotState.value = state;
      maibotRetryCount.value = retry;
      maibotPid.value = pid;
      Log.d('MaiBot 状态更新: $state$pidInfo (重试次数: $retry)', tag: 'BackendProcessManager');
    } else if (service.toLowerCase() == 'napcat') {
      napcatState.value = state;
      napcatRetryCount.value = retry;
      napcatPid.value = pid;
      Log.d('NapCat 状态更新: $state$pidInfo (重试次数: $retry)', tag: 'BackendProcessManager');
    }
  }

  /// 启动后端服务
  static Future<void> startService({ServiceTarget target = ServiceTarget.all}) async {
    _userClickedStop = false;
    Log.i('启动后端服务: target=$target', tag: 'BackendProcessManager');

    try {
      await ConfigService.ensureConfigsSynced();
      await _channel.invokeMethod('control_backend_service', {
        'action': 'start',
        'target': target.name,
        'binPath': RuntimeEnvir.binPath,
        'homePath': RuntimeEnvir.homePath,
        'tmpPath': RuntimeEnvir.tmpPath,
        'ubuntuPath': scripts.ubuntuPath,
      });
    } catch (e) {
      Log.e('启动服务失败: $e', tag: 'BackendProcessManager');
    }
  }

  /// 停止后端服务
  static Future<void> stopService({ServiceTarget target = ServiceTarget.all}) async {
    if (target == ServiceTarget.all) {
      _userClickedStop = true;
    }
    Log.i('停止后端服务: target=$target', tag: 'BackendProcessManager');

    try {
      await _channel.invokeMethod('control_backend_service', {
        'action': 'stop',
        'target': target.name,
        'binPath': RuntimeEnvir.binPath,
        'homePath': RuntimeEnvir.homePath,
        'tmpPath': RuntimeEnvir.tmpPath,
        'ubuntuPath': scripts.ubuntuPath,
      });
    } catch (e) {
      Log.e('停止服务失败: $e', tag: 'BackendProcessManager');
    }
  }

  /// 独立重启单个或全部服务
  static Future<void> restartService({ServiceTarget target = ServiceTarget.all}) async {
    _userClickedStop = false;
    Log.i('重启服务: target=$target', tag: 'BackendProcessManager');

    try {
      await ConfigService.ensureConfigsSynced();
      await _channel.invokeMethod('control_backend_service', {
        'action': 'restart',
        'target': target.name,
        'binPath': RuntimeEnvir.binPath,
        'homePath': RuntimeEnvir.homePath,
        'tmpPath': RuntimeEnvir.tmpPath,
        'ubuntuPath': scripts.ubuntuPath,
      });
    } catch (e) {
      Log.e('重启服务失败: $e', tag: 'BackendProcessManager');
    }
  }

  /// 维护操作安全事务包裹器：平滑停机 -> 执行任务 -> 按需自动恢复
  static Future<T> runMaintenanceTransaction<T>({
    required Future<T> Function() action,
    bool autoRestart = true,
  }) async {
    Log.i('执行维护级安全事务，正在平滑停机...', tag: 'BackendProcessManager');
    try {
      await _channel.invokeMethod('control_backend_service', {
        'action': 'safe_terminate',
        'target': 'all',
        'binPath': RuntimeEnvir.binPath,
        'homePath': RuntimeEnvir.homePath,
        'tmpPath': RuntimeEnvir.tmpPath,
        'ubuntuPath': scripts.ubuntuPath,
      });
    } catch (e) {
      Log.w('通知安全停机异常: $e', tag: 'BackendProcessManager');
    }

    // 等待短暂缓冲确保资源彻底释放
    await Future.delayed(const Duration(milliseconds: 800));

    try {
      return await action();
    } finally {
      if (autoRestart) {
        Log.i('维护操作完成，正在恢复后台服务...', tag: 'BackendProcessManager');
        await startService(target: ServiceTarget.all);
      }
    }
  }
}
