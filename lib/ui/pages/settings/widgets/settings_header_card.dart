import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../core/services/backend_process_manager.dart';

/// 设置页顶部品牌与实时容器状态展示卡片
class SettingsHeaderCard extends StatelessWidget {
  final String appVersion;
  final Color primaryColor;

  const SettingsHeaderCard({
    super.key,
    required this.appVersion,
    required this.primaryColor,
  });

  ({String label, Color dotColor}) _resolveStatus(
    ProcessState maibot,
    ProcessState napcat,
    int retry,
  ) {
    if (maibot == ProcessState.running) {
      return (label: '服务运行中', dotColor: const Color(0xFF69F0AE));
    }
    if (maibot == ProcessState.starting || napcat == ProcessState.starting) {
      return (label: '正在启动...', dotColor: const Color(0xFFFFD740));
    }
    if (maibot == ProcessState.restarting || napcat == ProcessState.restarting) {
      final suffix = retry > 0 ? ' (#$retry)' : '';
      return (label: '重启恢复中$suffix', dotColor: const Color(0xFFFFAB40));
    }
    if (maibot == ProcessState.error || napcat == ProcessState.error) {
      return (label: '服务异常', dotColor: const Color(0xFFFF5252));
    }
    if (maibot == ProcessState.stopping) {
      return (label: '正在停止...', dotColor: const Color(0xFFFFAB40));
    }
    if (napcat == ProcessState.running) {
      return (label: 'NapCat 运行中', dotColor: const Color(0xFF69F0AE));
    }
    return (label: '后台待命', dotColor: const Color(0xFFB0BEC5));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [primaryColor, primaryColor.withValues(alpha: 0.82)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MaiBot Android',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  appVersion.isEmpty ? '加载中...' : '版本: v$appVersion',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Obx(() {
            final status = _resolveStatus(
              BackendProcessManager.maibotState.value,
              BackendProcessManager.napcatState.value,
              BackendProcessManager.maibotRetryCount.value,
            );
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: status.dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
