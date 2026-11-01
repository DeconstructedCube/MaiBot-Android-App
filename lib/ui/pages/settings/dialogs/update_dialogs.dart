import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/utils/version_utils.dart';

/// 检查应用更新并展示更新/下载源对话框
class UpdateChecker {
  // 存储从GitHub API获取的原始下载URL
  String? _originalDownloadUrl;

  /// 检查更新：拉取最新版本、比较版本号并展示相应对话框
  Future<void> checkForUpdates() async {
    BuildContext? loadingDialogContext;
    void dismissLoadingDialog() {
      final ctx = loadingDialogContext;
      loadingDialogContext = null;
      if (ctx != null && ctx.mounted) {
        Navigator.of(ctx).pop();
      } else if (Get.isDialogOpen == true) {
        Get.back(canPop: false);
      }
    }

    try {
      // 每次检查更新时重置原始URL
      _originalDownloadUrl = null;

      // 显示加载提示
      unawaited(
        Get.dialog(
          Builder(
            builder: (ctx) {
              loadingDialogContext = ctx;
              return const Center(child: CircularProgressIndicator());
            },
          ),
          barrierDismissible: false,
        ),
      );
      // 获取当前版本
      final currentVersion = await getAppVersion();

      // 使用镜像源获取最新版本信息
      final mirrors = [
        ...Config.githubApiMirrors.map((mirror) =>
            '$mirror/${Config.githubApi}${Config.githubReleasesPath}'),
        '${Config.githubApi}${Config.githubReleasesPath}',
      ];

      Map<String, dynamic>? releaseData;

      for (final mirror in mirrors) {
        try {
          final response = await http.get(
            Uri.parse(mirror),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            releaseData = jsonDecode(response.body) as Map<String, dynamic>;
            break;
          }
        } catch (e) {
          Log.w('镜像源 $mirror 请求失败: $e', tag: 'MaiBot');
          continue;
        }
      }

      dismissLoadingDialog(); // 关闭加载提示

      if (releaseData == null) {
        Get.snackbar(
          '检查失败',
          '无法连接到更新服务器',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
        );
        return;
      }

      // 解析最新版本号
      final latestVersion =
          (releaseData['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      final releaseNotes = releaseData['body'] as String? ?? '暂无更新说明';

      // 比较版本号
      if (compareVersions(latestVersion, currentVersion) > 0) {
        // 有新版本，显示更新对话框
        _showUpdateDialog(latestVersion, releaseNotes, releaseData);
      } else {
        Get.snackbar(
          '已是最新版本',
          '当前版本 $currentVersion 已是最新版本',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      dismissLoadingDialog(); // 关闭加载提示
      Log.e('检查更新失败: $e', tag: 'MaiBot');
      Get.snackbar(
        '检查失败',
        '检查更新时发生错误: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  // 显示更新对话框
  void _showUpdateDialog(
      String version, String releaseNotes, Map<String, dynamic> releaseData) {
    Get.dialog(
      Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500, maxHeight: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.new_releases_rounded, color: colorScheme.onPrimaryContainer, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '发现新版本 v$version',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Get.back(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20.0),
                      child: MarkdownBody(
                        data: releaseNotes,
                        styleSheet: MarkdownStyleSheet(
                          h1: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                          h2: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                          h3: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                          p: TextStyle(fontSize: 14, color: colorScheme.onSurface, height: 1.45),
                          listBullet: TextStyle(fontSize: 14, color: colorScheme.primary),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Get.back(),
                          child: const Text('稍后再说'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            Get.back();
                            _showDownloadSourceDialog(releaseData);
                          },
                          child: const Text('去下载'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // 显示下载源选择对话框
  void _showDownloadSourceDialog(Map<String, dynamic> releaseData) {
    // 如果还没有保存原始URL，从releaseData中构造
    if (_originalDownloadUrl == null) {
      final assets = releaseData['assets'] as List?;
      final tagName = releaseData['tag_name'] as String?;

      if (tagName == null || assets == null) {
        Get.snackbar(
          '下载失败',
          '未找到版本信息',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 查找APK文件名
      String? apkFileName;
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          apkFileName = name;
          break;
        }
      }

      if (apkFileName == null) {
        Get.snackbar(
          '下载失败',
          '未找到可下载的APK文件',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 直接构造GitHub原始下载链接，避免使用可能被镜像站污染的URL
      _originalDownloadUrl =
          '${Config.githubDownloadBase}/$tagName/$apkFileName';
    }

    // 使用原始URL构建各个镜像源的下载链接
    final sources = [
      ...Config.downloadMirrors.map((mirror) => {
            'name': mirror['name']!,
            'icon':
                mirror['icon'] == 'speed' ? Icons.speed : Icons.cloud_download_rounded,
            'url': '${mirror['url']}/$_originalDownloadUrl',
          }),
      {
        'name': 'GitHub 官方直连',
        'icon': Icons.cloud_download_rounded,
        'url': _originalDownloadUrl!,
        'description': '直接从 GitHub 服务器下载',
      },
    ];

    Get.dialog(
      Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return AlertDialog(
            icon: const Icon(Icons.cloud_download_rounded, size: 28),
            title: const Text('选择下载源'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '请选择适合您网络环境的下载镜像源',
                  style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                ...sources.map((source) {
                  return ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(source['icon'] as IconData, size: 20, color: colorScheme.onPrimaryContainer),
                    ),
                    title: Text(source['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    subtitle: source['description'] != null
                        ? Text(
                            source['description'] as String,
                            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                          )
                        : null,
                    onTap: () {
                      unawaited(() async {
                        final url = source['url'] as String;
                        final uri = Uri.parse(url);

                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                          Get.back();
                        } else {
                          Get.snackbar(
                            '打开失败',
                            '无法打开浏览器',
                            snackPosition: SnackPosition.BOTTOM,
                            backgroundColor: Colors.red,
                            colorText: Colors.white,
                          );
                        }
                      }());
                    },
                  );
                }),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
  }
}
