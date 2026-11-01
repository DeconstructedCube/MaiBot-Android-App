import 'package:get/get.dart';
import 'package:settings/settings.dart';
import '../pages/privacy_agree_page.dart';
import '../pages/terminal/terminal_page.dart';
import '../pages/webview/webview_page.dart';
import '../controllers/home_controller.dart';

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
          Get.find<HomeController>().startBootstrapSequence();
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
