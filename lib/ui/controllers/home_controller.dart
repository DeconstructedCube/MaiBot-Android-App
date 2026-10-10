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
import '../../core/services/progress_tracker.dart';
import '../../core/services/socket_stream_client.dart';
import '../../core/services/backend_process_manager.dart';
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

  bool _isLocalhostDetected = false; // localhost:6185 检测标志
  bool _isAppInForeground = true; // 应用是否在前台
  Timer? _localhostProbeTimer; // [Fix 4.2 / 5.1] 本地端口主动探测定时器

  double get progress => progressTracker.progress;
  String get currentProgress => progressTracker.currentProgress;

  final WebviewController webviewController = Get.put(WebviewController());
  final NapcatController napcatController = Get.put(NapcatController());

  // 检查两个条件是否都满足，如果满足则触发跳转
  void _checkAndNavigateToWebview() {
    // 只要本地端口就绪且登录已处理且应用在前台时跳转
    if (_isLocalhostDetected &&
        (napcatController.isQrcodeProcessed || napcatController.napCatWebUiToken.isNotEmpty) &&
        _isAppInForeground &&
        !webviewController.webviewHasOpen) {
      webviewController.navigateToWebview();
    }
  }

  void _handleMaibotLine(String line) {
    napcatController.handleMaibotOutput(line);
    final cleanLine = NapcatLogParser.stripAnsi(line);
    if (cleanLine.contains('访问地址:')) {
      _isLocalhostDetected = true;
      // 仅在非历史回放（实时流数据）时增加进度计数，防止重连重放触发
      if (!maibotClient.isReplaying) {
        progressTracker.bump();
      }
      _checkAndNavigateToWebview();
      Future.delayed(const Duration(milliseconds: 2000), () => update());
    }
  }

  void _handleNapcatLine(String line) {
    napcatController.handleNapcatOutput(line);
    _checkAndNavigateToWebview();
  }

  // 初始化环境，将动态库中的文件链接到数据目录
  // Init environment and link files from the dynamic library to the data directory
  Future<void> loadMaiBot() async {
    // 如果检测到后台服务已在运行，直接连接并跳过重复解压与安装
    if (await BackendProcessManager.isBackendRunning()) {
      Log.i('后台服务已在运行，跳过安装流水线直接连接', tag: 'MaiBot');
      _isLocalhostDetected = true;
      maibotClient.connect();
      napcatClient.connect();
      _checkAndNavigateToWebview();
      return;
    }

    // 初始化环境
    await Directory(RuntimeEnvir.tmpPath).create(recursive: true);
    await Directory(RuntimeEnvir.homePath).create(recursive: true);
    await Directory(RuntimeEnvir.binPath).create(recursive: true);

    // 仅在根文件系统尚未就绪时才从 Asset 拷贝 61.2MB 压缩包，避免每次冷启动带来冗余 I/O
    if (!InstallerService.isRootfsReady()) {
      await AssetsUtils.copyAssetToPath('assets/${Config.ubuntuFileName}',
          '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}');
    }
    
    // 开始 Dart 驱动的安装流
    final success = await InstallerService.runInstallPipeline(
      onProgress: (msg) {
        progressTracker.setProgress(msg);
        progressTracker.bump();
        update();
      },
      onLog: (log) {
        terminal.write(log);
      },
    );

    if (!success) {
      Log.e('安装流水线执行失败', tag: 'MaiBot');
      return;
    }
    // 首次全新安装完成时，若检测到本地存在历史备份，提示用户是否选择性恢复备份
    if (InstallerService.lastInstallWasFresh) {
      final backups = BackupService.getAvailableBackups();
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
    progressTracker.setProgress('正在启动后台运行环境...');

    await BackendProcessManager.startService();

    // 前端连接到后端 Socket
    maibotClient.connect();
    napcatClient.connect();
  }

  @override
  void onInit() {
    super.onInit();

    // 初始化终端标签页管理器
    terminalTabManager = TerminalTabManager();

    // 初始化 Socket 客户端（须先于 terminal/napcatShowTerminal 的首次访问，
    // 它们的 onOutput 回调会引用 client.socket）
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

    // 监听 MaiBot 进程状态变更以协助触发 UI 状态更新
    ever(BackendProcessManager.maibotState, (state) {
      if (state == ProcessState.running) {
        _checkAndNavigateToWebview();
      }
    });

    // 初始化进度跟踪器（terminal 尚未访问，延迟注入）
    progressTracker = ProgressTracker(
      onChanged: () => update(),
      // NapCat 安装完成时拉起其 PTY
      onNapcatInstalled: () {
        Log.i('检测到 Napcat 已安装，准备就绪', tag: 'MaiBot');
      },
    );
    progressTracker.terminal = terminal;

    // 初始化隐藏最近活动状态
    if (hideFromRecents.get() == true) {
      setHideFromRecents(true);
    }
    // 为 Google Play 上架做准备
    // For Google Play
    Future.delayed(Duration.zero, () async {
      if (privacySetting.get() == null) {
        await Get.to(PrivacyAgreePage(
          onAgreeTap: () {
            privacySetting.set(true);
            Get.back();
          },
        ));
      }

      // 检查必须权限（通知权限与存储权限）
      if (Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        final manageStorageStatus = await Permission.manageExternalStorage.status;
        final storageStatus = await Permission.storage.status;
        final bool hasStorage = manageStorageStatus.isGranted || storageStatus.isGranted;
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

      // 优先检查后台服务是否已在运行
      final isRunning = await BackendProcessManager.isBackendRunning();
      if (isRunning) {
        Log.i('检测到后台服务已在运行，直接连接 Socket 并恢复状态', tag: 'MaiBot');
        _isLocalhostDetected = true;
        maibotClient.connect();
        napcatClient.connect();
        _checkAndNavigateToWebview();
      } else {
        // 加载并启动 MaiBot
        await loadMaiBot();
      }
      // 在终端创建完成后初始化固定标签页
      Future.delayed(const Duration(milliseconds: 500), () {
        terminalTabManager.initializeFixedTabs(terminal, napcatShowTerminal);
      });
    });

    // [Fix 4.2 / 5.1] 定时主动探测本地 8001 端口并检查跳转条件，解开多重 AND 条件跳转死锁并兜底日志丢失
    _localhostProbeTimer?.cancel();
    _localhostProbeTimer =
        Timer.periodic(const Duration(seconds: 2), (timer) {
      unawaited(() async {
        if (webviewController.webviewHasOpen) {
          timer.cancel();
          return;
        }
        if (!_isLocalhostDetected) {
          for (final port in Ports.localhostProbePorts) {
            try {
              final socket = await Socket.connect('127.0.0.1', port,
                  timeout: const Duration(milliseconds: 800));
              await socket.close();
              _isLocalhostDetected = true;
              Log.i('主动探测 127.0.0.1:$port 成功，设置 _isLocalhostDetected = true', tag: 'MaiBot');
              break;
            } catch (_) {}
          }
        }
        _checkAndNavigateToWebview();
      }());
    });
    // 监听应用生命周期状态变化
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

  // 设置是否从最近活动中隐藏自身
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
      progressTracker.dispose();
      _localhostProbeTimer?.cancel();
      maibotClient.dispose();
      napcatClient.dispose();
    } catch (e) {
      Log.e('清理终端引用时出错: $e', tag: 'MaiBot');
    }

    // 移除生命周期观察者
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
