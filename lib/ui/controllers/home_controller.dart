import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:xterm/xterm.dart';

import '../../core/config/app_config.dart';
import '../../core/services/backup_service.dart';
import '../../core/services/installer_service.dart';
import '../../core/services/port_probe_service.dart';
import '../../core/services/progress_tracker.dart';
import '../../core/services/socket_stream_client.dart';
import '../../core/services/backend_process_manager.dart';
import '../../core/state/app_lifecycle_state_machine.dart';
import 'napcat_controller.dart';
import 'napcat_log_parser.dart';
import 'terminal_tab_manager.dart';
import 'webview_controller.dart';
import '../pages/permission_request_page.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  // 终端标签页管理器
  late final TerminalTabManager terminalTabManager;
  Setting privacySetting = 'privacy'.setting;
  Setting showTerminalWhiteText = 'show_terminal_white_text'.setting;
  Setting hideFromRecents = 'hide_from_recents'.setting;

  // 确定性启动生命周期状态机与有界端口探测器
  final AppLifecycleStateMachine lifecycle = AppLifecycleStateMachine();
  final PortProbeService _portProber = PortProbeService();

  // 前台服务 PTY 转发 Socket 客户端
  late final SocketStreamClient maibotClient;
  late final SocketStreamClient napcatClient;

  late Terminal terminal = Terminal(
    maxLines: 5000,
    onOutput: (data) {
      maibotClient.socket?.add(utf8.encode(data));
    },
    onResize: (width, height, pixelWidth, pixelHeight) {
      Log.d('maibot terminal resize: $width x $height', tag: 'HomeController');
    },
  );

  late Terminal napcatShowTerminal = Terminal(
    maxLines: 5000,
    onOutput: (data) {
      napcatClient.socket?.add(utf8.encode(data));
    },
    onResize: (width, height, pixelWidth, pixelHeight) {
      Log.d('napcat terminal resize: $width x $height', tag: 'HomeController');
    },
  );

  // 安装进度跟踪器
  late final ProgressTracker progressTracker;

  bool _isAppInForeground = true;

  double get progress => progressTracker.progress;
  String get currentProgress => progressTracker.currentProgress;

  final WebviewController webviewController = Get.put(WebviewController());
  final NapcatController napcatController = Get.put(NapcatController());

  void _syncProgressFromLifecycle() {
    progressTracker.updateFromStateMachine(
      lifecycle.progress,
      lifecycle.statusMessage,
    );
    update();
  }

  /// 检查状态机是否满足进入主控制台的条件（Web 端口已就绪 且 登录已处理 且 应用在前台）
  void _checkAndNavigateToWebview() {
    if (napcatController.isQrcodeProcessed ||
        napcatController.napCatWebUiToken.isNotEmpty) {
      if (!lifecycle.loginReady) {
        lifecycle.markLoginReady();
        _syncProgressFromLifecycle();
      }
    }

    if (lifecycle.canEnterWebview &&
        _isAppInForeground &&
        !webviewController.webviewHasOpen) {
      _portProber.cancel();
      webviewController.navigateToWebview();
    }
  }

  void _handleMaibotLine(String line) {
    napcatController.handleMaibotOutput(line);
    final cleanLine = NapcatLogParser.stripAnsi(line);
    if (cleanLine.contains('访问地址:')) {
      lifecycle.markPortsReady(message: 'MaiBot Web 服务已就绪');
      _syncProgressFromLifecycle();
      _checkAndNavigateToWebview();
      Future.delayed(const Duration(milliseconds: 2000), () => update());
    }
  }

  void _handleNapcatLine(String line) {
    napcatController.handleNapcatOutput(line);
    _checkAndNavigateToWebview();
  }

  /// 启动有界端口重试探测，取代旧的无限 Timer.periodic
  void _startWebPortProbe() {
    unawaited(
      _portProber.waitForAnyPort(
        Ports.localhostProbePorts,
        onReady: (port) {
          Log.i('有界探测命中 Web 端口 127.0.0.1:$port，标记端口就绪', tag: 'MaiBot');
          lifecycle.markPortsReady();
          _syncProgressFromLifecycle();
          _checkAndNavigateToWebview();
        },
      ),
    );
  }

  /// 初始化环境并驱动安装/启动流水线
  Future<void> loadMaiBot() async {
    // 区分原生守护进程（PTY 20001/20002）与业务 Web 端口（8001/6185）
    if (await BackendProcessManager.isDaemonRunning()) {
      Log.i('检测到原生守护进程已在运行，跳过安装流水线直接连接', tag: 'MaiBot');
      lifecycle.markBackendRequested(message: '正在恢复后台运行会话...');
      if (await BackendProcessManager.isWebServiceReady()) {
        lifecycle.markPortsReady();
      } else {
        _startWebPortProbe();
      }
      _syncProgressFromLifecycle();
      maibotClient.connect();
      napcatClient.connect();
      _checkAndNavigateToWebview();
      return;
    }

    await Directory(RuntimeEnvir.tmpPath).create(recursive: true);
    await Directory(RuntimeEnvir.homePath).create(recursive: true);
    await Directory(RuntimeEnvir.binPath).create(recursive: true);

    if (!InstallerService.isRootfsReady()) {
      lifecycle.beginExtraction();
      _syncProgressFromLifecycle();
      await AssetsUtils.copyAssetToPath(
        'assets/${Config.ubuntuFileName}',
        '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}',
      );
    }

    final success = await InstallerService.runInstallPipeline(
      onStage: (stage, msg) {
        if (stage == InstallStage.extractingRootfs) {
          lifecycle.beginExtraction(message: msg);
        } else {
          lifecycle.beginConfiguration(stage: stage, message: msg);
        }
        _syncProgressFromLifecycle();
      },
      onProgress: (msg) {
        if (lifecycle.phase == AppPhase.uninitialized) {
          lifecycle.beginConfiguration(message: msg);
        }
        _syncProgressFromLifecycle();
      },
      onLog: (log) {
        terminal.write(log);
      },
    );

    if (!success) {
      lifecycle.fail('安装流水线执行失败，请切换至终端日志排查问题');
      _syncProgressFromLifecycle();
      Log.e('安装流水线执行失败', tag: 'MaiBot');
      return;
    }

    if (InstallerService.lastInstallWasFresh) {
      final backups = await BackupService.getAvailableBackupsAsync();
      if (backups.isNotEmpty) {
        await BackupService.showRestoreDialog(
          isInitialInstall: true,
          onCompleted: () => unawaited(_startBackendServices()),
        );
        return;
      }
    }

    await _startBackendServices();
  }

  /// 启动常驻后台服务并建立 Socket 连接
  Future<void> _startBackendServices() async {
    lifecycle.markBackendRequested(message: '正在启动后台运行环境...');
    _syncProgressFromLifecycle();

    await BackendProcessManager.startService();

    maibotClient.connect();
    napcatClient.connect();
    _startWebPortProbe();
  }

  @override
  void onInit() {
    super.onInit();

    terminalTabManager = TerminalTabManager();

    maibotClient = SocketStreamClient(
      port: Ports.maibotPtySocket,
      onData: (event) => terminal.write(event),
      onLine: _handleMaibotLine,
    );
    napcatClient = SocketStreamClient(
      port: Ports.napcatPtySocket,
      onData: (event) => napcatShowTerminal.write(event),
      onLine: _handleNapcatLine,
    );

    ever(BackendProcessManager.maibotState, (state) {
      if (state == ProcessState.running) {
        _checkAndNavigateToWebview();
      }
    });

    progressTracker = ProgressTracker(
      onChanged: () => update(),
      onNapcatInstalled: () {
        Log.i('检测到 Napcat 已安装，准备就绪', tag: 'MaiBot');
      },
    );
    progressTracker.terminal = terminal;

    if (hideFromRecents.get() == true) {
      setHideFromRecents(true);
    }

    Future.delayed(Duration.zero, () async {
      if (privacySetting.get() == null) {
        await Get.to(PrivacyAgreePage(
          onAgreeTap: () {
            privacySetting.set(true);
            Get.back();
          },
        ));
      }

      if (Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        final manageStorageStatus = await Permission.manageExternalStorage.status;
        final storageStatus = await Permission.storage.status;
        final bool hasStorage =
            manageStorageStatus.isGranted || storageStatus.isGranted;
        final bool hasNotif = notifStatus.isGranted;

        if (!hasNotif || !hasStorage) {
          final completer = Completer<void>();
          await Get.to(PermissionRequestPage(
            onPermissionsGranted: () {
              Get.back();
              if (!completer.isCompleted) completer.complete();
            },
          ));
          await completer.future;
        }
      }

      await loadMaiBot();

      Future.delayed(const Duration(milliseconds: 500), () {
        terminalTabManager.initializeFixedTabs(terminal, napcatShowTerminal);
      });
    });

    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _isAppInForeground = true;
        _checkAndNavigateToWebview();
        break;
      case AppLifecycleState.paused:
        _isAppInForeground = false;
        break;
      default:
        break;
    }
  }

  Future<void> setHideFromRecents(bool value) async {
    hideFromRecents.set(value);
    try {
      const channel = MethodChannel(Config.methodChannel);
      await channel.invokeMethod('hide_from_recents', {'hide': value});
    } catch (e) {
      Log.e('设置从最近活动隐藏失败: $e', tag: 'MaiBot');
    }
  }

  @override
  void onClose() {
    try {
      _portProber.dispose();
      progressTracker.dispose();
      maibotClient.dispose();
      napcatClient.dispose();
    } catch (e) {
      Log.e('清理终端引用时出错: $e', tag: 'MaiBot');
    }

    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
