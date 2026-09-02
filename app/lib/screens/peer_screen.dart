import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/probe.dart';
import '../core/providers.dart';
import '../platform/platform_caps.dart';
import '../platform/terminal_launcher.dart';
import '../util/errors.dart';
import '../util/format.dart';
import 'browse_screen.dart';
import 'client_session_screen.dart';

/// What the other side offers, as actions. Built from a [ProbeResult].
class PeerScreen extends ConsumerStatefulWidget {
  const PeerScreen({super.key, required this.token, required this.probe});

  final String token;
  final ProbeResult probe;

  @override
  ConsumerState<PeerScreen> createState() => _PeerScreenState();
}

class _PeerScreenState extends ConsumerState<PeerScreen> {
  final _manualPort = TextEditingController();
  String? _busyAction;

  ProbeResult get p => widget.probe;

  Future<void> _run(String action, Future<void> Function() body) async {
    setState(() => _busyAction = action);
    try {
      await body();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<String?> _pickDest() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '保存到');
    if (d != null) return d;
    try {
      return (await getDownloadsDirectory())?.path ?? (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  Future<void> _receiveAll() => _run('receive', () async {
        final dest = await _pickDest();
        if (dest == null) return;
        final res = await ref.read(engineProvider).call('download', {
          'token': widget.token,
          'remote_paths': ['.'],
          'local_dir': dest,
        });
        if (mounted) _open(ClientSessionScreen(sessionId: res['session_id'] as String, title: '接收文件'));
      });

  Future<void> _sendFiles() => _run('send', () async {
        final files = await FilePicker.pickFiles(dialogTitle: '选择要发送的文件');
        final paths = [for (final f in files) if (f.path != null) f.path!];
        if (paths.isEmpty) return;
        final res = await ref.read(engineProvider).call('send_files', {
          'token': widget.token,
          'paths': paths,
          'remote_dir': '.',
        });
        if (mounted) _open(ClientSessionScreen(sessionId: res['session_id'] as String, title: '发送文件'));
      });

  Future<void> _forward(int remotePort) => _run('port-$remotePort', () async {
        final res = await ref.read(engineProvider).call('start_forward', {
          'token': widget.token,
          'remote_port': remotePort,
          'local_port': remotePort, // same number when free, else random
        }).catchError((Object e) async {
          if (friendlyError(e).contains('占用')) {
            return ref.read(engineProvider).call('start_forward', {
              'token': widget.token,
              'remote_port': remotePort,
              'local_port': 0,
            });
          }
          throw e;
        });
        if (mounted) _open(ClientSessionScreen(sessionId: res['session_id'] as String, title: '端口 $remotePort'));
      });

  Future<void> _socks() => _run('socks', () async {
        Map<String, dynamic> res;
        try {
          res = await ref.read(engineProvider).call('start_socks', {'token': widget.token, 'listen': '1080'});
        } catch (e) {
          if (!friendlyError(e).contains('占用')) rethrow;
          res = await ref.read(engineProvider).call('start_socks', {'token': widget.token, 'listen': '0'});
        }
        if (mounted) _open(ClientSessionScreen(sessionId: res['session_id'] as String, title: 'SOCKS5 代理'));
      });

  Future<void> _ssh() => _run('ssh', () async {
        final res = await ref.read(engineProvider).call('start_ssh_forward', {'token': widget.token});
        final cmd = res['command'] as String;
        await openTerminalWith(cmd);
        if (mounted) _open(ClientSessionScreen(sessionId: res['session_id'] as String, title: 'SSH', sshCommand: cmd));
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m = p.manifest;
    final items = p.offeredItems;
    final total = items.fold<int>(0, (s, i) => s + i.size);

    return Scaffold(
      appBar: AppBar(title: Text(p.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: cs.primaryContainer,
                child: Icon(_platformIcon(m?.platform), color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.displayName, style: theme.textTheme.titleLarge),
                    Text(
                      p.isDirect ? '直连 · ${formatLatency(p.latencyMs)}' : '经中继 ${p.detail} · ${formatLatency(p.latencyMs)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- files handed to us ----
          if (items.isNotEmpty)
            _ActionCard(
              icon: Icons.download_rounded,
              title: '对方发来 ${items.length} 项文件${total > 0 ? '（${formatBytes(total)}）' : ''}',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final i in items.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Icon(i.isDir ? Icons.folder : Icons.insert_drive_file_outlined, size: 16),
                          const SizedBox(width: 6),
                          Expanded(child: Text(i.name, overflow: TextOverflow.ellipsis)),
                          if (!i.isDir) Text(formatBytes(i.size), style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  if (items.length > 8) Text('…还有 ${items.length - 8} 项', style: theme.textTheme.bodySmall),
                ],
              ),
              actions: [
                FilledButton.icon(
                  icon: _spinnerOr('receive', Icons.download),
                  label: const Text('全部接收'),
                  onPressed: _busyAction == null ? _receiveAll : null,
                ),
                OutlinedButton(
                  onPressed: () => _open(BrowseScreen(initialToken: widget.token)),
                  child: const Text('挑选'),
                ),
              ],
            )
          else if (p.canBrowse)
            _ActionCard(
              icon: Icons.folder_shared_outlined,
              title: m?.files?.dir.isNotEmpty == true ? '对方共享了文件夹「${m!.files!.dir}」' : '对方共享了文件',
              body: Text(p.canSendFiles ? '可以浏览下载，也可以上传。' : '只读：可以浏览和下载。', style: theme.textTheme.bodySmall),
              actions: [
                FilledButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('浏览并下载'),
                  onPressed: () => _open(BrowseScreen(initialToken: widget.token)),
                ),
                if (p.canSendFiles)
                  OutlinedButton.icon(
                    icon: _spinnerOr('send', Icons.upload),
                    label: const Text('发送文件'),
                    onPressed: _busyAction == null ? _sendFiles : null,
                  ),
              ],
            )
          else if (p.canSendFiles)
            _ActionCard(
              icon: Icons.upload_rounded,
              title: '对方在等待接收文件',
              body: Text('选择文件后会直接传到对方指定的目录。', style: theme.textTheme.bodySmall),
              actions: [
                FilledButton.icon(
                  icon: _spinnerOr('send', Icons.upload),
                  label: const Text('发送文件'),
                  onPressed: _busyAction == null ? _sendFiles : null,
                ),
              ],
            ),

          // ---- ports ----
          if (p.knownPorts.isNotEmpty || p.allPorts)
            _ActionCard(
              icon: Icons.lan_outlined,
              title: p.allPorts ? '对方开放了所有端口' : '对方开放了 ${p.knownPorts.length} 个端口',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final port in p.knownPorts)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('端口 $port'),
                      subtitle: Text('映射后在本机访问 localhost:$port', style: theme.textTheme.bodySmall),
                      trailing: FilledButton.tonalIcon(
                        icon: _spinnerOr('port-$port', Icons.cable, small: true),
                        label: const Text('映射到本机'),
                        onPressed: _busyAction == null ? () => _forward(port) : null,
                      ),
                    ),
                  if (p.allPorts) _manualForwardRow(),
                ],
              ),
            ),

          // ---- socks ----
          if (p.canSocks)
            _ActionCard(
              icon: Icons.vpn_lock_outlined,
              title: m?.exitNode == true ? '可以通过对方的网络上网' : '可以用 SOCKS5 访问对方的所有端口',
              body: Text('在本机开一个 SOCKS5 代理端口，浏览器或工具指向它即可。', style: theme.textTheme.bodySmall),
              actions: [
                FilledButton.icon(
                  icon: _spinnerOr('socks', Icons.vpn_lock),
                  label: const Text('开启 SOCKS5 代理'),
                  onPressed: _busyAction == null ? _socks : null,
                ),
              ],
            ),

          // ---- ssh ----
          if (p.canSsh && PlatformCaps.hasSystemSsh)
            _ActionCard(
              icon: Icons.terminal,
              title: '对方允许 SSH 登录',
              body: Text('用系统终端打开一个免密 SSH 会话。', style: theme.textTheme.bodySmall),
              actions: [
                FilledButton.icon(
                  icon: _spinnerOr('ssh', Icons.terminal),
                  label: const Text('SSH 登录'),
                  onPressed: _busyAction == null ? _ssh : null,
                ),
              ],
            ),

          // ---- CLI fallback / advanced ----
          if (p.cliFallback || !p.hasKnownServices)
            _ActionCard(
              icon: Icons.tune,
              title: p.cliFallback ? '对方用的是命令行 tailcat' : '对方没有声明任何服务',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('无法自动得知开放了哪些端口。如果知道端口号，可以手动映射。', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  _manualForwardRow(),
                ],
              ),
              actions: [
                if (!p.canSocks)
                  OutlinedButton.icon(
                    icon: _spinnerOr('socks', Icons.vpn_lock),
                    label: const Text('尝试 SOCKS5'),
                    onPressed: _busyAction == null ? _socks : null,
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text('令牌：${widget.token}', style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _manualForwardRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _manualPort,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '对方端口', isDense: true, border: OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(
          onPressed: _busyAction == null
              ? () {
                  final port = int.tryParse(_manualPort.text.trim());
                  if (port == null || port < 1 || port > 65535) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('端口应为 1-65535')));
                    return;
                  }
                  _forward(port);
                }
              : null,
          child: const Text('映射'),
        ),
      ],
    );
  }

  Widget _spinnerOr(String action, IconData icon, {bool small = false}) {
    if (_busyAction != action) return Icon(icon, size: small ? 18 : null);
    return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
  }

  IconData _platformIcon(String? platform) => switch (platform) {
        'android' => Icons.phone_android,
        'darwin' => Icons.laptop_mac,
        'windows' => Icons.laptop_windows,
        'linux' => Icons.dns_outlined,
        _ => Icons.devices_other,
      };

  @override
  void dispose() {
    _manualPort.dispose();
    super.dispose();
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.body, this.actions = const []});
  final IconData icon;
  final String title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            body,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
