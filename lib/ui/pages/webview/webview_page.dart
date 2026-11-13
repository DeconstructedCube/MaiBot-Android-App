import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'webview_file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../controllers/home_controller.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../../navbar/bottom_nav_bar.dart';
import '../settings/maintenance_actions.dart';

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  int _currentIndex = 0;
  int _previousNavItemCount = 0; // 记录上一次导航栏项目数量

  DateTime? _lastBackPressedTime;
  late final WebViewController _maiBotController;
  final Map<String, WebViewController> _customControllers =
      {}; // 存储自定义 WebView 控制器，使用 URL 作为 key

  final HomeController homeController = Get.find<HomeController>();

  Worker? _customWebViewsWorker;

  void _switchTab(int newIndex) {
    if (_currentIndex == newIndex) return;
    setState(() {
      _currentIndex = newIndex;
    });
  }

  @override
  void initState() {
    super.initState();
    _initMaiBotController();

    // 监听自定义 WebView 列表变化,清理已删除的控制器
    _customWebViewsWorker =
        ever(homeController.webviewController.customWebViews,
            (List<Map<String, String>> webviews) {
      // 清理不再存在的控制器
      final validUrls = webviews.map((wv) => wv['url'] ?? '').toSet();
      final controllersToRemove = _customControllers.keys
          .where((key) => !validUrls.contains(key))
          .toList();
      for (final key in controllersToRemove) {
        _customControllers.remove(key);
      }
    });
  }

  @override
  void dispose() {
    _customWebViewsWorker?.dispose();
    super.dispose();
  }

  // 检查URL是否为本地地址
  bool _isLocalUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      // 检查是否为本地地址
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '0.0.0.0' ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          (host.startsWith('172.') && _isPrivateIp172(host));
    } catch (e) {
      debugPrint('Error parsing URL: $e');
      return false;
    }
  }

  // 检查是否为172.16.0.0 - 172.31.255.255范围的私有IP
  bool _isPrivateIp172(String host) {
    final parts = host.split('.');
    if (parts.length >= 2) {
      final secondOctet = int.tryParse(parts[1]);
      return secondOctet != null && secondOctet >= 16 && secondOctet <= 31;
    }
    return false;
  }

  // 在外部浏览器中打开URL
  Future<void> _launchInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        debugPrint('Cannot launch URL: $url');
        if (mounted) {
          Get.snackbar(
            '无法打开链接',
            '无法在浏览器中打开此链接',
            snackPosition: SnackPosition.BOTTOM,
          );
        }
      }
    } catch (e) {
      debugPrint('Error launching URL: $e');
      if (mounted) {
        Get.snackbar(
          '打开失败',
          '打开链接时出错: $e',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    }
  }

  // 配置 Android 平台 WebView 公共选项（混合内容/本地文件访问/文件选择）
  void _configureAndroidPlatform(
    WebViewController controller, {
    bool enableDebugging = false,
  }) {
    if (controller.platform is AndroidWebViewController) {
      if (enableDebugging) {
        AndroidWebViewController.enableDebugging(true);
      }
      final androidController = controller.platform as AndroidWebViewController;
      androidController
        ..setMediaPlaybackRequiresUserGesture(false)
        // 设置混合内容模式以提高兼容性（Android 9+ 需要）
        ..setMixedContentMode(MixedContentMode.compatibilityMode)
        // 允许访问本地文件和内容
        ..setAllowFileAccess(true)
        ..setAllowContentAccess(true)
        // 设置文件选择回调
        ..setOnShowFileSelector(WebViewFileSelector.handleFileSelection);
    }
  }

  void _initMaiBotController() {
    final initialUrl = homeController.activeWebEntryUrl.value.isNotEmpty
        ? homeController.activeWebEntryUrl.value
        : 'http://127.0.0.1:${homeController.activeWebPort.value}';
    _maiBotController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // 拦截外域URL
            if (!_isLocalUrl(request.url)) {
              debugPrint('Intercepting external URL: ${request.url}');
              _launchInBrowser(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _injectClipboardScript(_maiBotController);
            _configureViewport(_maiBotController);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('MaiBot WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));

    _configureAndroidPlatform(_maiBotController, enableDebugging: kDebugMode);

    _maiBotController.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        final msg = message.message;
        if (msg == 'getClipboardData' || msg.startsWith('getClipboardData:')) {
          final reqId = msg.contains(':') ? msg.substring('getClipboardData:'.length) : '';
          _getClipboardData(_maiBotController, reqId);
        }
      },
    );
  }


  // 创建自定义 WebView 控制器
  WebViewController _createCustomController(String url) {
    final controller = WebViewController();

    // 检查初始URL是否为本地地址，如果是则启用外域拦截
    final shouldInterceptExternal = _isLocalUrl(url);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // 仅对配置为本地URL的WebView启用外域拦截
            if (shouldInterceptExternal && !_isLocalUrl(request.url)) {
              debugPrint(
                  'Intercepting external URL from custom WebView: ${request.url}');
              _launchInBrowser(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String pageUrl) {
            _configureViewport(controller);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Custom WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    _configureAndroidPlatform(controller, enableDebugging: true);

    return controller;
  }

  // 获取或创建自定义 WebView 控制器
  WebViewController _getCustomController(String url) {
    // 如果控制器存在但URL已更改，删除旧控制器并创建新的
    if (_customControllers.containsKey(url)) {
      return _customControllers[url]!;
    }

    // 创建新控制器
    _customControllers[url] = _createCustomController(url);
    return _customControllers[url]!;
  }

  void _injectClipboardScript(WebViewController controller) {
    const String jsCode = '''
      (function() {
        window.__clipboardResolvers = window.__clipboardResolvers || {};
        window.__resolveClipboard = function(id, text) {
          var resolver = window.__clipboardResolvers[id];
          if (resolver) {
            delete window.__clipboardResolvers[id];
            resolver(text || '');
          }
        };
        if (navigator.clipboard) {
          navigator.clipboard.readText = function () {
            return new Promise((resolve) => {
              var id = String(Date.now()) + '_' + Math.random().toString(36).slice(2);
              window.__clipboardResolvers[id] = resolve;
              Android.postMessage('getClipboardData:' + id);
              setTimeout(() => {
                if (window.__clipboardResolvers[id]) {
                  delete window.__clipboardResolvers[id];
                  resolve('');
                }
              }, 1500);
            });
          };
        }
      })();
    ''';
    controller.runJavaScript(jsCode);
  }

  void _configureViewport(WebViewController controller) {
    const String jsCode = '''
      (function() {
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          meta.content = 'width=device-width, initial-scale=1.0, user-scalable=yes';
          document.head.appendChild(meta);
        }
        // Ensure horizontal scroll is allowed if content overflows
        document.body.style.overflowX = 'auto';
        document.documentElement.style.overflowX = 'auto';
      })();
    ''';
    controller.runJavaScript(jsCode);
  }

  Future<void> _getClipboardData(WebViewController controller, String reqId) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text ?? '';
    if (reqId.isNotEmpty) {
      await controller.runJavaScript(
        'window.__resolveClipboard && window.__resolveClipboard(${jsonEncode(reqId)}, ${jsonEncode(text)});',
      );
    } else {
      await controller.runJavaScript('window.clipboardText = ${jsonEncode(text)};');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final customWebViews = homeController.webviewController.customWebViews;

      final List<Widget> pages = [
        // 1. MaiBot 配置页面
        Visibility(
          key: const ValueKey('maibot_webview_visibility'),
          visible: _currentIndex == 0,
          maintainState: true,
          child: WebViewWidget(
              key: const ValueKey('maibot_webview'),
              controller: _maiBotController),
        ),

        // 3. 自定义 WebView 页面
        ...List.generate(customWebViews.length, (index) {
          final webview = customWebViews[index];
          final url = webview['url'] ?? '';
          final int pageIndex = index + 1;
          return Visibility(
            key: ValueKey('custom_webview_visibility_$url'),
            visible: _currentIndex == pageIndex,
            maintainState: true,
            child: WebViewWidget(
              key: ValueKey('custom_webview_$url'),
              controller: _getCustomController(url),
            ),
          );
        }),
      ];

      final int settingsIndex = pages.length + 1;
      final int currentNavItemCount = pages.length + 2;

      int validCurrentIndex = _currentIndex;
      if (_previousNavItemCount != 0 &&
          _previousNavItemCount != currentNavItemCount) {
        validCurrentIndex = settingsIndex;
        _previousNavItemCount = currentNavItemCount;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _currentIndex = settingsIndex;
            });
          }
        });
      } else if (_previousNavItemCount == 0) {
        _previousNavItemCount = currentNavItemCount;
      }

      final isDark = theme.brightness == Brightness.dark;

      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        ),
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            unawaited(() async {
              if (didPop) return;

              // 1. 如果当前是自定义 WebView 且内部可回退，优先回退页面历史
              if (_currentIndex > 0 && _currentIndex <= customWebViews.length) {
                final customUrl = customWebViews[_currentIndex - 1]['url'] ?? '';
                final customCtrl = _customControllers[customUrl];
                if (customCtrl != null && await customCtrl.canGoBack()) {
                  await customCtrl.goBack();
                  return;
                }
              }

              // 2. 如果当前不是 MaiBot 主控制台标签页，按返回键优先返回主标签页
              if (_currentIndex != 0) {
                _switchTab(0);
                return;
              }
              // 2. 如果 MaiBot WebView 内部有历史页面可回退，则回退上一页
              if (await _maiBotController.canGoBack()) {
                await _maiBotController.goBack();
                return;
              }

              // 3. 在主页根路径时，双击返回键退出应用或移至后台
              final now = DateTime.now();
              if (_lastBackPressedTime == null ||
                  now.difference(_lastBackPressedTime!) > const Duration(seconds: 2)) {
                _lastBackPressedTime = now;
                Get.snackbar(
                  '提示',
                  '再次按返回键退出应用',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 2),
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                );
                return;
              }

              // 执行彻底安全退出（停机并清理后台）
              await MaintenanceActions.performExit(showConfirmation: false);
            }());
          },
          child: Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            body: SafeArea(
              top: true,
              bottom: false,
              child: IndexedStack(
                index: validCurrentIndex,
                children: [
                  ...pages,

                  // 4. 终端页面
                  const TerminalTabView(key: ValueKey('terminal_tab_view')),

                  // 5. 软件设置页面
                  SettingsPage(
                    key: const ValueKey('settings_page'),
                    maiBotController: _maiBotController,
                    onNavigate: (index) {
                      _switchTab(index);
                    },
                  ),
                ],
              ),
            ),
            bottomNavigationBar: WebViewBottomNavBar(
              currentIndex: validCurrentIndex,
              onTap: (index) {
                _switchTab(index);
              },
            ),
          ),
        ),
      );
    });
  }
}
