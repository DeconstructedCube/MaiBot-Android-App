import 'package:material_ui/material_ui.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'dart:async';

import 'core/config/app_config.dart';
import 'core/services/env_bootstrapper.dart';
import 'core/services/backend_process_manager.dart';
import 'ui/routes/app_routes.dart';
import 'ui/controllers/home_controller.dart';
import 'ui/controllers/theme_controller.dart';

// Notice: behavior will submit Device

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启用系统沉浸式全面屏边缘延展 (Edge-to-Edge)
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  RuntimeEnvir.initEnvirWithPackageName(Config.packageName);
  await initSettingStore(RuntimeEnvir.configPath);

  // 初始化运行环境（释放原生二进制链接，防止由于拉起服务过快导致无 proot 可执行）
  await EnvBootstrapper.initEnvir();

  // 初始化后台进程管理
  BackendProcessManager.init();

  // 初始化核心全局控制器
  Get.put(ThemeController(), permanent: true);
  Get.put(HomeController(), permanent: true);

  runApp(const MaiBot());
}

class MaiBot extends StatelessWidget {
  const MaiBot({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeController themeController = Get.find<ThemeController>();

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        themeController.updateSystemDynamicSchemes(lightDynamic, darkDynamic);

        return Obx(() {
          return MaterialApp(
            title: 'MaiBot Android',
            navigatorKey: Get.key,
            navigatorObservers: [GetObserver()],
            theme: themeController.getLightTheme(dynamicLightScheme: lightDynamic),
            darkTheme: themeController.getDarkTheme(dynamicDarkScheme: darkDynamic),
            themeMode: themeController.currentThemeMode.value,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [
              Locale('zh', 'CN'),
              Locale('en', 'US'),
            ],
            initialRoute: 'privacy'.setting.get() == true
                ? AppRoutes.terminal
                : AppRoutes.privacy,
            onGenerateRoute: AppRoutes.onGenerateRoute,
            builder: (context, child) {
              return ViewMetric(
                uiWidth: 375,
                screenWidth: MediaQuery.of(context).size.width,
                child: child ?? const SizedBox.shrink(),
              );
            },
          );
        });
      },
    );
  }
}
