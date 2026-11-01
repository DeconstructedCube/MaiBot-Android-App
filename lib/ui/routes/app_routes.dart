import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import '../pages/terminal/terminal_page.dart';
import '../pages/webview/webview_page.dart';

class AppRoutes {
  static const String privacy = '/privacy';
  static const String terminal = '/terminal';
  static const String webview = '/webview';

  static final routes = [
    GetPage(
      name: privacy,
      page: () => PrivacyAgreePage(
        onAgreeTap: () {
          'privacy'.setting.set(true);
          Get.offAllNamed(terminal);
        },
      ),
      transition: Transition.fadeIn,
    ),
    GetPage(
      name: terminal,
      page: () => const TerminalPage(),
    ),
    GetPage(
      name: webview,
      page: () => const WebViewPage(),
      transition: Transition.fadeIn,
    ),
  ];
}
