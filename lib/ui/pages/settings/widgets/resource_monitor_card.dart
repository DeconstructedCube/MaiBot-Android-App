import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../../core/config/app_config.dart';

/// 设置页：实时资源监控卡片（CPU / 容器内存 / 应用与系统内存）
class ResourceMonitorCard extends StatefulWidget {
  final bool isVisible;

  const ResourceMonitorCard({super.key, this.isVisible = true});
  @override
  State<ResourceMonitorCard> createState() => _ResourceMonitorCardState();
}

class _ResourceMonitorCardState extends State<ResourceMonitorCard>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(Config.methodChannel);

  Timer? _timer;
  bool _isForeground = true;
  bool _isSampling = false;

  double _cpuPercent = 0.0;
  double _appMemoryMb = 0.0;
  double _containerMemoryMb = 0.0;
  int _processCount = 0;
  double _systemAvailMb = 0.0;
  double _systemTotalMb = 0.0;
  bool _hasSampled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.isVisible) {
      unawaited(_refreshStats());
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(covariant ResourceMonitorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      if (widget.isVisible && _isForeground) {
        unawaited(_refreshStats());
        _startTimer();
      } else {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      if (widget.isVisible) {
        unawaited(_refreshStats());
        _startTimer();
      }
    } else if (state == AppLifecycleState.paused) {
      _isForeground = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (!widget.isVisible || !_isForeground) return;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isForeground && widget.isVisible && mounted) {
        unawaited(_refreshStats());
      }
    });
  }

  Future<void> _refreshStats() async {
    if (!Platform.isAndroid || _isSampling) return;
    _isSampling = true;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'get_resource_usage',
      );
      if (raw != null && mounted) {
        setState(() {
          _cpuPercent = (raw['cpuPercent'] as num?)?.toDouble() ?? 0.0;
          _appMemoryMb = (raw['appMemoryMb'] as num?)?.toDouble() ?? 0.0;
          _containerMemoryMb =
              (raw['containerMemoryMb'] as num?)?.toDouble() ?? 0.0;
          _processCount = (raw['processCount'] as num?)?.toInt() ?? 0;
          _systemAvailMb = (raw['systemAvailMb'] as num?)?.toDouble() ?? 0.0;
          _systemTotalMb = (raw['systemTotalMb'] as num?)?.toDouble() ?? 0.0;
          _hasSampled = true;
        });
      }
    } catch (_) {
    } finally {
      _isSampling = false;
    }
  }

  String _formatMb(double mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} GB';
    }
    return '${mb.toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final double sysUsedMb =
        (_systemTotalMb - _systemAvailMb).clamp(0.0, _systemTotalMb);
    final double sysUsedRatio =
        _systemTotalMb > 0 ? (sysUsedMb / _systemTotalMb).clamp(0.0, 1.0) : 0.0;
    final double cpuRatio = (_cpuPercent / 100.0).clamp(0.0, 1.0);

    Color metricColor(double ratio) {
      if (ratio >= 0.85) return colorScheme.error;
      if (ratio >= 0.65) return Colors.orange;
      return colorScheme.primary;
    }

    return Card(
      elevation: 0,
      color: theme.cardTheme.color ?? colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: colorScheme.outlineVariant
              .withValues(alpha: isDark ? 0.35 : 0.45),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.monitor_heart_rounded,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '运行资源监控',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                if (_hasSampled)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '容器进程 $_processCount',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _buildMetricBlock(
                    context: context,
                    label: 'CPU 占用',
                    value: _hasSampled
                        ? '${_cpuPercent.toStringAsFixed(1)}%'
                        : '采样中...',
                    ratio: cpuRatio,
                    barColor: metricColor(cpuRatio),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildMetricBlock(
                    context: context,
                    label: '应用/容器内存',
                    value: _hasSampled
                        ? '${_formatMb(_appMemoryMb)} (${_formatMb(_containerMemoryMb)})'
                        : '采样中...',
                    ratio: _systemTotalMb > 0
                        ? (_appMemoryMb / _systemTotalMb).clamp(0.0, 1.0)
                        : 0.0,
                    barColor: colorScheme.tertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildMetricBlock(
              context: context,
              label: '系统内存',
              value: _hasSampled
                  ? '可用 ${_formatMb(_systemAvailMb)} / ${_formatMb(_systemTotalMb)}'
                  : '读取中...',
              ratio: sysUsedRatio,
              barColor: metricColor(sysUsedRatio),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricBlock({
    required BuildContext context,
    required String label,
    required String value,
    required double ratio,
    required Color barColor,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Flexible(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _hasSampled ? ratio : null,
            minHeight: 5,
            backgroundColor: colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
      ],
    );
  }
}
