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

  /// 异步校验并同步 NapCat OneBot11 与 MaiBot 适配器的通信凭证与端口
  static Future<void> ensureConfigsSynced() async {
    try {
      final String napcatConfigDir = '${scripts.ubuntuPath}/root/napcat/config';
      final String onebotPath = '$napcatConfigDir/onebot11.json';

      final String adapterConfigDir = '${scripts.ubuntuPath}/root/MaiBot/plugins/MaiBot-Napcat-Adapter';
      final String adapterConfigPath = '$adapterConfigDir/config.toml';

      // 1. Ensure NapCat onebot11.json exists with a token
      String token = _generateSecureToken();
      int port = Ports.onebotWsDefault;

      final onebotFile = File(onebotPath);
      if (await onebotFile.exists()) {
        try {
          final content = await onebotFile.readAsString();
          final Map<String, dynamic> data = jsonDecode(content);
          final wsServers = data['network']?['websocketServers'] as List?;
          if (wsServers != null && wsServers.isNotEmpty) {
            token = wsServers.first['token']?.toString() ?? token;
            port = int.tryParse(wsServers.first['port']?.toString() ?? '') ?? port;
          }
        } catch (e) {
          Log.w('Failed to parse onebot11.json, using default token/port', tag: 'ConfigService');
        }
      } else {
        await Directory(napcatConfigDir).create(recursive: true);
        final defaultOnebot = {
          "network": {
            "httpServers": [],
            "httpClients": [],
            "websocketServers": [
              {
                "name": "WsServer",
                "enable": true,
                "host": "127.0.0.1",
                "port": port,
                "reportSelfMessage": false,
                "enableForcePushEvent": true,
                "messagePostFormat": "array",
                "token": token,
                "debug": false,
                "heartInterval": 30000
              }
            ],
            "websocketClients": []
          },
          "musicSignUrl": "",
          "enableLocalFile2Url": false,
          "parseMultMsg": false
        };
        await onebotFile.writeAsString(const JsonEncoder.withIndent('  ').convert(defaultOnebot));
      }

      // 2. Sync to MaiBot-Napcat-Adapter config.toml
      final adapterFile = File(adapterConfigPath);
      Map<String, dynamic> tomlData = {};

      if (await adapterFile.exists()) {
        try {
          final content = await adapterFile.readAsString();
          tomlData = TomlDocument.parse(content).toMap();
        } catch (e) {
          Log.w('Failed to parse config.toml, will recreate', tag: 'ConfigService');
        }
      }

      tomlData['plugin'] ??= {
        'enabled': true,
        'config_version': '0.1.0'
      };

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

      Log.i('Configs synced successfully. Token: $token, Port: $port', tag: 'ConfigService');
    } catch (e, stackTrace) {
      Log.e('Error syncing configs: $e\n$stackTrace', tag: 'ConfigService');
    }
  }
}
