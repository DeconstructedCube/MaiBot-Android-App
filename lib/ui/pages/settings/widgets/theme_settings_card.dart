import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../controllers/theme_controller.dart';

/// 设置页：Material 3 主题色调、亮暗模式与 AMOLED 纯黑模式配置卡片
class ThemeSettingsCard extends StatelessWidget {
  final ThemeController controller;

  const ThemeSettingsCard({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: theme.cardTheme.color ?? colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.45),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.color_lens_rounded,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '主题色调',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Obx(
                  () => Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: controller.currentSeedColor
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      controller.currentSeedName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: controller.currentSeedColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Obx(() {
            final selectedIndex = controller.selectedColorIndex.value;
            final isDynamicSel = controller.isDynamicSelected;
            return SizedBox(
              height: 58,
              child: ShaderMask(
                shaderCallback: (Rect bounds) {
                  return const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.04, 0.96, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  itemCount: ThemeController.presetColors.length,
                  itemBuilder: (context, index) {
                    final item = ThemeController.presetColors[index];
                    final isSelected = selectedIndex == index;
                    final Color dynamicColor = isDynamicSel
                        ? colorScheme.primary
                        : const Color(0xFF6750A4);
                    final Color displayColor =
                        item.isDynamic ? dynamicColor : item.color!;

                    return GestureDetector(
                      onTap: () => controller.setColorIndex(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: displayColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? colorScheme.onSurface
                                : Colors.transparent,
                            width: 2.5,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: displayColor.withValues(alpha: 0.4),
                                    blurRadius: 8,
                                    spreadRadius: 0.5,
                                  )
                                ]
                              : null,
                        ),
                        child: () {
                          if (item.isDynamic) {
                            return Icon(
                              isSelected
                                  ? Icons.check_rounded
                                  : Icons.auto_awesome_rounded,
                              color: Colors.white,
                              size: 18,
                            );
                          } else if (isSelected) {
                            return const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            );
                          }
                          return null;
                        }(),
                      ),
                    );
                  },
                ),
              ),
            );
          }),
          const SizedBox(height: 6),
          const Divider(height: 1, indent: 56),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.brightness_medium_rounded,
                        color: Colors.amber,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      '显示模式',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Obx(() {
                  final currentMode = controller.currentThemeMode.value;
                  const options = [
                    (
                      mode: ThemeMode.system,
                      label: '跟随系统',
                      icon: Icons.auto_mode_rounded,
                    ),
                    (
                      mode: ThemeMode.light,
                      label: '浅色',
                      icon: Icons.light_mode_rounded,
                    ),
                    (
                      mode: ThemeMode.dark,
                      label: '深色',
                      icon: Icons.dark_mode_rounded,
                    ),
                  ];

                  return Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: options.map((opt) {
                        final selected = currentMode == opt.mode;
                        return Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => controller.setThemeMode(opt.mode),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: selected
                                    ? colorScheme.secondaryContainer
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    opt.icon,
                                    size: 16,
                                    color: selected
                                        ? colorScheme.onSecondaryContainer
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    opt.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: selected
                                          ? colorScheme.onSecondaryContainer
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  );
                }),
              ],
            ),
          ),
          Obx(() {
            final mode = controller.currentThemeMode.value;
            final isSystemDark = mode == ThemeMode.system && isDark;
            if (mode == ThemeMode.dark || isSystemDark) {
              return Column(
                children: [
                  const Divider(height: 1, indent: 56),
                  SwitchListTile(
                    secondary: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blueGrey.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.contrast_rounded,
                        color: Colors.blueGrey,
                        size: 22,
                      ),
                    ),
                    title: const Text(
                      'AMOLED 纯黑暗色',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    subtitle: Text(
                      '纯黑底色背景，降低 OLED 屏幕功耗',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    value: controller.isAmoledDark.value,
                    onChanged: (bool value) => controller.setAmoledDark(value),
                  ),
                ],
              );
            }
            return const SizedBox.shrink();
          }),
        ],
      ),
    );
  }
}
