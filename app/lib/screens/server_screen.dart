import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../widgets/path_badge.dart';
import '../widgets/progress_tile.dart';
import '../widgets/token_card.dart';

/// Shows a running server session: token, connection status, transfers.
class ServerScreen extends ConsumerWidget {
  const ServerScreen({super.key, required this.sessionId, this.title = '服务端'});

  final String sessionId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final transfers = ref.watch(sessionTransfersProvider(sessionId));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(child: Text(session.summary, style: Theme.of(context).textTheme.bodyMedium)),
                    PathBadge(session: session),
                  ],
                ),
                if (session.kind == SessionKind.server && session.state == SessionState.running)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('已连接客户端: ${session.peers}', style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 12),
                if (session.token != null)
                  TokenCard(token: session.token!)
                else if (session.state == SessionState.starting)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Row(
                        children: [
                          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 16),
                          Expanded(child: Text('正在选择中继并生成令牌…')),
                        ],
                      ),
                    ),
                  ),
                if (session.lastError != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(session.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                    ),
                  ),
                if (transfers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('传输', style: Theme.of(context).textTheme.titleMedium),
                  for (final t in transfers.reversed) ProgressTile(transfer: t),
                ],
                const SizedBox(height: 24),
                if (session.state.isActive)
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.errorContainer,
                      foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('断开并停止'),
                    onPressed: () => ref.read(sessionsProvider.notifier).stop(sessionId),
                  )
                else
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('返回'),
                  ),
              ],
            ),
    );
  }
}
