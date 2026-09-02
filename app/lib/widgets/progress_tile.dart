import 'package:flutter/material.dart';

import '../core/models.dart';
import '../util/format.dart';

class ProgressTile extends StatelessWidget {
  const ProgressTile({super.key, required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final name = t.file.split('/').where((s) => s.isNotEmpty).lastOrNull ?? t.file;
    final status = t.done
        ? '完成 · ${formatBytes(t.bytes)}'
        : t.total > 0
            ? '${formatBytes(t.bytes)} / ${formatBytes(t.total)}  ${formatRate(t.rateBps)}'
            : '${formatBytes(t.bytes)}  ${formatRate(t.rateBps)}';
    return ListTile(
      leading: Icon(t.direction == 'up' ? Icons.upload_outlined : Icons.download_outlined),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(value: t.done ? 1 : t.fraction),
          const SizedBox(height: 4),
          Text(status, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
