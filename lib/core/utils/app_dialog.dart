import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Displays a dialog using `package:material_ui`'s [showDialog] so it resolves
/// `material_ui`'s [MaterialLocalizations] and [Theme] instead of GetX's
/// legacy `flutter/material.dart` dialog helper.
Future<T?> showAppDialog<T>({
  required WidgetBuilder builder,
  BuildContext? context,
  bool barrierDismissible = true,
}) {
  final BuildContext? targetContext = (context != null && context.mounted)
      ? context
      : (Get.overlayContext ?? Get.key.currentState?.overlay?.context);
  if (targetContext == null || !targetContext.mounted) {
    return Future<T?>.value(null);
  }
  return showDialog<T>(
    context: targetContext,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
}
