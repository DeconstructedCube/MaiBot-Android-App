import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';

class PermissionRequestPage extends StatefulWidget {
  final VoidCallback onPermissionsGranted;

  const PermissionRequestPage({
    super.key,
    required this.onPermissionsGranted,
  });

  @override
  State<PermissionRequestPage> createState() => _PermissionRequestPageState();
}

class _PermissionRequestPageState extends State<PermissionRequestPage> with WidgetsBindingObserver {
  bool _notificationGranted = false;
  bool _storageGranted = false;
  bool _batteryOptimizationIgnored = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAllPermissions();
    }
  }

  Future<void> _checkAllPermissions() async {
    if (!Platform.isAndroid) {
      widget.onPermissionsGranted();
      return;
    }

    try {
      final notifStatus = await Permission.notification.status;
      final manageStorageStatus = await Permission.manageExternalStorage.status;
      final storageStatus = await Permission.storage.status;
      final batteryStatus = await Permission.ignoreBatteryOptimizations.status;

      if (mounted) {
        setState(() {
          _notificationGranted = notifStatus.isGranted;
          _storageGranted = manageStorageStatus.isGranted || storageStatus.isGranted;
          _batteryOptimizationIgnored = batteryStatus.isGranted;
          _isChecking = false;
        });
      }
    } catch (e) {
      Log.e('检查权限状态失败: $e', tag: 'PermissionRequestPage');
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.request();
    if (status.isGranted) {
      setState(() => _notificationGranted = true);
    } else if (status.isPermanentlyDenied) {
      _showOpenSettingsDialog('通知权限', '请在系统设置中开启通知权限，以便前台服务正常运行。');
    }
    _checkAllPermissions();
  }

  Future<void> _requestStoragePermission() async {
    var status = await Permission.manageExternalStorage.request();
    if (status.isGranted) {
      setState(() => _storageGranted = true);
      _checkAllPermissions();
      return;
    }

    var normalStorage = await Permission.storage.request();
    if (normalStorage.isGranted) {
      setState(() => _storageGranted = true);
    } else if (normalStorage.isPermanentlyDenied || status.isPermanentlyDenied) {
      _showOpenSettingsDialog('存储权限', '请在系统设置中授予存储权限，用于管理应用运行环境和数据备份。');
    }
    _checkAllPermissions();
  }

  Future<void> _requestBatteryOptimization() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (status.isGranted) {
      setState(() => _batteryOptimizationIgnored = true);
    }
    _checkAllPermissions();
  }

  void _showOpenSettingsDialog(String title, String content) {
    Get.dialog(
      AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Get.back();
              openAppSettings();
            },
            child: const Text('前往设置'),
          ),
        ],
      ),
    );
  }

  bool get _isAllRequiredGranted => _notificationGranted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: const Text('权限申请', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          centerTitle: true,
          automaticallyImplyLeading: false,
        ),
        body: _isChecking
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colorScheme.primary.withValues(alpha: 0.2),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.shield_outlined, color: colorScheme.primary, size: 24),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '应用需要以下权限以确保后台服务稳定运行和数据存储。请先授予必要权限。',
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildSectionHeader(context, '必要权限'),
                        const SizedBox(height: 8),
                        _buildPermissionItem(
                          context: context,
                          icon: Icons.notifications_none_rounded,
                          title: '通知权限',
                          description: '用于在状态栏显示常驻前台服务，防止后台进程被系统终止。',
                          isGranted: _notificationGranted,
                          isRequired: true,
                          onRequest: () => unawaited(_requestNotificationPermission()),
                        ),
                        const SizedBox(height: 10),
                        _buildPermissionItem(
                          context: context,
                          icon: Icons.folder_open_rounded,
                          title: '存储权限',
                          description: '用于读写外部存储中的备份文件。',
                          isGranted: _storageGranted,
                          isRequired: false,
                          onRequest: () => unawaited(_requestStoragePermission()),
                        ),
                        const SizedBox(height: 20),
                        _buildSectionHeader(context, '可选保活设置'),
                        const SizedBox(height: 8),
                        _buildPermissionItem(
                          context: context,
                          icon: Icons.battery_charging_full_rounded,
                          title: '忽略电池优化',
                          description: '允许应用在系统休眠时保持后台网络和进程运行。',
                          isGranted: _batteryOptimizationIgnored,
                          isRequired: false,
                          onRequest: () => unawaited(_requestBatteryOptimization()),
                        ),
                        const SizedBox(height: 10),
                        _buildNoticeItem(
                          context: context,
                          icon: Icons.power_settings_new_rounded,
                          title: '系统省电策略',
                          description: '建议在系统设置中将应用的省电策略设为无限制。此状态无法自动检测。',
                          actionText: '去设置',
                          onAction: () => openAppSettings(),
                        ),
                        const SizedBox(height: 10),
                        _buildNoticeItem(
                          context: context,
                          icon: Icons.lock_outline_rounded,
                          title: '后台任务锁定',
                          description: '在多任务界面长按或下拉应用卡片添加锁定，防止被一键清理。此状态无法自动检测。',
                          actionText: null,
                          onAction: null,
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      border: Border(
                        top: BorderSide(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _isAllRequiredGranted ? widget.onPermissionsGranted : null,
                        child: Text(
                          _isAllRequiredGranted ? '完成并继续' : '请先授予必要权限',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildPermissionItem({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required bool isRequired,
    required VoidCallback onRequest,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGranted
              ? Colors.green.withValues(alpha: 0.3)
              : colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    if (isRequired) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '必选',
                          style: TextStyle(
                            fontSize: 10,
                            color: colorScheme.onErrorContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isGranted)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, color: Colors.green, size: 18),
                    SizedBox(width: 4),
                    Text('已授权', style: TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w500)),
                  ],
                )
              else
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: onRequest,
                  child: const Text('授权', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeItem({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required String? actionText,
    required VoidCallback? onAction,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              if (actionText != null && onAction != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: onAction,
                  child: Text(actionText, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
