import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:shizuku_api/shizuku_api.dart';

import '../../../core/config/app_config.dart';
import '../../controllers/home_controller.dart';

/// 权限与后台保活设置页面
class KeepAliveSettingsPage extends StatefulWidget {
  const KeepAliveSettingsPage({super.key});

  @override
  State<KeepAliveSettingsPage> createState() => _KeepAliveSettingsPageState();
}

class _KeepAliveSettingsPageState extends State<KeepAliveSettingsPage> with WidgetsBindingObserver {
  bool _isNotificationGranted = false;
  bool _isStorageGranted = false;
  bool _isBatteryOptimizationIgnored = false;
  bool _isAccessibilityEnabled = false;
  bool _isAutoStartEnabled = true;

  final Setting _enableWifiLock = 'enable_wifi_lock'.setting;

  bool _shizukuDozeWhitelist = false;
  bool _shizukuRunAnyInBackground = false;
  bool _shizukuPhantomProcessLimit = false;
  bool _shizukuAvailable = false;
  bool _shizukuPermissionGranted = false;
  final ShizukuApi _shizukuApi = ShizukuApi();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_enableWifiLock.get() == null) {
      _enableWifiLock.set(true);
    }
    // 避免在页面推入路由转场动画期间执行密集 IPC/Channel 阻塞导致卡顿
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _checkAllStatus();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _checkAllStatus();
    }
  }

  Future<void> _checkAllStatus() async {
    if (!Platform.isAndroid) return;
    await Future.wait([
      _checkSystemPermissionsStatus(),
      _checkBatteryOptimizationStatus(),
      _checkAccessibilityStatus(),
      _checkAutoStartStatus(),
      _checkShizukuStatus(),
    ]);
  }

  Future<void> _checkSystemPermissionsStatus() async {
    if (!Platform.isAndroid) return;
    try {
      final notifStatus = await Permission.notification.status;
      final manageStorageStatus = await Permission.manageExternalStorage.status;
      final storageStatus = await Permission.storage.status;

      if (mounted) {
        setState(() {
          _isNotificationGranted = notifStatus.isGranted;
          _isStorageGranted = manageStorageStatus.isGranted || storageStatus.isGranted;
        });
      }
    } catch (e) {
      Log.e('检查系统权限状态失败: $e', tag: 'KeepAliveSettingsPage');
    }
  }

  Future<void> _checkBatteryOptimizationStatus() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (mounted) {
        setState(() {
          _isBatteryOptimizationIgnored = status.isGranted;
        });
      }
    } catch (e) {
      Log.e('检查电池优化豁免状态失败: $e', tag: 'MaiBot');
    }
  }

  Future<void> _checkAccessibilityStatus() async {
    if (!Platform.isAndroid) return;
    try {
      const channel = MethodChannel(Config.methodChannel);
      final bool? enabled = await channel.invokeMethod<bool>('is_accessibility_enabled');
      if (mounted) {
        setState(() {
          _isAccessibilityEnabled = enabled ?? false;
        });
      }
    } catch (e) {
      Log.e('检查无障碍保活状态失败: $e', tag: 'KeepAliveSettingsPage');
    }
  }

  Future<void> _openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      const channel = MethodChannel(Config.methodChannel);
      await channel.invokeMethod('open_accessibility_settings');
    } catch (e) {
      Log.e('打开无障碍设置失败: $e', tag: 'KeepAliveSettingsPage');
      openAppSettings();
    }
  }
  Future<void> _checkAutoStartStatus() async {
    if (!Platform.isAndroid) return;
    try {
      const channel = MethodChannel(Config.methodChannel);
      final bool? enabled = await channel.invokeMethod<bool>('is_auto_start_enabled');
      if (mounted) {
        setState(() {
          _isAutoStartEnabled = enabled ?? true;
        });
      }
    } catch (e) {
      Log.e('检查自启动状态失败: $e', tag: 'KeepAliveSettingsPage');
    }
  }

  Future<void> _toggleAutoStart(bool value) async {
    if (!Platform.isAndroid) return;
    try {
      const channel = MethodChannel(Config.methodChannel);
      await channel.invokeMethod('set_auto_start_enabled', {'enabled': value});
      if (mounted) {
        setState(() {
          _isAutoStartEnabled = value;
        });
      }
    } catch (e) {
      Log.e('设置自启动状态失败: $e', tag: 'KeepAliveSettingsPage');
    }
  }
  Future<void> _checkShizukuStatus() async {
    if (!Platform.isAndroid) return;
    try {
      final isBinderRunning = await _shizukuApi.pingBinder() ?? false;
      if (!isBinderRunning) {
        if (mounted) {
          setState(() {
            _shizukuAvailable = false;
            _shizukuPermissionGranted = false;
          });
        }
        return;
      }

      final hasPermission = await _shizukuApi.checkPermission() ?? false;
      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _shizukuAvailable = true;
            _shizukuPermissionGranted = false;
          });
        }
        return;
      }

      // 并行执行 Shizuku Shell 命令，大幅缩短等待时间避免 UI 掉帧
      final results = await Future.wait([
        _shizukuApi.runCommand('dumpsys deviceidle whitelist'),
        _shizukuApi.runCommand('cmd appops get ${Config.packageName} RUN_ANY_IN_BACKGROUND'),
        _shizukuApi.runCommand('dumpsys activity settings'),
      ]);

      final dozeOut = results.first;
      final isDozeWhitelisted = dozeOut != null && dozeOut.contains(Config.packageName);

      final appopsOut = results[1];
      final isRunAnyAllowed = appopsOut != null && appopsOut.toLowerCase().contains('allow');

      final phantomOut = results[2];
      final isPhantomIncreased = phantomOut != null && phantomOut.contains('max_phantom_processes=64');

      if (mounted) {
        setState(() {
          _shizukuAvailable = true;
          _shizukuPermissionGranted = true;
          _shizukuDozeWhitelist = isDozeWhitelisted;
          _shizukuRunAnyInBackground = isRunAnyAllowed;
          _shizukuPhantomProcessLimit = isPhantomIncreased;
        });
      }
    } catch (e) {
      Log.e('检查 Shizuku 状态失败: $e', tag: 'KeepAliveSettingsPage');
    }
  }

  Future<bool> _ensureShizukuPermission() async {
    final isBinderRunning = await _shizukuApi.pingBinder() ?? false;
    if (!isBinderRunning) {
      Get.snackbar(
        '提示',
        'Shizuku 服务未运行',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
      setState(() {
        _shizukuAvailable = false;
        _shizukuPermissionGranted = false;
      });
      return false;
    }

    var hasPermission = await _shizukuApi.checkPermission() ?? false;
    if (!hasPermission) {
      final requested = await _shizukuApi.requestPermission() ?? false;
      if (!requested) {
        Get.snackbar(
          '提示',
          '未授予 Shizuku 权限',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        setState(() {
          _shizukuPermissionGranted = false;
        });
        return false;
      }
      hasPermission = await _shizukuApi.checkPermission() ?? false;
    }
    setState(() {
      _shizukuAvailable = true;
      _shizukuPermissionGranted = hasPermission;
    });
    return hasPermission;
  }

  Future<void> _toggleDozeWhitelist(bool value) async {
    if (!await _ensureShizukuPermission()) return;
    try {
      if (value) {
        await _shizukuApi.runCommand('dumpsys deviceidle whitelist +${Config.packageName}');
        Get.snackbar('设置成功', '已加入电池优化白名单', snackPosition: SnackPosition.BOTTOM);
      } else {
        await _shizukuApi.runCommand('dumpsys deviceidle whitelist -${Config.packageName}');
        Get.snackbar('设置成功', '已移出电池优化白名单', snackPosition: SnackPosition.BOTTOM);
      }
      await _checkShizukuStatus();
    } catch (e) {
      Get.snackbar('执行失败', e.toString(), snackPosition: SnackPosition.BOTTOM, backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _togglePhantomProcess(bool value) async {
    if (!await _ensureShizukuPermission()) return;
    try {
      if (value) {
        await _shizukuApi.runCommand('device_config set_sync_disabled_for_tests persistent');
        await _shizukuApi.runCommand('device_config put activity_manager max_phantom_processes 64');
        Get.snackbar('设置成功', '已调整幻影进程上限为 64', snackPosition: SnackPosition.BOTTOM);
      } else {
        await _shizukuApi.runCommand('device_config set_sync_disabled_for_tests none');
        await _shizukuApi.runCommand('device_config put activity_manager max_phantom_processes 32');
        Get.snackbar('设置成功', '已恢复默认幻影进程上限', snackPosition: SnackPosition.BOTTOM);
      }
      await _checkShizukuStatus();
    } catch (e) {
      Get.snackbar('执行失败', e.toString(), snackPosition: SnackPosition.BOTTOM, backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _toggleRunAnyInBackground(bool value) async {
    if (!await _ensureShizukuPermission()) return;
    try {
      if (value) {
        await _shizukuApi.runCommand('cmd appops set ${Config.packageName} RUN_ANY_IN_BACKGROUND allow');
        await _shizukuApi.runCommand('cmd appops set ${Config.packageName} RUN_IN_BACKGROUND allow');
        Get.snackbar('设置成功', '已开启后台无限制运行', snackPosition: SnackPosition.BOTTOM);
      } else {
        await _shizukuApi.runCommand('cmd appops set ${Config.packageName} RUN_ANY_IN_BACKGROUND default');
        await _shizukuApi.runCommand('cmd appops set ${Config.packageName} RUN_IN_BACKGROUND default');
        Get.snackbar('设置成功', '已恢复默认后台运行策略', snackPosition: SnackPosition.BOTTOM);
      }
      await _checkShizukuStatus();
    } catch (e) {
      Get.snackbar('执行失败', e.toString(), snackPosition: SnackPosition.BOTTOM, backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) {
      openAppSettings();
    }
    await _checkSystemPermissionsStatus();
  }

  Future<void> _requestStoragePermission() async {
    var status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
      if (status.isPermanentlyDenied) {
        openAppSettings();
      }
    }
    await _checkSystemPermissionsStatus();
  }

  Future<void> _requestBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        Get.snackbar('提示', '已获得电池优化豁免权限', snackPosition: SnackPosition.BOTTOM, duration: const Duration(seconds: 2));
        return;
      }
      final result = await Permission.ignoreBatteryOptimizations.request();
      await Future.delayed(const Duration(milliseconds: 500));
      await _checkBatteryOptimizationStatus();
      if (result.isGranted) {
        Get.snackbar('设置成功', '已获得电池优化豁免权限', snackPosition: SnackPosition.BOTTOM, duration: const Duration(seconds: 2));
      }
    } catch (e) {
      Log.e('请求电池优化豁免失败: $e', tag: 'MaiBot');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('权限与后台保活', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Get.back(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _buildSectionTitle('系统运行权限', Icons.verified_user_rounded),
          _buildCard([
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.notifications_none_rounded, size: 22),
              title: Text('通知权限', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                _isNotificationGranted ? '已授权，前台通知正常运行' : '未授权，前台服务可能被系统终止',
                style: TextStyle(
                  fontSize: 12,
                  color: _isNotificationGranted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
                ),
              ),
              trailing: _isNotificationGranted
                  ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 22)
                  : FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => unawaited(_requestNotificationPermission()),
                      child: const Text('授权', style: TextStyle(fontSize: 12)),
                    ),
              onTap: () => unawaited(_requestNotificationPermission()),
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.folder_open_rounded, size: 22),
              title: Text('存储权限', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                _isStorageGranted ? '已授权，支持环境解压及备份读写' : '未授权，无法管理容器及备份文件',
                style: TextStyle(
                  fontSize: 12,
                  color: _isStorageGranted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
                ),
              ),
              trailing: _isStorageGranted
                  ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 22)
                  : FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => unawaited(_requestStoragePermission()),
                      child: const Text('授权', style: TextStyle(fontSize: 12)),
                    ),
              onTap: () => unawaited(_requestStoragePermission()),
            ),
          ]),
          const SizedBox(height: 16),
          _buildSectionTitle('基础保活设置', Icons.battery_charging_full_rounded),
          _buildCard([
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.battery_saver_rounded, size: 22),
              title: Text('忽略电池优化', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                _isBatteryOptimizationIgnored ? '已授权，允许息屏时保持后台运行' : '未授权，系统可能在息屏时暂停网络和进程',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              trailing: _isBatteryOptimizationIgnored
                  ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 22)
                  : FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => unawaited(_requestBatteryOptimization()),
                      child: const Text('授权', style: TextStyle(fontSize: 12)),
                    ),
              onTap: () => unawaited(_requestBatteryOptimization()),
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.power_settings_new_rounded, size: 22),
              title: Text('系统省电策略', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '建议在系统设置中将应用省电策略设为无限制。此状态无法自动检测。',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              trailing: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => openAppSettings(),
                child: const Text('去设置', style: TextStyle(fontSize: 12)),
              ),
              onTap: () => openAppSettings(),
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.wifi_lock_rounded, size: 22),
              title: Text('保持 WLAN 连接', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '息屏时保持 Wi-Fi 连接稳定',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _enableWifiLock.get() ?? true,
              onChanged: (bool value) {
                _enableWifiLock.set(value);
                unawaited(() async {
                  try {
                    const channel = MethodChannel(Config.methodChannel);
                    await channel.invokeMethod('set_wifi_lock_enabled', {'enabled': value});
                  } catch (_) {}
                }());
                if (mounted) {
                  setState(() {});
                }
              },
            ),
          ]),
          const SizedBox(height: 16),
          _buildSectionTitle('任务管理与后台锁定', Icons.task_alt_rounded),
          _buildCard([
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.accessibility_new_rounded, size: 22),
              title: Text('无障碍保活服务', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                _isAccessibilityEnabled
                    ? '已开启，防止从最近任务列表清除时终止后台服务'
                    : '未开启，开启后可防止划掉任务卡片时误杀后台服务',
                style: TextStyle(
                  fontSize: 12,
                  color: _isAccessibilityEnabled ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
                ),
              ),
              trailing: _isAccessibilityEnabled
                  ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 22)
                  : FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => unawaited(_openAccessibilitySettings()),
                      child: const Text('去开启', style: TextStyle(fontSize: 12)),
                    ),
              onTap: () => unawaited(_openAccessibilitySettings()),
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.lock_outline_rounded, size: 22),
              title: Text('多任务卡片加锁', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '在多任务列表中长按或下拉卡片添加锁定，防止被一键清理。此状态无法自动检测。',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off_rounded, size: 22),
              title: Text('从最近任务列表中隐藏', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '开启后不在多任务列表中显示应用',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: Get.find<HomeController>().hideFromRecents.get() ?? false,
              onChanged: (bool value) {
                Get.find<HomeController>().setHideFromRecents(value);
                if (mounted) {
                  setState(() {});
                }
              },
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.rocket_launch_rounded, size: 22),
              title: Text('开机与无障碍自启动', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '开机或连接无障碍服务时，自动在后台拉起容器与服务',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _isAutoStartEnabled,
              onChanged: (val) => unawaited(_toggleAutoStart(val)),
            ),
          ]),
          const SizedBox(height: 16),
          _buildSectionTitle('Shizuku 高级配置', Icons.extension_rounded),
          _buildCard([
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: const Icon(Icons.link_rounded, size: 22),
              title: Text('Shizuku 服务状态', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                _getShizukuSubtitle(),
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              trailing: Icon(
                _getShizukuIcon(),
                color: _getShizukuIconColor(theme),
                size: 22,
              ),
              onTap: () {
                unawaited(() async {
                  await _ensureShizukuPermission();
                  await _checkShizukuStatus();
                }());
              },
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.flash_on_rounded, size: 22),
              title: Text('写入 Doze 白名单', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '通过 Shell 命令将应用添加至系统白名单',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _shizukuDozeWhitelist,
              onChanged: (bool value) => _toggleDozeWhitelist(value),
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.tune_rounded, size: 22),
              title: Text('后台无限制运行', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '配置 AppOps 允许后台持续运行',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _shizukuRunAnyInBackground,
              onChanged: (bool value) => _toggleRunAnyInBackground(value),
            ),
            const Divider(height: 1, indent: 56),
            SwitchListTile(
              secondary: const Icon(Icons.memory_rounded, size: 22),
              title: Text('提高幻影进程限制', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: theme.colorScheme.onSurface)),
              subtitle: Text(
                '将系统限制提高至 64，适用于 Android 12 及以上',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
              value: _shizukuPhantomProcessLimit,
              onChanged: (bool value) => _togglePhantomProcess(value),
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
  String _getShizukuSubtitle() {
    if (!_shizukuAvailable) return '未检测到运行中的 Shizuku 服务';
    return _shizukuPermissionGranted ? '已连接并获得授权' : '已检测到服务，点击授权';
  }

  IconData _getShizukuIcon() {
    if (!_shizukuAvailable) return Icons.cancel_rounded;
    return _shizukuPermissionGranted ? Icons.check_circle_rounded : Icons.info_rounded;
  }

  Color _getShizukuIconColor(ThemeData theme) {
    if (!_shizukuAvailable) {
      return theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    }
    return _shizukuPermissionGranted ? Colors.green : Colors.orange;
  }
}
