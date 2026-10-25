import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';

import '../../core/constants/scripts.dart';
import 'napcat_log_parser.dart';

class NapcatController extends GetxController {
  final RxString napCatWebUiToken = ''.obs; // 存储 NapCat WebUI Token
  final RxString maiBotWebUiToken = ''.obs; // 存储 MaiBot WebUI Token
  final RxBool _isQrcodeShowing = false.obs;
  final RxInt _qrcodeRefreshTrigger = 0.obs;
  Setting napCatWebUiEnabled = 'napcat_webui_enabled'.setting;
  final RxBool napCatWebUiEnabledRx = false.obs;

  Dialog? _qrcodeDialog;
  bool isQrcodeProcessed = false;

  @override
  void onInit() {
    super.onInit();
    napCatWebUiEnabledRx.value = napCatWebUiEnabled.get() ?? false;
    unawaited(reloadTokensFromDisk());
  }

  // 更新 NapCat WebUI 启用状态
  void setNapCatWebUiEnabled(bool value) {
    napCatWebUiEnabled.set(value);
    napCatWebUiEnabledRx.value = value;
  }

  /// 从本地配置文件恢复 MaiBot 与 NapCat 的 Token 及登录状态（支持后台常驻重连与冷启动）
  Future<void> reloadTokensFromDisk() async {
    await Future.wait([
      _loadMaibotTokenFromFile(),
      _loadNapcatTokenFromFile(),
    ]);
  }

  /// 从本地 /root/MaiBot/data/webui.json 直接读取 MaiBot WebUI 登录凭证 (Token)
  Future<bool> _loadMaibotTokenFromFile() async {
    try {
      final file = File('$ubuntuPath/root/MaiBot/data/webui.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final parsed = jsonDecode(content);
        if (parsed is Map) {
          final token = parsed['access_token']?.toString() ?? '';
          if (token.isNotEmpty) {
            maiBotWebUiToken.value = token;
            Log.i('成功从 webui.json 读取到 MaiBot Token: $token', tag: 'MaiBot');
            return true;
          }
        }
      }
    } catch (e) {
      Log.e('读取 MaiBot webui.json 失败: $e', tag: 'MaiBot');
    }
    return false;
  }

