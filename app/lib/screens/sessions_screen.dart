import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../widgets/path_badge.dart';
import '../widgets/progress_tile.dart';
import 'client_session_screen.dart';
import 'server_screen.dart';

/// Sessions, transfers and logs.
class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('会话'),
          bottom: const TabBar(tabs: [Tab(text: '会话'), Tab(text: '传输'), Tab(text: '日志')]),
        ),
        body: const TabBarView(children: [_SessionsTab(), _TransfersTab(), _LogTab()]),
      ),
    );
  }
}

class _SessionsTab extends ConsumerWidget {
  const _SessionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider).values.toList()..sort((a, b) => b.createdMs.compareTo(a.createdMs));
    if (sessions.isEmpty) return const Center(child: Text('还没有会话'));
    return ListView.builder(
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        return ListTile(
          leading: Icon(_icon(s.kind)),
          title: Text('${s.kind.label} · ${s.id}'),
          subtitle: Text(s.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PathBadge(session: s, compact: true),
              if (s.state.isActive)
                IconButton(
                  tooltip: '停止',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () => ref.read(sessionsProvider.notifier).stop(s.id),
                )
              else
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close),
                  onPressed: () => ref.read(sessionsProvider.notifier).remove(s.id),
                ),
            ],
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => s.kind == SessionKind.server
                ? ServerScreen(sessionId: s.id)
                : ClientSessionScreen(sessionId: s.id, title: s.kind.label),
          )),
        );
      },
    );
  }

  IconData _icon(SessionKind k) => switch (k) {
        SessionKind.server => Icons.dns_outlined,
        SessionKind.forward => Icons.cable,
        SessionKind.socks => Icons.vpn_lock_outlined,
        SessionKind.send => Icons.upload_outlined,
        SessionKind.recv => Icons.download_outlined,
        SessionKind.ssh => Icons.terminal,
        SessionKind.unknown => Icons.help_outline,
      };
}

class _TransfersTab extends ConsumerWidget {
  const _TransfersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider).values.toList().reversed.toList();
    if (transfers.isEmpty) return const Center(child: Text('没有传输记录'));
    return Column(
      children: [
        Expanded(child: ListView(children: [for (final t in transfers) ProgressTile(transfer: t)])),
        SafeArea(
          child: TextButton(
            onPressed: () => ref.read(transfersProvider.notifier).clearFinished(),
            child: const Text('清除已完成'),
          ),
        ),
      ],
    );
  }
}

class _LogTab extends ConsumerWidget {
  const _LogTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(logProvider);
    final debug = ref.watch(showDebugLogsProvider);
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        SwitchListTile(
          dense: true,
          title: const Text('显示调试日志'),
          value: debug,
          onChanged: (v) => ref.read(showDebugLogsProvider.notifier).state = v,
        ),
        Expanded(
          child: lines.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  reverse: true,
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final l = lines[lines.length - 1 - i];
                    final t = DateTime.fromMillisecondsSinceEpoch(l.ts);
                    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      child: SelectableText(
                        '$ts ${l.sessionId != null ? '[${l.sessionId}] ' : ''}${l.msg}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: l.level == 'error' ? cs.error : l.level == 'debug' ? cs.outline : null,
                        ),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(child: TextButton(onPressed: () => ref.read(logProvider.notifier).clear(), child: const Text('清空'))),
      ],
    );
  }
}
