import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:global_repository/global_repository.dart';
import 'package:toml/toml.dart';

import '../config/app_config.dart';
import '../constants/scripts.dart' as scripts;

class ConfigService {
  static String _generateSecureToken([int length = 24]) {
    final rand = Random.secure();
    final bytes = List<int>.generate(length, (_) => rand.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Map<String, dynamic> _buildDefaultWsServerEntry(int port, String token) {
    return {
      "name": "WsServer",
      "enable": true,
      "host": "127.0.0.1",
      "port": port,
      "reportSelfMessage": false,
      "enableForcePushEvent": true,
      "messagePostFormat": "array",
      "token": token,
      "debug": false,
      "heartInterval": 30000,
    };
  }

  /// 异步校验并同步 NapCat OneBot11（含账号专属配置）与 MaiBot 适配器（NapCat / SnowLuma）的通信凭证与端口
  static Future<void> ensureConfigsSynced() async {
    try {
      final String napcatConfigDir = '${scripts.ubuntuPath}/root/napcat/config';
      final String onebotPath = '$napcatConfigDir/onebot11.json';

      String token = _generateSecureToken();
      int port = Ports.onebotWsDefault;

      await Directory(napcatConfigDir).create(recursive: true);

      // 1. 确保默认 onebot11.json 存在且包含有效 WsServer
      final onebotFile = File(onebotPath);
      if (await onebotFile.exists()) {
        try {
          final content = await onebotFile.readAsString();
          final Map<String, dynamic> data = jsonDecode(content);
          final wsServers = data['network']?['websocketServers'] as List?;
          if (wsServers != null && wsServers.isNotEmpty) {
            final firstWs = wsServers.first;
            if (firstWs is Map) {
              final existingToken = firstWs['token']?.toString() ?? '';
              if (existingToken.isNotEmpty) {
                token = existingToken;
              }
              port = int.tryParse(firstWs['port']?.toString() ?? '') ?? port;
            }
          } else {
            data['network'] ??= {};
            data['network']['websocketServers'] = [_buildDefaultWsServerEntry(port, token)];
            await onebotFile.writeAsString(
              const JsonEncoder.withIndent('  ').convert(data),
            );
          }
        } catch (e) {
          Log.w('Failed to parse onebot11.json, using default token/port', tag: 'ConfigService');
        }
      } else {
        final defaultOnebot = {
          "network": {
            "httpServers": [],
            "httpClients": [],
            "websocketServers": [_buildDefaultWsServerEntry(port, token)],
            "websocketClients": [],
          },
          "musicSignUrl": "",
          "enableLocalFile2Url": false,
          "parseMultMsg": false,
        };
        await onebotFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(defaultOnebot),
        );
      }

      // 1.5 同步已登录 QQ 账号的专属配置文件 onebot11_<qq>.json，防止扫码登录后 websocketServers 为空导致断联
      await for (final entity in Directory(napcatConfigDir).list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('onebot11_') && name.endsWith('.json')) {
            try {
              final content = await entity.readAsString();
              final Map<String, dynamic> qqData = jsonDecode(content);
              qqData['network'] ??= {};
              final wsList = qqData['network']['websocketServers'] as List?;
              if (wsList == null || wsList.isEmpty) {
                qqData['network']['websocketServers'] = [
                  _buildDefaultWsServerEntry(port, token),
                ];
              } else if (wsList.first is Map) {
                wsList.first['enable'] = true;
                wsList.first['host'] = '127.0.0.1';
                wsList.first['port'] = port;
                wsList.first['token'] = token;
              }
              await entity.writeAsString(
                const JsonEncoder.withIndent('  ').convert(qqData),
              );
            } catch (_) {}
          }
        }
      }

      // 2. 同步至 MaiBot-Napcat-Adapter config.toml
      final String adapterConfigDir =
          '${scripts.ubuntuPath}/root/MaiBot/plugins/MaiBot-Napcat-Adapter';
      await _syncNapcatAdapterConfig(adapterConfigDir, port, token);

      // 3. 若用户安装了新版 MaiBot-SnowLuma-Adapter，同步其 [client] 配置段
      for (final snowDirName in ['MaiBot-SnowLuma-Adapter', 'maibot-team.snowluma-adapter']) {
        final snowDir = Directory('${scripts.ubuntuPath}/root/MaiBot/plugins/$snowDirName');
        if (await snowDir.exists()) {
          await _syncSnowLumaAdapterConfig(snowDir.path, port, token);
        }
      }

      Log.i('Configs synced successfully. Token: $token, Port: $port', tag: 'ConfigService');
    } catch (e, stackTrace) {
      Log.e('Error syncing configs: $e\n$stackTrace', tag: 'ConfigService');
    }
  }

  static Future<void> _syncNapcatAdapterConfig(
    String adapterConfigDir,
    int port,
    String token,
  ) async {
    final adapterFile = File('$adapterConfigDir/config.toml');
    Map<String, dynamic> tomlData = {};

    if (await adapterFile.exists()) {
      try {
        final content = await adapterFile.readAsString();
        tomlData = TomlDocument.parse(content).toMap();
      } catch (e) {
        Log.w('Failed to parse NapCat adapter config.toml, will recreate', tag: 'ConfigService');
      }
    }

    tomlData['plugin'] ??= {
      'enabled': true,
      'config_version': '0.1.0',
    };
    if (tomlData['plugin'] is Map) {
      tomlData['plugin']['enabled'] ??= true;
      tomlData['plugin']['config_version'] ??= '0.1.0';
    }

    tomlData['napcat_server'] ??= {};
    tomlData['napcat_server']['host'] = '127.0.0.1';
    tomlData['napcat_server']['port'] = port;
    tomlData['napcat_server']['token'] = token;
    tomlData['napcat_server']['heartbeat_interval'] ??= 30.0;
    tomlData['napcat_server']['reconnect_delay_sec'] ??= 5.0;
    tomlData['napcat_server']['action_timeout_sec'] ??= 15.0;

    await Directory(adapterConfigDir).create(recursive: true);
    final newTomlString = TomlDocument.fromMap(tomlData).toString();
    await adapterFile.writeAsString(newTomlString);
  }

  static Future<void> _syncSnowLumaAdapterConfig(
    String snowConfigDir,
    int port,
    String token,
  ) async {
    final configFile = File('$snowConfigDir/config.toml');
    Map<String, dynamic> tomlData = {};

    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        tomlData = TomlDocument.parse(content).toMap();
      } catch (_) {}
    }

    tomlData['plugin'] ??= {
      'enabled': true,
      'config_version': '2.7.1',
    };
    if (tomlData['plugin'] is Map) {
      tomlData['plugin']['enabled'] ??= true;
      tomlData['plugin']['config_version'] ??= '2.7.1';
    }

    tomlData['client'] ??= {};
    tomlData['client']['client_type'] ??= 'napcat';
    tomlData['client']['server'] = '127.0.0.1';
    tomlData['client']['port'] = port;
    tomlData['client']['token'] = token;
    tomlData['client']['heartbeat_interval'] ??= 30.0;
    tomlData['client']['reconnect_delay_sec'] ??= 5.0;
    tomlData['client']['action_timeout_sec'] ??= 30.0;

    final newTomlString = TomlDocument.fromMap(tomlData).toString();
    await configFile.writeAsString(newTomlString);
  }
}
