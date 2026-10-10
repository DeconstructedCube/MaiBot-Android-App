import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../controllers/home_controller.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../../navbar/bottom_nav_bar.dart';
import '../../../core/config/app_config.dart';

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
  late final WebViewController _napCatController;
  final Map<String, WebViewController> _customControllers =
      {}; // 存储自定义 WebView 控制器，使用 URL 作为 key

  final HomeController homeController = Get.find<HomeController>();

  // 标记 MaiBot WebView 是否初始化
  bool _maiBotInitialized = false;

  Worker? _customWebViewsWorker;
  Worker? _napCatTokenWorker;

  @override
  void initState() {
    super.initState();
    _initSystemUI();
    _initMaiBotController();
    _initNapCatController();

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
    _napCatTokenWorker?.dispose();
    _restoreSystemUI();
    super.dispose();
  }

  void _initSystemUI() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  void _restoreSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
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
        ..setOnShowFileSelector(_handleFileSelection);
    }
  }

  void _initMaiBotController() {
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
            _disableZoom(_maiBotController);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('MaiBot WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse('http://127.0.0.1:${Ports.maibotWeb}'));

    _configureAndroidPlatform(_maiBotController, enableDebugging: kDebugMode);

    _maiBotController.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        if (message.message == 'getClipboardData') {
          _getClipboardData(_maiBotController);
        }
      },
    );

    setState(() {
      _maiBotInitialized = true;
    });
  }

  void _initNapCatController() {
    _napCatController = WebViewController()
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
            _disableZoom(_napCatController);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('NapCat WebView error: ${error.description}');
          },
        ),
      );

    // 监听 Token 变化
    _napCatTokenWorker =
        ever(homeController.napcatController.napCatWebUiToken, (String token) {
      if (token.isNotEmpty) {
        final url = 'http://127.0.0.1:${Ports.napcatWebUi}/webui?token=$token';
        _napCatController.loadRequest(Uri.parse(url));
      }
    });

    // 初始加载
    if (homeController.napcatController.napCatWebUiToken.isNotEmpty) {
      final url =
          'http://127.0.0.1:${Ports.napcatWebUi}/webui?token=${homeController.napcatController.napCatWebUiToken.value}';
      _napCatController.loadRequest(Uri.parse(url));
    } else {
      _napCatController.loadRequest(
          Uri.parse('http://127.0.0.1:${Ports.napcatWebUi}/webui'));
    }

    _configureAndroidPlatform(_napCatController, enableDebugging: true);
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
            _disableZoom(controller);
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

  // 处理文件选择
  Future<List<String>> _handleFileSelection(FileSelectorParams params) async {
    try {
      // 用于存放最终选择的文件列表
      List<PlatformFile> pickedFiles = [];

      // 判断是否接受多个文件
      final bool allowMultiple = params.mode == FileSelectorMode.openMultiple;

      // 提取文件类型与允许的扩展名参数
      FileType pickingType = FileType.any;
      List<String>? allowedExtensions;

      if (params.acceptTypes.isNotEmpty) {
        final acceptTypes = params.acceptTypes;

        // 检查是否只接受图片
        final bool isImageOnly = acceptTypes.every((type) =>
            type.startsWith('image/') ||
            [
              'jpg',
              'jpeg',
              'png',
              'gif',
              'webp',
              'bmp',
              '.jpg',
              '.jpeg',
              '.png',
              '.gif',
              '.webp',
              '.bmp'
            ].contains(type.toLowerCase()));

        // 检查是否只接受视频
        final bool isVideoOnly = acceptTypes.every((type) =>
            type.startsWith('video/') ||
            [
              'mp4',
              'avi',
              'mov',
              'mkv',
              'flv',
              'wmv',
              '.mp4',
              '.avi',
              '.mov',
              '.mkv',
              '.flv',
              '.wmv'
            ].contains(type.toLowerCase()));

        // 检查是否只接受音频
        final bool isAudioOnly = acceptTypes.every((type) =>
            type.startsWith('audio/') ||
            [
              'mp3',
              'wav',
              'ogg',
              'flac',
              'm4a',
              'aac',
              '.mp3',
              '.wav',
              '.ogg',
              '.flac',
              '.m4a',
              '.aac'
            ].contains(type.toLowerCase()));

        if (isImageOnly) {
          pickingType = FileType.image;
        } else if (isVideoOnly) {
          pickingType = FileType.video;
        } else if (isAudioOnly) {
          pickingType = FileType.audio;
        } else {
          // 提取所有允许的扩展名
          final List<String> extensions = [];
          for (final type in acceptTypes) {
            if (type.startsWith('.')) {
              extensions.add(type.substring(1));
            } else if (!type.contains('/')) {
              extensions.add(type);
            }
          }

          if (extensions.isNotEmpty) {
            pickingType = FileType.custom;
            allowedExtensions = extensions;
          }
        }
      }

      // 根据是否多选，调用相应的 API
      if (allowMultiple) {
        final List<PlatformFile> result = await FilePicker.pickFiles(
          type: pickingType,
          allowedExtensions: allowedExtensions,
        );
        if (result.isNotEmpty) {
          pickedFiles = result;
        }
      } else {
        final PlatformFile? file = await FilePicker.pickFile(
          type: pickingType,
          allowedExtensions: allowedExtensions,
        );
        if (file != null) {
          pickedFiles = [file];
        }
      }

      // 返回选中的文件路径,转换为 file:// URI 格式
      if (pickedFiles.isNotEmpty) {
        final List<String> filePaths =
            pickedFiles.where((file) => file.path != null).map((file) {
          final path = file.path!;
          if (path.startsWith('file://')) {
            return path;
          }
          final normalizedPath = path.replaceAll('\\', '/');
          return 'file://$normalizedPath';
        }).toList();

        debugPrint('Selected files: $filePaths');
        return filePaths;
      }

      return [];
    } catch (e) {
      debugPrint('File selection error: $e');
      return [];
    }
  }

  void _injectClipboardScript(WebViewController controller) {
    const String jsCode = '''
      const originalReadText = navigator.clipboard.readText;
      navigator.clipboard.readText = function () {
        console.log('Intercepted clipboard read');
        return new Promise((resolve) => {
          Android.postMessage('getClipboardData');
          setTimeout(() => {
            originalReadText.call(navigator.clipboard).then(text => {
              resolve(text);
            }).catch(() => resolve(''));
          }, 100);
        });
      };
    ''';
    controller.runJavaScript(jsCode);
  }

  void _disableZoom(WebViewController controller) {
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

  Future<void> _getClipboardData(WebViewController controller) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text ?? '';
    controller.runJavaScript('window.clipboardText = ${jsonEncode(text)};');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_maiBotInitialized) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                '正在加载控制面板...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Obx(() {
      final bool napCatEnabled =
          homeController.napcatController.napCatWebUiEnabledRx.value;
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

        // 2. NapCat 配置页面（仅在启用时添加）
        if (napCatEnabled)
          Visibility(
            key: const ValueKey('napcat_webview_visibility'),
            visible: _currentIndex == 1,
            maintainState: true,
            child: WebViewWidget(
                key: const ValueKey('napcat_webview'),
                controller: _napCatController),
          ),

        // 3. 自定义 WebView 页面
        ...List.generate(customWebViews.length, (index) {
          final webview = customWebViews[index];
          final url = webview['url'] ?? '';
          final int pageIndex = index + (napCatEnabled ? 2 : 1);
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

      final theme = Theme.of(context);
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

              // 1. 如果当前不是 MaiBot 主控制台标签页，按返回键优先返回主标签页
              if (_currentIndex != 0) {
                setState(() {
                  _currentIndex = 0;
                });
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

              // 执行安全退出
              SystemNavigator.pop();
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
                    napCatController: _napCatController,
                    onNavigate: (index) {
                      setState(() {
                        _currentIndex = index;
                      });
                    },
                  ),
                ],
              ),
            ),
            bottomNavigationBar: WebViewBottomNavBar(
              currentIndex: validCurrentIndex,
              onTap: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
            ),
          ),
        ),
      );
    });
  }
}
