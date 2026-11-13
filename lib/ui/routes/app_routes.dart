import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:settings/settings.dart';
import '../pages/privacy_agree_page.dart';
import '../pages/terminal/terminal_page.dart';
import '../pages/webview/webview_page.dart';
import '../controllers/home_controller.dart';

class AppRoutes {
  static const String privacy = '/privacy';
  static const String terminal = '/terminal';
  static const String webview = '/webview';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case privacy:
        return GetPageRoute(
          settings: settings,
          page: () => PrivacyAgreePage(
            onAgreeTap: () {
              'privacy'.setting.set(true);
              Get.offAllNamed(terminal);
              Get.find<HomeController>().startBootstrapSequence();
            },
          ),
          transition: Transition.fadeIn,
        );
      case webview:
        return GetPageRoute(
          settings: settings,
          page: () => const WebViewPage(),
          transition: Transition.fadeIn,
        );
      case terminal:
      default:
        return GetPageRoute(
          settings: settings,
          page: () => const TerminalPage(),
        );
    }
  }
}
