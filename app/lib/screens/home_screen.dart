import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/recent.dart';
import 'connect_screen.dart';
import 'sessions_screen.dart';
import 'share_screen.dart';

/// Two things to do: share, or connect. Plus a clipboard shortcut and the
/// peers you talked to before.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  String? _clipboardToken;
  String? _dismissedToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkClipboard();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      final token = text.replaceFirst('tailcat=', '');
      final looksLikeToken = token.startsWith('tc') && token.length > 40 && !token.contains(' ');
      if (!mounted) return;
      setState(() => _clipboardToken = looksLikeToken && token != _dismissedToken ? token : null);
    } catch (_) {}
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final active = ref.watch(activeSessionCountProvider);
    final caps = ref.watch(capsProvider).valueOrNull;
    final recents = ref.watch(recentPeersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tailcat'),
        actions: [
          IconButton(
            tooltip: '会话与日志',
            icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.list_alt)),
            onPressed: () => _push(const SessionsScreen()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_clipboardToken != null)
            Card(
              color: cs.tertiaryContainer,
              child: ListTile(
                leading: Icon(Icons.content_paste, color: cs.onTertiaryContainer),
                title: Text('剪贴板里有一个令牌', style: TextStyle(color: cs.onTertiaryContainer)),
                subtitle: Text(_short(_clipboardToken!), style: TextStyle(color: cs.onTertiaryContainer, fontFamily: 'monospace')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      onPressed: () => _push(ConnectScreen(initialToken: _clipboardToken, autoConnect: true)),
                      child: const Text('连接'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _dismissedToken = _clipboardToken;
                        _clipboardToken = null;
                      }),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _BigButton(
                  icon: Icons.ios_share,
                  title: '分享',
                  subtitle: '文件、文件夹、端口或网络\n生成一个令牌给对方',
                  onTap: () => _push(const ShareScreen()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigButton(
                  icon: Icons.link,
                  title: '连接',
                  subtitle: '输入或扫描对方的令牌\n自动显示能做什么',
                  onTap: () => _push(const ConnectScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('发送文件'),
                onPressed: () => _push(const ShareScreen(initialFileMode: 'send')),
              ),
              ActionChip(
                avatar: const Icon(Icons.download_rounded, size: 18),
                label: const Text('接收文件'),
                onPressed: () => _push(const ShareScreen(initialFileMode: 'receive')),
              ),
              ActionChip(
                avatar: const Icon(Icons.folder_shared_outlined, size: 18),
                label: const Text('共享文件夹'),
                onPressed: () => _push(const ShareScreen(initialFileMode: 'folder')),
              ),
            ],
          ),
          if (recents.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('最近连接', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final r in recents.take(8))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text(r.label),
                subtitle: Text('${_short(r.token)} · ${_ago(r.lastMs)}', style: theme.textTheme.bodySmall),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'rename') {
                      final alias = await _askAlias(context, r.label);
                      if (alias != null) ref.read(recentPeersProvider.notifier).rename(r.token, alias);
                    } else if (v == 'remove') {
                      ref.read(recentPeersProvider.notifier).remove(r.token);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'remove', child: Text('删除')),
                  ],
                ),
                onTap: () => _push(ConnectScreen(initialToken: r.token, autoConnect: true)),
              ),
          ],
        ],
      ),
      bottomNavigationBar: caps == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'core ${caps.version} · tailcat ${caps.tailcat} · ${caps.platform}/${caps.arch}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
    );
  }

  static String _short(String t) => t.length <= 24 ? t : '${t.substring(0, 12)}…${t.substring(t.length - 8)}';

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Future<String?> _askAlias(BuildContext context, String current) {
    final c = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('保存')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: cs.primaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 36, color: cs.onPrimaryContainer),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: cs.onPrimaryContainer)),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onPrimaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}