  /// 从本地 /root/napcat/config/webui.json 读取 NapCat Token 与自动登录状态
  Future<bool> _loadNapcatTokenFromFile() async {
    try {
      final configDir = Directory('$ubuntuPath/root/napcat/config');
      if (!await configDir.exists()) return false;

      final webuiFile = File('${configDir.path}/webui.json');
      if (await webuiFile.exists()) {
        final content = await webuiFile.readAsString();
        final parsed = jsonDecode(content);
        if (parsed is Map) {
          final token = parsed['token']?.toString() ?? '';
          if (token.isNotEmpty && napCatWebUiToken.value.isEmpty) {
            napCatWebUiToken.value = token;
            Log.i('成功从 napcat/config/webui.json 读取到 NapCat Token', tag: 'MaiBot');
          }
          final autoLogin = parsed['autoLoginAccount']?.toString() ?? '';
          if (autoLogin.isNotEmpty) {
            isQrcodeProcessed = true;
          }
        }
      }

      if (!isQrcodeProcessed) {
        await for (final entity in configDir.list()) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.startsWith('onebot11_') && fileName.endsWith('.json')) {
            final qq = fileName.substring(
              'onebot11_'.length,
              fileName.length - '.json'.length,
            );
            if (NapcatLogParser.isQQNumber(qq)) {
              isQrcodeProcessed = true;
              break;
            }
          }
        }
      }
      return napCatWebUiToken.value.isNotEmpty;
    } catch (e) {
      Log.w('读取 NapCat webui.json 失败: $e', tag: 'MaiBot');
      return false;
    }
  }

  void handleNapcatOutput(String event) async {
    final cleanEvent = NapcatLogParser.stripAnsi(event);

    for (final parsed in NapcatLogParser.parseNapcat(cleanEvent)) {
      switch (parsed.type) {
        case NapcatLogEventType.autoLoginSuccess:
          isQrcodeProcessed = true;
          if (_isQrcodeShowing.value && _qrcodeDialog != null) {
            Get.back();
            _isQrcodeShowing.value = false;
            _qrcodeDialog = null;
          }
          Log.i('检测到 NapCat 自动快速登录成功，准备进入主页面...', tag: 'MaiBot');
          break;

        case NapcatLogEventType.napcatToken:
          final token = parsed.payload;
          if (token != null) {
            napCatWebUiToken.value = token;
            Log.i('捕获到 NapCat Token: $token', tag: 'MaiBot');
          }
          break;

        case NapcatLogEventType.qrcodeSaved:
          if (!_isQrcodeShowing.value) {
            await _showQrcodeDialog();
          } else {
            final qrcodePath = '$ubuntuPath/root/napcat/cache/qrcode.png';
            await FileImage(File(qrcodePath)).evict();
            _qrcodeRefreshTrigger.value++;
          }
          break;

        case NapcatLogEventType.configLoaded:
          if (_isQrcodeShowing.value) {
            if (_qrcodeDialog != null) {
              Get.back();
              _isQrcodeShowing.value = false;
              _qrcodeDialog = null;
            }

            isQrcodeProcessed = true;
            _checkAndPromptSaveQQ();
          }
          break;

        case NapcatLogEventType.loginError:
          if (_isQrcodeShowing.value) {
            if (_qrcodeDialog != null) {
              Get.back();
              _isQrcodeShowing.value = false;
              _qrcodeDialog = null;
            }

            Get.snackbar(
              'NapCat 登录失败',
              parsed.payload ?? '登录失败',
              snackPosition: SnackPosition.BOTTOM,
              backgroundColor: Colors.red.withValues(alpha: 0.8),
              colorText: Colors.white,
              duration: const Duration(seconds: 5),
            );
          }
          break;
      }
    }
  }

  // 展示二维码登录对话框
  Future<void> _showQrcodeDialog() async {
    _isQrcodeShowing.value = true;
    final qrcodePath = '$ubuntuPath/root/napcat/cache/qrcode.png';
    final qrcodeFile = File(qrcodePath);

    if (!await qrcodeFile.exists()) {
      Get.showSnackbar(GetSnackBar(
        message: '二维码图片不存在：$qrcodePath',
        duration: const Duration(seconds: 3),
      ));
      _isQrcodeShowing.value = false;
      return;
    }

    await FileImage(qrcodeFile).evict();

    _qrcodeDialog = Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.qr_code_scanner_rounded,
                    color: colorScheme.onPrimaryContainer,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '请用手机 QQ 扫码登录',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '扫码成功后将自动跳转进入控制台',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Obx(() {
                    final _ = _qrcodeRefreshTrigger.value;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        qrcodeFile,
                        key: ValueKey(DateTime.now().millisecondsSinceEpoch),
                        width: 200,
                        height: 200,
                        fit: BoxFit.contain,
                      ),
                    );
                  }),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (isQrcodeProcessed) {
      _isQrcodeShowing.value = false;
      _qrcodeDialog = null;
      return;
    }

    await Get.dialog(
      _qrcodeDialog!,
      barrierDismissible: false,
    );

    _isQrcodeShowing.value = false;
    _qrcodeDialog = null;
  }

  void handleMaibotOutput(String event) {
    final cleanEvent = NapcatLogParser.stripAnsi(event);

    final token = NapcatLogParser.parseMaibotToken(cleanEvent);
    if (token != null) {
      maiBotWebUiToken.value = token;
      Log.i('成功从日志中抓取到 MaiBot Token: $token', tag: 'MaiBot');
    } else if (cleanEvent.contains('WebUI Token 已加载') &&
        maiBotWebUiToken.value.isEmpty) {
      unawaited(_loadMaibotTokenFromFile());
    }
  }

  void _checkAndPromptSaveQQ() async {
    try {
      final String configPath = '$ubuntuPath/root/napcat/config';
      final Directory configDir = Directory(configPath);
      if (!await configDir.exists()) return;

      final List<FileSystemEntity> files = await configDir.list().toList();
      String? loggedInQQ;

      for (var file in files) {
        final String fileName = file.path.split(Platform.pathSeparator).last;
        if (fileName.startsWith('onebot11_') && fileName.endsWith('.json')) {
          loggedInQQ = fileName.substring(
            'onebot11_'.length,
            fileName.length - '.json'.length,
          );
          if (NapcatLogParser.isQQNumber(loggedInQQ)) {
            break;
          } else {
            loggedInQQ = null;
          }
        }
      }

      if (loggedInQQ == null || loggedInQQ.isEmpty) return;

      final File webuiFile = File('$configPath/webui.json');
      if (!await webuiFile.exists()) return;

      final Map<String, dynamic> webuiConfig =
          jsonDecode(await webuiFile.readAsString());
      final String currentQQ =
          webuiConfig['autoLoginAccount']?.toString() ?? '';

      if (currentQQ.isEmpty) {
        Get.dialog(
          AlertDialog(
            icon: const Icon(Icons.account_circle_rounded, size: 28),
            title: const Text('快速登录设置'),
            content: Text(
              '检测到您已登录 QQ: $loggedInQQ\n是否将其保存为快速登录账号？\n设置后下次启动将免扫码自动登录。',
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  unawaited(() async {
                    webuiConfig['autoLoginAccount'] = loggedInQQ;
                    await webuiFile.writeAsString(
                      const JsonEncoder.withIndent('    ').convert(webuiConfig),
                    );
                    Get.back();
                    Get.snackbar(
                      '保存成功',
                      '已将 $loggedInQQ 设置为快速登录账号',
                      snackPosition: SnackPosition.BOTTOM,
                    );
                  }());
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Log.e('检测登录账号失败: $e', tag: 'MaiBot');
    }
  }
}
