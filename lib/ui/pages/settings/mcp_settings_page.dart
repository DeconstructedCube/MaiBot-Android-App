import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants/scripts.dart' as scripts;

/// 内置 `:backend` MCP 服务配置与状态管理页面
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({super.key});

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  static const MethodChannel _channel = MethodChannel(Config.methodChannel);

  bool _loading = true;
  bool _saving = false;
  Timer? _statusTimer;

  bool _enabled = false;
  int _port = 18081;
  String _token = '';
  bool _allowWrite = false;
  bool _allowExec = false;
  bool _allowServiceControl = true;
  String _rootScope = 'maibot';
  bool _protectSecrets = true;

  bool _running = false;
  int _boundPort = 0;
  String _lastError = '';
  int _requestCount = 0;
  String _lastToolName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfig());
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && !_saving) {
        unawaited(_loadConfig(silent: true));
      }
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig({bool silent = false}) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('get_mcp_config');
      if (raw != null && mounted) {
        setState(() {
          _enabled = raw['enabled'] == true;
          _port = (raw['port'] as num?)?.toInt() ?? 18081;
          _token = raw['token']?.toString() ?? '';
          _allowWrite = raw['allowWrite'] == true;
          _allowExec = raw['allowExec'] == true;
          _allowServiceControl = raw['allowServiceControl'] != false;
          _rootScope = raw['rootScope']?.toString() == 'ubuntu' ? 'ubuntu' : 'maibot';
          _protectSecrets = raw['protectSecrets'] != false;
          _running = raw['running'] == true;
          _boundPort = (raw['boundPort'] as num?)?.toInt() ?? 0;
          _lastError = raw['lastError']?.toString() ?? '';
          _requestCount = (raw['requestCount'] as num?)?.toInt() ?? 0;
          _lastToolName = raw['lastToolName']?.toString() ?? '';
          _loading = false;
        });
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _saveConfig({
    bool? enabled,
    int? port,
    bool? allowWrite,
    bool? allowExec,
    bool? allowServiceControl,
    String? rootScope,
    bool? protectSecrets,
  }) async {
    setState(() {
      _saving = true;
      if (enabled != null) _enabled = enabled;
      if (port != null) _port = port;
      if (allowWrite != null) _allowWrite = allowWrite;
      if (allowExec != null) _allowExec = allowExec;
      if (allowServiceControl != null) _allowServiceControl = allowServiceControl;
      if (rootScope != null) _rootScope = rootScope;
      if (protectSecrets != null) _protectSecrets = protectSecrets;
    });

    try {
      await _channel.invokeMethod('set_mcp_config', {
        'enabled': _enabled,
        'port': _port,
        'allowWrite': _allowWrite,
        'allowExec': _allowExec,
        'allowServiceControl': _allowServiceControl,
        'rootScope': _rootScope,
        'protectSecrets': _protectSecrets,
        'binPath': RuntimeEnvir.binPath,
        'homePath': RuntimeEnvir.homePath,
        'tmpPath': RuntimeEnvir.tmpPath,
        'ubuntuPath': scripts.ubuntuPath,
      });
      await Future.delayed(const Duration(milliseconds: 300));
      await _loadConfig(silent: true);
    } catch (e) {
      Get.snackbar('保存失败', e.toString(), snackPosition: SnackPosition.BOTTOM);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetToken() async {
    try {
      final newToken = await _channel.invokeMethod<String>('reset_mcp_token');
      if (newToken != null && mounted) {
        setState(() => _token = newToken);
        Get.snackbar(
          'Token 已重置',
          '请同步更新 Termux 客户端中的 Bearer Token',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      Get.snackbar('重置失败', e.toString(), snackPosition: SnackPosition.BOTTOM);
    }
  }

  Future<void> _editPortDialog() async {
    final ctrl = TextEditingController(text: _port.toString());
    final confirmed = await Get.dialog<int>(
      AlertDialog(
        title: const Text('设置 MCP 监听端口'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '本地端口 (1024 - 65535)',
            hintText: '默认 18081',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(ctrl.text.trim());
              if (parsed == null || parsed < 1024 || parsed > 65535) {
                Get.snackbar('端口无效', '请输入 1024 到 65535 之间的端口', snackPosition: SnackPosition.BOTTOM);
                return;
              }
              Get.back(result: parsed);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    unawaited(Future.delayed(const Duration(milliseconds: 400), ctrl.dispose));
    if (confirmed != null && confirmed != _port) {
      await _saveConfig(port: confirmed);
    }
  }

  String _buildClientConfigJson() {
    final activePort = _boundPort > 0 ? _boundPort : _port;
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'maibot-android': {
          'type': 'http',
          'url': 'http://127.0.0.1:$activePort/mcp',
          'headers': {
            'Authorization': 'Bearer $_token',
          },
        },
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final activePort = _boundPort > 0 ? _boundPort : _port;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('内置 MCP 服务', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Get.back(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                _buildStatusBanner(colorScheme, activePort),
                const SizedBox(height: 16),
                _buildSectionHeader(context, '服务与认证', Icons.hub_rounded),
                _buildCard(context, [
                  SwitchListTile(
                    secondary: const Icon(Icons.power_settings_new_rounded, size: 22),
                    title: const Text('启用后台 MCP 服务', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '运行在 :backend 独立保活进程中，切到 Termux 不易冻结',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    value: _enabled,
                    onChanged: _saving ? null : (v) => unawaited(_saveConfig(enabled: v)),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.lan_rounded, size: 22),
                    title: const Text('监听端口', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '仅绑定 127.0.0.1:$_port (Streamable HTTP /mcp)',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    trailing: OutlinedButton(
                      onPressed: _saving ? null : () => unawaited(_editPortDialog()),
                      child: const Text('修改', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.key_rounded, size: 22),
                    title: const Text('Bearer Token', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      _token.length > 20 ? '${_token.substring(0, 16)}••••' : _token,
                      style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: colorScheme.onSurfaceVariant),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, size: 19),
                          tooltip: '重置 Token',
                          onPressed: () => unawaited(_resetToken()),
                        ),
                        OutlinedButton(
                          onPressed: () {
                            unawaited(() async {
                              await Clipboard.setData(ClipboardData(text: _token));
                              Get.snackbar('已复制', 'MCP Bearer Token 已复制', snackPosition: SnackPosition.BOTTOM);
                            }());
                          },
                          child: const Text('复制', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSectionHeader(context, '权限与沙箱边界', Icons.security_rounded),
                _buildCard(context, [
                  SwitchListTile(
                    secondary: const Icon(Icons.edit_document, size: 22),
                    title: const Text('允许文件写入与删除', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '开放 fs_write 与 fs_delete 工具（关闭时仅允许只读排查）',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    value: _allowWrite,
                    onChanged: _saving ? null : (v) => unawaited(_saveConfig(allowWrite: v)),
                  ),
                  const Divider(height: 1, indent: 56),
                  SwitchListTile(
                    secondary: const Icon(Icons.terminal_rounded, size: 22),
                    title: const Text('允许容器 Shell 执行', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '开放 proot_exec 在 Ubuntu 容器内执行命令',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    value: _allowExec,
                    onChanged: _saving ? null : (v) => unawaited(_saveConfig(allowExec: v)),
                  ),
                  const Divider(height: 1, indent: 56),
                  SwitchListTile(
                    secondary: const Icon(Icons.restart_alt_rounded, size: 22),
                    title: const Text('允许服务控制与清锁', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '开放 service_control（启停/重启）与 rescue_clean_locks',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    value: _allowServiceControl,
                    onChanged: _saving ? null : (v) => unawaited(_saveConfig(allowServiceControl: v)),
                  ),
                  const Divider(height: 1, indent: 56),
                  SwitchListTile(
                    secondary: const Icon(Icons.privacy_tip_outlined, size: 22),
                    title: const Text('保护 WebUI 凭据文件', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      '禁止读取/修改 host/webui.json 与 sessions.sqlite3',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    value: _protectSecrets,
                    onChanged: _saving ? null : (v) => unawaited(_saveConfig(protectSecrets: v)),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.folder_special_rounded, size: 22),
                    title: const Text('文件沙箱根目录', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    subtitle: Text(
                      _rootScope == 'ubuntu' ? '整个 Ubuntu 容器根目录 (/)' : '仅限 MaiBot 目录 (/root/MaiBot)',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                    trailing: DropdownButton<String>(
                      value: _rootScope,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'maibot', child: Text('MaiBot')),
                        DropdownMenuItem(value: 'ubuntu', child: Text('Ubuntu')),
                      ],
                      onChanged: _saving
                          ? null
                          : (val) {
                              if (val != null) unawaited(_saveConfig(rootScope: val));
                            },
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSectionHeader(context, 'Termux 客户端接入', Icons.code_rounded),
                _buildCard(context, [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SelectableText(
                            _buildClientConfigJson(),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: colorScheme.onSurface,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.copy_all_rounded, size: 18),
                          label: const Text('复制 MCP 客户端 JSON 配置'),
                          onPressed: () {
                            unawaited(() async {
                              await Clipboard.setData(ClipboardData(text: _buildClientConfigJson()));
                              Get.snackbar('已复制', '可直接粘贴到 Termux Agent MCP 配置中', snackPosition: SnackPosition.BOTTOM);
                            }());
                          },
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _buildStatusBanner(ColorScheme colorScheme, int activePort) {
    final bool hasError = _enabled && !_running && _lastError.isNotEmpty;
    final Color bg = hasError
        ? colorScheme.errorContainer.withValues(alpha: 0.6)
        : (_running
            ? Colors.green.withValues(alpha: 0.12)
            : colorScheme.surfaceContainerHigh);
    final Color fg = hasError
        ? colorScheme.onErrorContainer
        : (_running ? Colors.green.shade700 : colorScheme.onSurfaceVariant);

    final String title = hasError
        ? 'MCP 启动失败'
        : (_running ? 'MCP 运行中' : (_enabled ? '正在启动 MCP...' : 'MCP 未启用'));
    final String detail = hasError
        ? _lastError
        : (_running
            ? 'http://127.0.0.1:$activePort/mcp · 请求数 $_requestCount${_lastToolName.isNotEmpty ? ' · 最近: $_lastToolName' : ''}'
            : '开启后可在 Termux 中通过 Streamable HTTP 直接操作容器');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            hasError
                ? Icons.error_outline_rounded
                : (_running ? Icons.check_circle_rounded : Icons.pause_circle_outline_rounded),
            color: fg,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: fg)),
                const SizedBox(height: 2),
                Text(detail, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, IconData icon) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, List<Widget> children) {
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
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
