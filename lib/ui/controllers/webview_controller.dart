import 'package:get/get.dart';
import '../../core/storage/app_settings.dart';

import '../routes/app_routes.dart';

class WebviewController extends GetxController {
  final RxList<Map<String, String>> customWebViews =
      <Map<String, String>>[].obs;
  bool webviewHasOpen = false;

  @override
  void onInit() {
    super.onInit();
    _loadCustomWebViews();
  }

  // 加载自定义 WebView 列表
  void _loadCustomWebViews() {
    final stored = box?.get('custom_webviews', defaultValue: const []);
    if (stored is List) {
      customWebViews.value = stored.map((e) {
        if (e is Map) {
          return {
            'title': e['title']?.toString() ?? '',
            'url': e['url']?.toString() ?? '',
          };
        }
        return <String, String>{};
      }).toList();
    }
  }

  // 保存自定义 WebView 列表
  void _saveCustomWebViews() {
    box?.put('custom_webviews', customWebViews.toList());
  }

  // 添加自定义 WebView
  void addCustomWebView(String title, String url) {
    customWebViews.add({'title': title, 'url': url});
    _saveCustomWebViews();
  }

  // 删除自定义 WebView
  void removeCustomWebView(int index) {
    if (index >= 0 && index < customWebViews.length) {
      customWebViews.removeAt(index);
      _saveCustomWebViews();
    }
  }

  // 更新自定义 WebView
  void updateCustomWebView(int index, String title, String url) {
    if (index >= 0 && index < customWebViews.length) {
      customWebViews[index] = {'title': title, 'url': url};
      _saveCustomWebViews();
    }
  }

  void navigateToWebview() {
    if (!webviewHasOpen) {
      Future.microtask(() {
        Get.offAllNamed(AppRoutes.webview);
        webviewHasOpen = true;
      });
    }
  }
}
