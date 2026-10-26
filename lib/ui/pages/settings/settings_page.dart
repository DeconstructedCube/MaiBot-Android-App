import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:global_repository/global_repository.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/config/app_config.dart';
import '../../../core/services/backup_service.dart';
import '../../../core/utils/version_utils.dart';
import 'dialogs/update_dialogs.dart';
import 'dialogs/quick_login_dialog.dart';
import 'dialogs/git_clone_dialog.dart';
import 'dialogs/git_dialogs.dart';
import 'keep_alive_settings_page.dart';
import 'maintenance_actions.dart';
import 'widgets/settings_header_card.dart';
import 'widgets/theme_settings_card.dart';
import 'widgets/token_and_webview_card.dart';

class SettingsPage extends StatefulWidget {
  final WebViewController maiBotController;
  final WebViewController napCatController;
  final Function(int) onNavigate;

  const SettingsPage({
    super.key,
    required this.maiBotController,
    required this.napCatController,
    required this.onNavigate,
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
          '已在文件管理器中打开 MaiBot Ubuntu 文件系统',
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
                  'Ubuntu 文件系统已挂载至系统"文件"应用的侧栏，名称为:',
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
                  '你可以手动打开系统"文件"应用，在侧栏中找到"MaiBot Ubuntu"来访问。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                const Text(
                  '或使用 MT 文件管理器等应用，添加以下路径至侧栏:',
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
                _buildSectionHeader('界面与主题', Icons.palette_rounded),
                ThemeSettingsCard(controller: themeController),
                const SizedBox(height: 16),
                _buildSectionHeader('常用操作', Icons.tune_rounded),
                _buildCard([
                  _buildSettingTile(
                    icon: Icons.home_rounded,
                    iconColor: Colors.blue,
                    title: '回到 MaiBot 主页',
                    subtitle: '重置并刷新 MaiBot 页面',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      widget.maiBotController.loadRequest(
                        Uri.parse('http://127.0.0.1:${Ports.maibotWeb}'),
                      );
                      widget.onNavigate(0);
                      Get.snackbar(
                        '已跳转',
                        'MaiBot 页面已重置并刷新',
                        snackPosition: SnackPosition.BOTTOM,
                        duration: const Duration(seconds: 2),
                      );
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.account_circle_rounded,
                    iconColor: Colors.indigo,
                    title: '快速登录 QQ',
                    subtitle: '配置自动免扫码登录的 QQ 账号',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => showQuickLoginDialog(),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildSettingTile(
                    icon: Icons.folder_open_rounded,
                    iconColor: Colors.amber.shade800,
                    title: '查看数据目录与文件',
                    subtitle: '通过系统文件管理或 MT 管理器浏览 Ubuntu 环境目录',
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
                    subtitle: '系统运行权限、电池优化及后台常驻策略',
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
                    subtitle: '执行 git pull 拉取当前分支最新代码并同步依赖',
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
                    subtitle: '获取并切换 MaiBot 代码分支',
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
                    subtitle: '按 Release Tag 检出指定版本',
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
                    title: '自定义 Git Clone 链接',
                    subtitle: '配置自定义或 Fork 的 MaiBot 仓库地址',
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
                    title: '清空 WebView 缓存',
                    subtitle: '清理内置网页与控制台的临时缓存',
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () {
                      unawaited(() async {
                        try {
                          await widget.maiBotController.clearCache();
                          await widget.napCatController.clearCache();
                          if (context.mounted) {
                            Get.snackbar(
                              '成功',
                              'WebView 缓存已清理',
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
                      subtitle: '打包本地配置、插件及数据至手机下载目录',
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
                      subtitle: '选择本地备份存档，支持按模块细粒度还原',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => unawaited(BackupService.showRestoreDialog()),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.restart_alt_rounded,
                      iconColor: Colors.orange.shade800,
                      title: '重置 Python 环境',
                      subtitle: '删除虚拟环境并在启动时重新构建依赖',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () => unawaited(MaintenanceActions.resetPythonEnv()),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.refresh_rounded,
                      iconColor: Colors.deepOrange,
                      title: '重新安装 NapCat 组件',
                      subtitle: '清除 NapCat 文件并触发重新安装',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onTap: () =>
                          unawaited(MaintenanceActions.reinstallNapcat()),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildSettingTile(
                      icon: Icons.system_update_alt_rounded,
                      iconColor: Colors.deepOrange.shade700,
                      title: '重新安装 MaiBot',
                      subtitle: '重新拉取并安装 MaiBot 代码',
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
                    subtitle: '查看应用隐私保护与开源协议条款',
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
                    subtitle: '完全终止前台守护服务与容器进程',
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
