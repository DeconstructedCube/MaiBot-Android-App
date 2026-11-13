import 'package:material_ui/material_ui.dart';
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: barBg,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
            width: 0.8,
          ),
        ),
      ),
      child: Obx(() {
        final isCtrl = manager.isCtrlActive.value;
        final isAlt = manager.isAltActive.value;
        final isShift = manager.isShiftActive.value;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _buildExpandedKey(
                  context,
                  label: 'ESC',
                  onPressed: () => _send('\x1b'),
                ),
                _buildExpandedKey(
                  context,
                  label: 'TAB',
                  onPressed: () => _send('\t'),
                ),
                _buildExpandedKey(
                  context,
                  label: '-',
                  onPressed: () => _send('-'),
                ),
                _buildExpandedKey(
                  context,
                  label: ':',
                  onPressed: () => _send(':'),
                ),
                _buildExpandedKey(
                  context,
                  label: 'INS',
                  onPressed: () => _send('\x1b[2~'),
                ),
                _buildExpandedKey(
                  context,
                  icon: Icons.arrow_upward_rounded,
                  onPressed: () => _send('\x1b[A'),
                ),
                _buildExpandedKey(
                  context,
                  label: 'END',
                  onPressed: () => _send('\x1b[4~'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _buildExpandedStateKey(
                  context,
                  label: 'CTRL',
                  isActive: isCtrl,
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    manager.isCtrlActive.value = !isCtrl;
                  },
                ),
                _buildExpandedStateKey(
                  context,
                  label: 'ALT',
                  isActive: isAlt,
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    manager.isAltActive.value = !isAlt;
                  },
                ),
                _buildExpandedStateKey(
                  context,
                  label: 'SHIFT',
                  isActive: isShift,
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    manager.isShiftActive.value = !isShift;
                  },
                ),
                _buildExpandedKey(
                  context,
                  icon: Icons.arrow_back_rounded,
                  onPressed: () => _send('\x1b[D'),
                ),
                _buildExpandedKey(
                  context,
                  icon: Icons.arrow_downward_rounded,
                  onPressed: () => _send('\x1b[B'),
                ),
                _buildExpandedKey(
                  context,
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () => _send('\x1b[C'),
                ),
                _buildExpandedKey(
                  context,
                  label: 'RET',
                  icon: Icons.keyboard_return_rounded,
                  onPressed: () => _send('\r'),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _buildExpandedKey(
    BuildContext context, {
    String? label,
    IconData? icon,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: _buildKey(
        context,
        label: label,
        icon: icon,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildExpandedStateKey(
    BuildContext context, {
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: _buildStateKey(
        context,
        label: label,
        isActive: isActive,
        onPressed: onPressed,
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
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: btnBg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null)
                    Icon(icon, size: 14, color: colorScheme.onSurface),
                  if (icon != null && label != null)
                    const SizedBox(width: 2),
                  if (label != null)
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                ],
              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: isActive ? activeBg : inactiveBg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 4),
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
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 4.5,
                    height: 4.5,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? activeFg : Colors.grey,
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: isActive ? activeFg : inactiveFg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
