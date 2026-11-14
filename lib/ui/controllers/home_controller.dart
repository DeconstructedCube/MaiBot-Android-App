import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
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
import '../../core/constants/scripts.dart';
import 'maibot_log_parser.dart';
import 'terminal_tab_manager.dart';
import 'webview_controller.dart';
import '../pages/permission_request_page.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  // 终端标签页管理器
  late final TerminalTabManager terminalTabManager;
  Setting privacySetting = 'privacy'.setting;
  Setting hideFromRecents = 'hide_from_recents'.setting;

  // 确定性启动生命周期状态机与有界端口探测器
  final AppLifecycleStateMachine lifecycle = AppLifecycleStateMachine();
  final PortProbeService _portProber = PortProbeService();

  // 前台服务 PTY 转发 Socket 客户端
  late final SocketStreamClient maibotClient;

  late Terminal terminal = Terminal(
    maxLines: 5000,
    onOutput: (data) {
      maibotClient.socket?.add(utf8.encode(data));
    },
    onResize: (width, height, pixelWidth, pixelHeight) {
      Log.d('maibot terminal resize: $width x $height', tag: 'HomeController');
    },
  );

  // 安装进度跟踪器
  late final ProgressTracker progressTracker;

  bool _isAppInForeground = true;
  bool _bootstrapStarted = false;

  double get progress => progressTracker.progress;
  String get currentProgress => progressTracker.currentProgress;

  final WebviewController webviewController = Get.put(WebviewController());
  final RxString maiBotWebUiToken = ''.obs;
  final RxString maiBotTokenSource = ''.obs;
  final RxInt activeWebPort = Ports.maibotWeb.obs;
  final RxString activeWebEntryUrl = ''.obs;
  Worker? _maibotStateWorker;
  void _syncProgressFromLifecycle() {
    progressTracker.updateFromStateMachine(
      lifecycle.progress,
      lifecycle.statusMessage,
    );
    update();
  }

  /// 检查状态机是否满足进入主控制台的条件（Web 端口已就绪 且 应用在前台）
  void _checkAndNavigateToWebview() {
    if (lifecycle.canEnterWebview &&
        _isAppInForeground &&
        !webviewController.webviewHasOpen) {
      _portProber.cancel();
      webviewController.navigateToWebview();
    }
  }

  void _handleMaibotLine(String line) {
    final cleanLine = MaibotLogParser.stripAnsi(line);
    final parsedToken = MaibotLogParser.parseMaibotToken(cleanLine);
    if (parsedToken != null) {
      maiBotWebUiToken.value = parsedToken;
      if (cleanLine.contains('临时登录密码')) {
        maiBotTokenSource.value = 'temporary';
      }
    } else if (cleanLine.contains('WebUI') || cleanLine.contains('Token')) {
      unawaited(reloadTokensFromDisk());
    }

    final parsedUrl = MaibotLogParser.parseWebUiUrl(cleanLine);
    if (parsedUrl != null) {
      final uri = Uri.tryParse(parsedUrl);
      if (uri != null && uri.port > 0 && uri.port <= 65535) {
        activeWebPort.value = uri.port;
      }
      activeWebEntryUrl.value = parsedUrl;
      lifecycle.markPortsReady(message: 'MaiBot Web 服务已就绪');
      _syncProgressFromLifecycle();
      unawaited(reloadTokensFromDisk().whenComplete(_checkAndNavigateToWebview));
      Future.delayed(const Duration(milliseconds: 2000), () => update());
    }
  }

  /// 从本地优先读取 /root/MaiBot/host/webui.json（兼容旧版 data/webui.json）获取 WebUI 凭据
  Future<bool> reloadTokensFromDisk() async {
    final candidatePaths = [
      '$ubuntuPath/root/MaiBot/host/webui.json',
      '$ubuntuPath/root/MaiBot/data/webui.json',
    ];
    for (final path in candidatePaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final content = await file.readAsString();
          final parsed = jsonDecode(content);
          if (parsed is Map) {
            final token = (parsed['access_token'] ?? parsed['token'])?.toString().trim() ?? '';
            final source = parsed['token_source']?.toString().trim() ?? '';
            if (token.isNotEmpty) {
              maiBotWebUiToken.value = token;
              maiBotTokenSource.value = source;
              Log.i('成功从 $path 读取到 MaiBot Token', tag: 'MaiBot');
              return true;
            }
          }
        }
      } catch (e) {
        Log.e('读取 $path 失败: $e', tag: 'MaiBot');
      }
    }
    return false;
  }

  /// 从 host/config.toml 读取自定义 WebUI 端口并与默认探测端口合并
  Future<List<int>> _resolveProbePorts() async {
    final ports = <int>[...Ports.localhostProbePorts];
    try {
      final hostConfig = File('$ubuntuPath/root/MaiBot/host/config.toml');
      if (await hostConfig.exists()) {
        final content = await hostConfig.readAsString();
        final match = RegExp(r'^\s*port\s*=\s*(\d{2,5})\b', multiLine: true).firstMatch(content);
        final customPort = int.tryParse(match?.group(1) ?? '');
        if (customPort != null && customPort > 0 && customPort <= 65535) {
          ports.remove(customPort);
          ports.insert(0, customPort);
        }
      }
    } catch (_) {}
    return ports;
  }

  /// 启动有界端口重试探测，取代旧的无限 Timer.periodic
  void _startWebPortProbe() {
    unawaited(() async {
      final probePorts = await _resolveProbePorts();
      await _portProber.waitForAnyPort(
        probePorts,
        onReady: (port) {
          Log.i('有界探测命中 Web 端口 127.0.0.1:$port，标记端口就绪', tag: 'MaiBot');
          activeWebPort.value = port;
          lifecycle.markPortsReady();
          _syncProgressFromLifecycle();
          unawaited(reloadTokensFromDisk().whenComplete(_checkAndNavigateToWebview));
        },
      );
    }());
  }
  /// 首次或同意隐私政策后的环境引导流水线
  Future<void> startBootstrapSequence() async {
    if (_bootstrapStarted) return;
    _bootstrapStarted = true;

    try {
      if (Platform.isAndroid) {
        try {
          final notifStatus = await Permission.notification.status;
          if (!notifStatus.isGranted) {
            await Get.to(() => PermissionRequestPage(
              onPermissionsGranted: () {
                Get.back();
              },
            ));
          }
        } catch (e) {
          Log.w('通知权限检查跳过: $e', tag: 'HomeController');
        }
      }
    } catch (e) {
      Log.w('启动前置权限/隐私确认异常: $e', tag: 'HomeController');
    }

    try {
      await loadMaiBot();
    } catch (e, stack) {
      Log.e('loadMaiBot 启动致命异常: $e\n$stack', tag: 'HomeController');
      terminal.write('\x1b[31m[致命错误]\x1b[0m 后台初始化异常: $e\r\n');
      lifecycle.fail('后台启动异常: $e');
      _syncProgressFromLifecycle();
    }
  }

  /// 初始化环境并驱动安装/启动流水线
  Future<void> loadMaiBot() async {
    // 区分原生守护进程（PTY 20001）与业务 Web 端口（8001/6185）
    if (await BackendProcessManager.isDaemonRunning()) {
      Log.i('检测到原生守护进程已在运行，跳过安装流水线直接连接', tag: 'MaiBot');
      lifecycle.markBackendRequested(message: '正在恢复后台运行会话...');
      await reloadTokensFromDisk();
      final probePorts = await _resolveProbePorts();
      final hitPort = await PortProbeService.probeAnyPort(
        probePorts,
        timeout: const Duration(milliseconds: 500),
      );
      if (hitPort != null) {
        activeWebPort.value = hitPort;
        lifecycle.markPortsReady();
      } else {
        _startWebPortProbe();
      }
      _syncProgressFromLifecycle();
      maibotClient.connect();
      _checkAndNavigateToWebview();
      return;
    }

    await Directory(RuntimeEnvir.tmpPath).create(recursive: true);
    await Directory(RuntimeEnvir.homePath).create(recursive: true);
    await Directory(RuntimeEnvir.binPath).create(recursive: true);

    if (!InstallerService.isRootfsReady()) {
      lifecycle.beginExtraction();
      _syncProgressFromLifecycle();
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
      onProgress: (msg, [ratio]) {
        if (lifecycle.phase == AppPhase.extracting && ratio != null) {
          lifecycle.updateExtractionProgress(ratio: ratio, message: msg);
        } else if (lifecycle.phase == AppPhase.uninitialized) {
          lifecycle.beginConfiguration(message: msg);
        } else {
          lifecycle.updateStatus(msg);
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
    terminal.write('\x1b[36m[系统]\x1b[0m 正在启动 MaiBot 后台服务...\r\n');

    await BackendProcessManager.startService(
      cols: terminal.viewWidth > 0 ? terminal.viewWidth : 60,
      rows: terminal.viewHeight > 0 ? terminal.viewHeight : 28,
    );
    unawaited(reloadTokensFromDisk());

    maibotClient.connect();
    _startWebPortProbe();
  }

  @override
  void onInit() {
    super.onInit();

    terminalTabManager = TerminalTabManager();
    terminalTabManager.initializeFixedTabs(terminal);

    maibotClient = SocketStreamClient(
      port: Ports.maibotPtySocket,
      onHistoryReplayStart: () {
        terminal.buffer.clear();
        terminal.buffer.setCursor(0, 0);
      },
      onData: (event) => terminal.write(event),
      onLine: _handleMaibotLine,
    );
    unawaited(reloadTokensFromDisk());

    _maibotStateWorker = ever(BackendProcessManager.maibotState, (state) {
      if (state == ProcessState.running) {
        _checkAndNavigateToWebview();
      }
    });

    progressTracker = ProgressTracker(
      onChanged: () => update(),
    );
    progressTracker.terminal = terminal;

    if (hideFromRecents.get() == true) {
      setHideFromRecents(true);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (privacySetting.get() == true) {
        await startBootstrapSequence();
      }
    });

    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _isAppInForeground = true;
        maibotClient.resumeReconnect();
        _checkAndNavigateToWebview();
        break;
      case AppLifecycleState.paused:
        _isAppInForeground = false;
        maibotClient.pauseReconnect();
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
      _maibotStateWorker?.dispose();
      _portProber.dispose();
      progressTracker.dispose();
      maibotClient.dispose();
      terminalTabManager.onClose();
    } catch (e) {
      Log.e('清理终端引用时出错: $e', tag: 'MaiBot');
    }
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
