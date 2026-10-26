import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';

import '../../../../core/constants/scripts.dart' as scripts;

// 显示快速登录QQ对话框
Future<void> showQuickLoginDialog() async {
  final webuiJsonPath = '${scripts.ubuntuPath}/root/napcat/config/webui.json';
  final webuiJsonFile = File(webuiJsonPath);

  // 读取并解析 JSON 文件（若不存在则自动初始化）
  String currentQQ = '';
  Map<String, dynamic> jsonData = {};
  if (await webuiJsonFile.exists()) {
    try {
      final jsonContent = await webuiJsonFile.readAsString();
      jsonData = jsonDecode(jsonContent) as Map<String, dynamic>;
      currentQQ = jsonData['autoLoginAccount']?.toString() ?? '';
    } catch (e) {
      Log.w('读取 webui.json 失败，使用默认配置: $e', tag: 'MaiBot');
    }
  }

  // 显示编辑对话框
  final qqController = TextEditingController(text: currentQQ);

  final result = await Get.dialog<bool>(
    AlertDialog(
      icon: const Icon(Icons.account_circle_rounded, size: 28),
      title: const Text('快速登录 QQ'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: qqController,
            decoration: const InputDecoration(
              labelText: 'QQ 账号',
              hintText: '请输入用于免扫码登录的 QQ 号',
              prefixIcon: Icon(Icons.numbers_rounded),
            ),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Get.back(result: true),
          child: const Text('保存'),
        ),
      ],
    ),
  );

  // 如果用户点击了保存
  if (result == true) {
    final newQQ = qqController.text.trim();

    try {
      // 确保目录存在并补齐默认配置字段
      await webuiJsonFile.parent.create(recursive: true);
      jsonData['host'] ??= '0.0.0.0';
      jsonData['port'] ??= 6099;
      jsonData['loginRate'] ??= 3;
      jsonData['autoLoginAccount'] = newQQ;

      // 写回文件
      await webuiJsonFile.writeAsString(
        const JsonEncoder.withIndent('    ').convert(jsonData),
      );

      Get.snackbar(
        '保存成功',
        'QQ号已更新为: $newQQ',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
      Log.i('自动登录QQ号已更新: $newQQ', tag: 'MaiBot');
    } catch (e) {
      Get.snackbar(
        '保存失败',
        '写入 webui.json 失败: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
      Log.e('保存自动登录QQ号失败: $e', tag: 'MaiBot');
    }
  }

  qqController.dispose();
}
