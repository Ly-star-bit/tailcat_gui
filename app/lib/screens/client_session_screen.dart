import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../platform/terminal_launcher.dart';
import '../widgets/path_badge.dart';
import '../widgets/progress_tile.dart';

/// Shows a client-side session (forward / socks / ssh / send / recv).
class ClientSessionScreen extends ConsumerWidget {
  const ClientSessionScreen({super.key, required this.sessionId, this.title = '连接', this.sshCommand});

  final String sessionId;
  final String title;

  /// For ssh sessions: the command line returned by start_ssh_forward.
  final String? sshCommand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId));
    final transfers = ref.watch(sessionTransfersProvider(sessionId));
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(child: Text(session.summary)),
                    PathBadge(session: session),
                  ],
                ),
                const SizedBox(height: 12),
                if (session.kind == SessionKind.forward || session.kind == SessionKind.socks)
                  _InfoCard(
                    title: session.kind == SessionKind.socks ? '本地 SOCKS5 代理' : '本地端口',
                    value: session.listen ?? '127.0.0.1:${session.localPort}',
                    hint: session.kind == SessionKind.socks
                        ? '把浏览器或工具的代理设为此地址；目标 server.tailcat 表示对方机器本身。'
                        : '访问此地址等同于访问对方的端口 ${session.remotePort}。',
                  ),
                if (session.kind == SessionKind.ssh && sshCommand != null)
                  _InfoCard(
                    title: 'SSH 命令',
                    value: sshCommand!,
                    hint: '在终端中运行即可登录对方机器（免密码，隧道已做身份验证）。',
                    actions: [
                      FilledButton.icon(
                        icon: const Icon(Icons.terminal),
                        label: const Text('打开终端'),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final ok = await openTerminalWith(sshCommand!);
                          if (!ok) {
                            await Clipboard.setData(ClipboardData(text: sshCommand!));
                            messenger.showSnackBar(
                              const SnackBar(content: Text('此平台无法自动打开终端，命令已复制')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                if (session.lastError != null)
                  Card(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(session.lastError!, style: TextStyle(color: cs.onErrorContainer)),
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
                      backgroundColor: cs.errorContainer,
                      foregroundColor: cs.onErrorContainer,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.power_settings_new),
                    label: Text(session.kind == SessionKind.send || session.kind == SessionKind.recv ? '取消传输' : '断开连接'),
                    onPressed: () => ref.read(sessionsProvider.notifier).stop(sessionId),
                  )
                else
                  OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回')),
              ],
            ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.value, required this.hint, this.actions = const []});
  final String title;
  final String value;
  final String hint;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
            const SizedBox(height: 8),
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                ...actions.map((a) => Padding(padding: const EdgeInsets.only(right: 8), child: a)),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('复制'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: value));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
