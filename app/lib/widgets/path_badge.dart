import 'package:flutter/material.dart';

import '../core/models.dart';
import '../util/format.dart';

/// Shows whether a session's traffic is relayed (DERP) or direct.
class PathBadge extends StatelessWidget {
  const PathBadge({super.key, required this.session, this.compact = false});

  final Session session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = session.path;
    final (icon, label, color) = switch (session.state) {
      SessionState.failed => (Icons.error_outline, '失败', cs.error),
      SessionState.stopped => (Icons.stop_circle_outlined, '已停止', cs.outline),
      SessionState.done => (Icons.check_circle_outline, '已完成', cs.primary),
      SessionState.starting => (Icons.hourglass_top, session.detail.isEmpty ? '启动中' : session.detail, cs.tertiary),
      SessionState.running => path == null || !path.isKnown
          ? (Icons.wifi_tethering, session.kind == SessionKind.server ? '等待连接' : '已连接', cs.secondary)
          : path.isDirect
              ? (Icons.bolt, '直连 ${compact ? '' : path.detail}'.trim(), Colors.green.shade700)
              : (Icons.cloud_outlined, '中继 ${compact ? '' : path.detail}'.trim(), cs.secondary),
    };
    final latency = path?.latencyMs;
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(
        latency != null && !compact && session.state == SessionState.running ? '$label · ${formatLatency(latency)}' : label,
        style: TextStyle(color: color),
      ),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      visualDensity: VisualDensity.compact,
    );
  }
}
