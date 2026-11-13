import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:settings/settings.dart';

/// 预设主题种子色彩定义 (包含 Material You 动态色彩项)
class AppThemeColor {
  final String name;
  final Color? color;
  final bool isDynamic;

  const AppThemeColor(this.name, this.color, {this.isDynamic = false});
}

class ThemeController extends GetxController {
  static const List<AppThemeColor> presetColors = [
    AppThemeColor('系统动态 (Monet)', null, isDynamic: true),
    AppThemeColor('麦麦橙 (Mai Orange)', Color(0xFFFF8C00)),
    AppThemeColor('落日红 (Sunset)', Color(0xFFFF5722)),
    AppThemeColor('暖阳金 (Amber)', Color(0xFFFFB300)),
    AppThemeColor('经典蓝 (Classic)', Color(0xFF1976D2)),
    AppThemeColor('深靛蓝 (Indigo)', Color(0xFF3F51B5)),
    AppThemeColor('松石青 (Teal)', Color(0xFF00897B)),
    AppThemeColor('麦苗绿 (Mint)', Color(0xFF00A86B)),
    AppThemeColor('极客绿 (Forest)', Color(0xFF2E7D32)),
    AppThemeColor('樱花粉 (Pink)', Color(0xFFE91E63)),
    AppThemeColor('优雅紫 (Purple)', Color(0xFF7B1FA2)),
    AppThemeColor('岩石灰 (Slate)', Color(0xFF455A64)),
  ];

  final Setting _colorIndexSetting = 'theme_seed_color_index'.setting;
  final Setting _themeModeSetting = 'theme_mode_preference'.setting;
  final Setting _amoledSetting = 'theme_amoled_dark'.setting;

  final RxInt selectedColorIndex = 0.obs;
  final Rx<ThemeMode> currentThemeMode = ThemeMode.system.obs;
  final RxBool isAmoledDark = false.obs;

  // 存储系统 Android 12+ 提供的动态 Monet 配色
  ColorScheme? _systemLightScheme;
  ColorScheme? _systemDarkScheme;

  @override
  void onInit() {
    super.onInit();
    _loadThemeSettings();
  }

  void updateSystemDynamicSchemes(ColorScheme? light, ColorScheme? dark) {
    _systemLightScheme = light;
    _systemDarkScheme = dark;
  }

  void _loadThemeSettings() {
    final colorIdx = _colorIndexSetting.get();
    selectedColorIndex.value =
        (colorIdx is int && colorIdx >= 0 && colorIdx < presetColors.length)
            ? colorIdx
            : 0; // 默认使用系统动态 Monet

    final modeVal = _themeModeSetting.get();
    if (modeVal == 'light') {
      currentThemeMode.value = ThemeMode.light;
    } else if (modeVal == 'dark') {
      currentThemeMode.value = ThemeMode.dark;
    } else {
      currentThemeMode.value = ThemeMode.system;
    }

    isAmoledDark.value = _amoledSetting.get() ?? false;
  }

  bool get isDynamicSelected => presetColors[selectedColorIndex.value].isDynamic;

  Color get currentSeedColor {
    return presetColors[selectedColorIndex.value].color ?? const Color(0xFFFF8C00);
  }
  String get currentSeedName => presetColors[selectedColorIndex.value].name;

  void setColorIndex(int index) {
    if (index >= 0 && index < presetColors.length && selectedColorIndex.value != index) {
      selectedColorIndex.value = index;
      _colorIndexSetting.set(index);
    }
  }

  void setThemeMode(ThemeMode mode) {
    currentThemeMode.value = mode;
    if (mode == ThemeMode.light) {
      _themeModeSetting.set('light');
    } else if (mode == ThemeMode.dark) {
      _themeModeSetting.set('dark');
    } else {
      _themeModeSetting.set('system');
    }
    // MaterialApp listens reactively to currentThemeMode via Obx in main.dart.
  }

  void setAmoledDark(bool value) {
    if (isAmoledDark.value != value) {
      isAmoledDark.value = value;
      _amoledSetting.set(value);
    }
  }

  /// 构建正统 Material 3 浅色主题
  ThemeData getLightTheme({ColorScheme? dynamicLightScheme}) {
    final ColorScheme colorScheme =
        (isDynamicSelected && (dynamicLightScheme ?? _systemLightScheme) != null)
            ? (dynamicLightScheme ?? _systemLightScheme)!
            : ColorScheme.fromSeed(
                seedColor: currentSeedColor,
                brightness: Brightness.light,
              );

    return _buildThemeData(colorScheme: colorScheme, isDark: false);
  }

  /// 构建正统 Material 3 深色主题
  ThemeData getDarkTheme({ColorScheme? dynamicDarkScheme}) {
    ColorScheme colorScheme =
        (isDynamicSelected && (dynamicDarkScheme ?? _systemDarkScheme) != null)
            ? (dynamicDarkScheme ?? _systemDarkScheme)!
            : ColorScheme.fromSeed(
                seedColor: currentSeedColor,
                brightness: Brightness.dark,
              );

    final isAmoled = isAmoledDark.value;
    if (isAmoled) {
      colorScheme = colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0D0D0D),
        surfaceContainer: const Color(0xFF141414),
        surfaceContainerHigh: const Color(0xFF1C1C1C),
        surfaceContainerHighest: const Color(0xFF262626),
      );
    }

    return _buildThemeData(colorScheme: colorScheme, isDark: true, isAmoled: isAmoled);
  }

  ThemeData _buildThemeData({
    required ColorScheme colorScheme,
    required bool isDark,
    bool isAmoled = false,
  }) {
    final scaffoldBg = isAmoled ? Colors.black : colorScheme.surface;

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBg,
      canvasColor: scaffoldBg,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scaffoldBg,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: colorScheme.surfaceTint,
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.1,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isAmoled ? const Color(0xFF121212) : colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.45),
            width: 1,
          ),
        ),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 1,
        backgroundColor: isAmoled ? const Color(0xFF0A0A0A) : colorScheme.surfaceContainer,
        indicatorColor: colorScheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.onSecondaryContainer, size: 24);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            );
          }
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurfaceVariant,
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        elevation: 4,
        backgroundColor: isAmoled ? const Color(0xFF181818) : colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        titleTextStyle: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: colorScheme.onSurface,
        ),
        contentTextStyle: TextStyle(
          fontSize: 14,
          color: colorScheme.onSurfaceVariant,
          height: 1.45,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.3 : 0.4),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        textColor: colorScheme.onSurface,
        iconColor: colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isAmoled
            ? const Color(0xFF1E1E1E)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.error, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.error, width: 2),
        ),
        labelStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
        hintStyle: TextStyle(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          fontSize: 14,
        ),
        helperStyle: TextStyle(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontSize: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: BorderSide(color: colorScheme.outlineVariant),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isAmoled ? const Color(0xFF222222) : colorScheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: isAmoled ? Colors.white : colorScheme.onInverseSurface,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 4,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return colorScheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.surfaceContainerHighest;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return colorScheme.outline;
        }),
      ),
    );
  }
}
