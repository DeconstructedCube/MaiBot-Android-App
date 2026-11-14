import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:global_repository/global_repository.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/config/app_config.dart';
import '../../../core/services/backend_process_manager.dart';
import '../../../core/services/backup_service.dart';
import '../../../core/services/host_rescue_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/version_utils.dart';
import 'dialogs/update_dialogs.dart';
import 'dialogs/git_clone_dialog.dart';
import 'dialogs/git_dialogs.dart';
import 'keep_alive_settings_page.dart';
import 'maintenance_actions.dart';
import 'widgets/resource_monitor_card.dart';
import 'widgets/settings_header_card.dart';
import 'widgets/theme_settings_card.dart';
import 'widgets/token_and_webview_card.dart';

class SettingsPage extends StatefulWidget {
  final WebViewController maiBotController;
  final Function(int) onNavigate;
  final bool isVisible;

  const SettingsPage({
    super.key,
    required this.maiBotController,
    required this.onNavigate,
    this.isVisible = true,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static String _cachedAppVersion = '';
  static String? _cachedPrivacyContent;
  String _appVersion = _cachedAppVersion;
  final HomeController homeController = Get.find<HomeController>();
  final UpdateChecker _updateChecker = UpdateChecker();

  @override
  void initState() {
    super.initState();
    if (_appVersion.isEmpty) {
      _loadAppVersion();
    }
    unawaited(homeController.reloadTokensFromDisk());
  }

  Future<void> _loadAppVersion() async {
    final version = await getAppVersion();
    _cachedAppVersion = version;
    if (mounted) {
      setState(() {
        _appVersion = version;
      });
    }
  }

  Future<void> _openFileManager() async {
    try {
      final contentUri = Uri.parse(
        'content://${Config.packageName}.documents/root/ubuntu_root',
      );

      if (await canLaunchUrl(contentUri)) {
        await launchUrl(
          contentUri,
          mode: LaunchMode.externalApplication,
        );

        Get.snackbar(
          '已打开',
          '已在文件管理器中打开 Ubuntu 文件系统',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.dialog(
          AlertDialog(
            title: const Text('打开文件系统'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '系统文件管理器的侧栏名称为:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text(
                  'MaiBot Ubuntu',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '可手动打开系统文件应用访问，或在第三方文件管理器中添加路径:',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  scripts.ubuntuPath,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  unawaited(() async {
                    await Clipboard.setData(
                        ClipboardData(text: scripts.ubuntuPath));
                    Get.back();
                    Get.snackbar(
                      '已复制',
                      '路径已复制到剪贴板',
                      snackPosition: SnackPosition.BOTTOM,
                      duration: const Duration(seconds: 2),
                    );
                  }());
                },
                child: const Text('复制路径'),
              ),
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Log.e('打开文件管理器失败: $e', tag: 'MaiBot');
      Get.snackbar(
        '打开失败',
        '无法打开文件管理器: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
    }
  }

  void _showWebUiRescueDialog() {
    Get.dialog(
      AlertDialog(
        icon: const Icon(Icons.medical_services_rounded, size: 28, color: Colors.deepPurple),
        title: const Text('WebUI 离线急救'),
        content: const Text(
          '当忘记固定密码、修改端口/反爬配置导致 WebUI 无法打开时，可直接从容器文件层恢复访问：',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () {
              Get.back();
              unawaited(() async {
                await HostRescueService.repairHostWebUiConfig();
                homeController.activeWebPort.value = Ports.maibotWeb;
                Get.snackbar(
                  '已修复宿主配置',
                  '已恢复默认 127.0.0.1:8001 并重启 MaiBot',
                  snackPosition: SnackPosition.BOTTOM,
                );
              }());
            },
            child: const Text('重置端口/反爬'),
          ),
          FilledButton(
            onPressed: () {
              Get.back();
              unawaited(() async {
                final newToken = await HostRescueService.resetWebUiCredentials();
                homeController.maiBotWebUiToken.value = newToken;
                homeController.maiBotTokenSource.value = 'temporary';
                Get.snackbar(
                  '密码已重置',
                  '已生成新临时密码并清空旧会话，服务重启后生效',
                  snackPosition: SnackPosition.BOTTOM,
                );
              }());
            },
            child: const Text('重置登录密码'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final ThemeController themeController = Get.find<ThemeController>();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: SettingsHeaderCard(
                appVersion: _appVersion,
                primaryColor: primaryColor,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                ResourceMonitorCard(isVisible: widget.isVisible),
                const SizedBox(height: 16),
                _buildSectionHeader('界面与主题', Icons.palette_rounded),
                ThemeSettingsCard(controller: themeController),
                const SizedBox(height: 16),
                _buildSectionHeader('常用操作', Icons.tune_rounded),
                _buildCard([
                  _buildSettingTile(
                    icon: Icons.home_rounded,
                    iconColor: Colors.blue,
                    title: '回到 MaiBot 主页',
                    subtitle: '刷新页面',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      widget.maiBotController.loadRequest(
                        Uri.parse('http://127.0.0.1:${homeController.activeWebPort.value}'),
                      );
                      widget.onNavigate(0);
                      Get.snackbar(
                        '已跳转',
                        'MaiBot 页面已刷新',
                        snackPosition: SnackPosition.BOTTOM,
                        duration: const Duration(seconds: 2),
                      );
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.restart_alt_rounded,
                    iconColor: Colors.green.shade700,
                    title: '重启 MaiBot',
                    subtitle: '重启后台 MaiBot 服务进程',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      unawaited(() async {
                        await BackendProcessManager.restartService(
                          target: ServiceTarget.maibot,
                          cols: homeController.terminal.viewWidth > 0
                              ? homeController.terminal.viewWidth
                              : 60,
                          rows: homeController.terminal.viewHeight > 0
                              ? homeController.terminal.viewHeight
                              : 28,
                        );
                        Get.snackbar(
                          '已发送重启指令',
                          '正在重启 MaiBot 后台服务',
                          snackPosition: SnackPosition.BOTTOM,
                          duration: const Duration(seconds: 2),
                        );
                      }());
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.folder_open_rounded,
                    iconColor: Colors.amber.shade800,
                    title: '查看数据目录与文件',
                    subtitle: '浏览 Ubuntu 系统目录',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => _openFileManager(),
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSectionHeader('控制面板与令牌', Icons.dashboard_rounded),
                TokenAndWebviewCard(homeController: homeController),
                const SizedBox(height: 16),
                _buildSectionHeader('系统与网络', Icons.settings_suggest_rounded),
                _buildCard([
                  _buildSettingTile(
                    icon: Icons.shield_outlined,
                    iconColor: Colors.blue,
                    title: '权限与后台保活',
                    subtitle: '系统权限与前台服务保活',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      Get.to(() => const KeepAliveSettingsPage());
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.cloud_sync_rounded,
                    iconColor: Colors.teal,
                    title: '更新 MaiBot',
                    subtitle: '拉取最新代码并更新依赖',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => showUpdateMaiBotDialog(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.alt_route_rounded,
                    iconColor: Colors.teal.shade700,
                    title: '切换 MaiBot 分支',
                    subtitle: '切换代码分支',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => showSwitchBranchDialog(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.sell_rounded,
                    iconColor: Colors.purple,
                    title: '切换 Release 版本',
                    subtitle: '检出指定发布版本',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => showSwitchReleaseTagDialog(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.code_rounded,
                    iconColor: Colors.cyan.shade700,
                    title: '自定义 Git 仓库',
                    subtitle: '配置自定义仓库地址',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => showCustomGitCloneDialog(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.cleaning_services_rounded,
                    iconColor: Colors.orange,
                    title: '清空网页缓存',
                    subtitle: '清理内置网页缓存',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      unawaited(() async {
                        try {
                          await widget.maiBotController.clearCache();
                          if (context.mounted) {
                            Get.snackbar(
                              '成功',
                              '网页缓存已清理',
                              snackPosition: SnackPosition.BOTTOM,
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            Get.snackbar(
                              '清理失败',
                              e.toString(),
                              snackPosition: SnackPosition.BOTTOM,
                              backgroundColor: Colors.red,
                              colorText: Colors.white,
                            );
                          }
                        }
                      }());
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSectionHeader(
                  '维护与环境重置',
                  Icons.build_circle_rounded,
                  isDanger: true,
                ),
                _buildCard(
                  [
                    _buildSettingTile(
                      icon: Icons.backup_rounded,
                      iconColor: Colors.blue.shade700,
                      title: '备份 MaiBot 数据',
                      subtitle: '导出配置、插件及数据',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => unawaited(
                        BackupService.performBackup(showLoadingDialog: true),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.settings_backup_restore_rounded,
                      iconColor: Colors.indigo.shade600,
                      title: '从备份恢复数据',
                      subtitle: '还原备份存档',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => unawaited(BackupService.showRestoreDialog()),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.vpn_key_off_rounded,
                      iconColor: Colors.deepPurple.shade600,
                      title: 'WebUI 密码与端口急救',
                      subtitle: '离线重置登录密码或修复锁死的 8001 端口配置',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => _showWebUiRescueDialog(),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.cleaning_services_rounded,
                      iconColor: Colors.amber.shade900,
                      title: '清理容器残留锁',
                      subtitle: '移除异常退出遗留的 run.lock / instance.lock',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () {
                        unawaited(() async {
                          final removed = await HostRescueService.cleanStaleLocks();
                          Get.snackbar(
                            '清理完成',
                            removed > 0
                                ? '已移除 $removed 个残留锁文件并重启服务'
                                : '未发现残留锁文件',
                            snackPosition: SnackPosition.BOTTOM,
                          );
                        }());
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.bug_report_rounded,
                      iconColor: Colors.teal.shade700,
                      title: '导出诊断日志包',
                      subtitle: '打包日志与宿主配置至下载目录（自动脱敏密钥）',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () {
                        unawaited(() async {
                          final file = await HostRescueService.exportDiagnosticsBundle(
                            terminalLogText: homeController.terminal.getPlainText(),
                          );
                          Get.snackbar(
                            file != null ? '导出成功' : '导出失败',
                            file != null
                                ? '诊断包已保存至: ${file.path}'
                                : '未找到 MaiBot 日志或目录不存在',
                            snackPosition: SnackPosition.BOTTOM,
                            duration: const Duration(seconds: 4),
                          );
                        }());
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.restart_alt_rounded,
                      iconColor: Colors.orange.shade800,
                      title: '重置 Python 环境',
                      subtitle: '删除虚拟环境并重新构建',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => unawaited(MaintenanceActions.resetPythonEnv()),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.system_update_alt_rounded,
                      iconColor: Colors.deepOrange.shade700,
                      title: '重新安装 MaiBot',
                      subtitle: '重新安装 MaiBot 代码',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () =>
                          unawaited(MaintenanceActions.reinstallMaiBot()),
                    ),
                  ],
                  backgroundColor: Colors.red.withValues(alpha: 0.03),
                  borderColor: Colors.red.withValues(alpha: 0.2),
                ),
                const SizedBox(height: 16),
                _buildSectionHeader('关于与支持', Icons.info_outline_rounded),
                _buildCard([
                  _buildSettingTile(
                    icon: Icons.verified_rounded,
                    iconColor: primaryColor,
                    title: '软件版本',
                    subtitle: _appVersion.isEmpty
                        ? '加载中...'
                        : 'v$_appVersion',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '检查更新',
                        style: TextStyle(
                          fontSize: 12,
                          color: primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    onTap: () => _updateChecker.checkForUpdates(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.privacy_tip_rounded,
                    iconColor: Colors.blueGrey,
                    title: '隐私政策',
                    subtitle: '查看隐私政策',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      unawaited(() async {
                        try {
                          _cachedPrivacyContent ??= await rootBundle
                              .loadString('assets/privacy_policy.md');
                          if (context.mounted) {
                            Get.dialog(
                              Dialog(
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20)),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Row(
                                        children: [
                                          const Text(
                                            '隐私政策',
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const Spacer(),
                                          IconButton(
                                            icon: const Icon(Icons.close),
                                            onPressed: () => Get.back(),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Divider(height: 1),
                                    Flexible(
                                      child: SingleChildScrollView(
                                        padding: const EdgeInsets.all(16.0),
                                        child: MarkdownBody(
                                          data: _cachedPrivacyContent!,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            Get.snackbar(
                              '加载失败',
                              '无法加载隐私政策: $e',
                              snackPosition: SnackPosition.BOTTOM,
                            );
                          }
                        }
                      }());
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.power_settings_new_rounded,
                    iconColor: Colors.redAccent,
                    title: '退出应用',
                    subtitle: '停止前台服务并退出应用',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => unawaited(MaintenanceActions.exitApp()),
                  ),
                ]),
                const SizedBox(height: 36),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    IconData icon, {
    bool isDanger = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final Color dangerColor =
        isDark ? const Color(0xFFFF8A80) : colorScheme.error;
    final Color color = isDanger ? dangerColor : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    List<Widget> children, {
    Color? backgroundColor,
    Color? borderColor,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: backgroundColor ??
          theme.cardTheme.color ??
          theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: borderColor ??
              theme.colorScheme.outlineVariant
                  .withValues(alpha: isDark ? 0.35 : 0.45),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildSettingTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
