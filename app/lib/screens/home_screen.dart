import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../platform/platform_caps.dart';
import 'browse_screen.dart';
import 'connect_port_screen.dart';
import 'send_screen.dart';
import 'sessions_screen.dart';
import 'share_folder_screen.dart';
import 'share_port_screen.dart';
import 'socks_screen.dart';
import 'ssh_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionCountProvider);
    final caps = ref.watch(capsProvider).valueOrNull;
    final sshServer = caps?.sshServer ?? false;

    final actions = <_Action>[
      _Action('接收文件', '生成令牌，让对方把文件发给我', Icons.download_rounded,
          () => const ShareFolderScreen(mode: ShareFolderMode.receive)),
      _Action('发送文件', '输入对方令牌，把文件发过去', Icons.upload_rounded, () => const SendScreen()),
      _Action('共享文件夹', '生成令牌，让对方浏览并下载我的文件', Icons.folder_shared_outlined,
          () => ShareFolderScreen(mode: ShareFolderMode.share, allowSsh: sshServer)),
      _Action('浏览并下载', '输入对方令牌，取回对方共享的文件', Icons.folder_open_outlined, () => const BrowseScreen()),
      _Action('共享端口', '把本机端口（如 8080）暴露给对方', Icons.lan_outlined, () => const SharePortScreen()),
      _Action('连接端口', '在本机开一个端口，映射到对方端口', Icons.cable, () => const ConnectPortScreen()),
      _Action('SOCKS5 代理', '通过对方的网络访问其内网或互联网', Icons.vpn_lock_outlined, () => const SocksScreen()),
      if (PlatformCaps.hasSystemSsh) _Action('SSH 登录', '输入令牌，用系统 ssh 登录对方机器', Icons.terminal, () => const SshScreen()),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tailcat'),
        actions: [
          IconButton(
            tooltip: '会话与日志',
            icon: Badge(
              isLabelVisible: active > 0,
              label: Text('$active'),
              child: const Icon(Icons.list_alt),
            ),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionsScreen())),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final cols = c.maxWidth > 900 ? 3 : c.maxWidth > 560 ? 2 : 1;
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisExtent: 96,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: actions.length,
            itemBuilder: (context, i) => _ActionCard(action: actions[i]),
          );
        },
      ),
      bottomNavigationBar: caps == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'core ${caps.version} · tailcat ${caps.tailcat} · ${caps.platform}/${caps.arch}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
    );
  }
}

class _Action {
  const _Action(this.title, this.subtitle, this.icon, this.build);
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() build;
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action});
  final _Action action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => action.build())),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(backgroundColor: cs.primaryContainer, child: Icon(action.icon, color: cs.onPrimaryContainer)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(action.title, style: Theme.of(context).textTheme.titleMedium),
                    Text(action.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
