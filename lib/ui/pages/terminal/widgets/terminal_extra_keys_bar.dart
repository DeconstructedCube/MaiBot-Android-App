import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../../controllers/terminal_tab_manager.dart';

/// Termux 同款终端快捷按键底边栏（支持状态键 CTRL / ALT / SHIFT 及常用特殊键）
class TerminalExtraKeysBar extends StatelessWidget {
  final TerminalTabManager manager;

  const TerminalExtraKeysBar({
    super.key,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final barBg = isDark
        ? const Color(0xFF1E1E24)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.85);

    return Container(
      width: double.infinity,
      height: 42,
      decoration: BoxDecoration(
        color: barBg,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
            width: 0.8,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Obx(() {
          final isCtrl = manager.isCtrlActive.value;
          final isAlt = manager.isAltActive.value;
          final isShift = manager.isShiftActive.value;

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ESC
              _buildKey(
                context,
                label: 'ESC',
                onPressed: () => _send('\x1b'),
              ),
              // TAB
              _buildKey(
                context,
                label: 'TAB',
                onPressed: () => _send('\t'),
              ),
              // CTRL (有状态)
              _buildStateKey(
                context,
                label: 'CTRL',
                isActive: isCtrl,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  manager.isCtrlActive.value = !isCtrl;
                },
              ),
              // ALT (有状态)
              _buildStateKey(
                context,
                label: 'ALT',
                isActive: isAlt,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  manager.isAltActive.value = !isAlt;
                },
              ),
              // -
              _buildKey(
                context,
                label: '-',
                onPressed: () => _send('-'),
              ),
              // 方向键 ◀
              _buildKey(
                context,
                icon: Icons.arrow_back_rounded,
                onPressed: () => _send('\x1b[D'),
              ),
              // 方向键 ▲
              _buildKey(
                context,
                icon: Icons.arrow_upward_rounded,
                onPressed: () => _send('\x1b[A'),
              ),
              // 方向键 ▼
              _buildKey(
                context,
                icon: Icons.arrow_downward_rounded,
                onPressed: () => _send('\x1b[B'),
              ),
              // 方向键 ▶
              _buildKey(
                context,
                icon: Icons.arrow_forward_rounded,
                onPressed: () => _send('\x1b[C'),
              ),
              // ENTER
              _buildKey(
                context,
                label: 'ENTER',
                icon: Icons.keyboard_return_rounded,
                onPressed: () => _send('\r'),
              ),
              // INS
              _buildKey(
                context,
                label: 'INS',
                onPressed: () => _send('\x1b[2~'),
              ),
              // END
              _buildKey(
                context,
                label: 'END',
                onPressed: () => _send('\x1b[4~'),
              ),
              // SHIFT (有状态)
              _buildStateKey(
                context,
                label: 'SHIFT',
                isActive: isShift,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  manager.isShiftActive.value = !isShift;
                },
              ),
              // :
              _buildKey(
                context,
                label: ':',
                onPressed: () => _send(':'),
              ),
            ],
          );
        }),
      ),
    );
  }

  void _send(String data) {
    HapticFeedback.lightImpact();
    manager.dispatchKeyInput(data);
  }

  Widget _buildKey(
    BuildContext context, {
    String? label,
    IconData? icon,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final btnBg = isDark
        ? const Color(0xFF2C2C34)
        : colorScheme.surfaceContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: btnBg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null)
                  Icon(icon, size: 15, color: colorScheme.onSurface),
                if (icon != null && label != null)
                  const SizedBox(width: 3),
                if (label != null)
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStateKey(
    BuildContext context, {
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final activeBg = colorScheme.primary;
    final activeFg = colorScheme.onPrimary;
    final inactiveBg = isDark
        ? const Color(0xFF2C2C34)
        : colorScheme.surfaceContainer;
    final inactiveFg = colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: isActive ? activeBg : inactiveBg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 46, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive
                    ? colorScheme.primary
                    : colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? activeFg : Colors.grey,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: isActive ? activeFg : inactiveFg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
