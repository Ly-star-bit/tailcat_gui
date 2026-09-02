import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/providers.dart';
import '../util/errors.dart';
import '../util/format.dart';
import 'server_screen.dart';

enum _FileMode { none, send, folder, receive }

/// One screen, one token: pick what to hand out (files, a folder, an inbox,
/// ports, exit node, SSH) and generate a single token for all of it.
class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({super.key, this.initialFileMode});

  /// Preselects the file section (home shortcuts use this).
  final String? initialFileMode;

  @override
  ConsumerState<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends ConsumerState<ShareScreen> {
  _FileMode _fileMode = _FileMode.none;
  final _paths = <String>[];
  String? _folder;
  bool _folderWritable = false;
  String? _inbox;
  final _ports = TextEditingController();
  bool _allPorts = false;
  bool _exitNode = false;
  bool _ssh = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fileMode = switch (widget.initialFileMode) {
      'send' => _FileMode.send,
      'folder' => _FileMode.folder,
      'receive' => _FileMode.receive,
      _ => _FileMode.none,
    };
    if (_fileMode == _FileMode.receive) _defaultInbox();
  }

  Future<void> _defaultInbox() async {
    try {
      final d = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      if (mounted) setState(() => _inbox ??= d.path);
    } catch (_) {}
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(dialogTitle: '选择要发送的文件');
    setState(() {
      for (final f in files) {
        final p = f.path;
        if (p != null && !_paths.contains(p)) _paths.add(p);
      }
    });
  }

  Future<void> _pickFolderToSend() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '选择要发送的文件夹');
    if (d != null && !_paths.contains(d)) setState(() => _paths.add(d));
  }

  bool get _ready {
    final files = switch (_fileMode) {
      _FileMode.none => false,
      _FileMode.send => _paths.isNotEmpty,
      _FileMode.folder => _folder != null,
      _FileMode.receive => _inbox != null,
    };
    final ports = _allPorts || _ports.text.trim().isNotEmpty;
    return files || ports || _exitNode || _ssh;
  }

  Future<void> _start() async {
    List<int> ports = const [];
    if (!_allPorts && _ports.text.trim().isNotEmpty) {
      try {
        ports = parsePorts(_ports.text);
      } on FormatException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        return;
      }
    }
    final args = <String, dynamic>{
      'ports': ports,
      'all': _allPorts,
      'exit_node': _exitNode,
      'ssh': _ssh,
    };
    switch (_fileMode) {
      case _FileMode.send:
        args['share_paths'] = _paths;
      case _FileMode.folder:
        args['files'] = {'dir': _folder, 'mode': _folderWritable ? 'rw' : 'ro'};
      case _FileMode.receive:
        args['files'] = {'dir': _inbox, 'mode': 'wo'};
      case _FileMode.none:
        break;
    }
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_server', args);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ServerScreen(sessionId: res['session_id'] as String, title: '分享中'),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(capsProvider).valueOrNull;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('分享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('勾选要给对方的东西，生成一个令牌。对方输入令牌后会自动看到这些内容。', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          _Section(
            title: '文件',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<_FileMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _FileMode.none, label: Text('不共享')),
                    ButtonSegment(value: _FileMode.send, label: Text('发送文件')),
                    ButtonSegment(value: _FileMode.folder, label: Text('共享文件夹')),
                    ButtonSegment(value: _FileMode.receive, label: Text('接收文件')),
                  ],
                  selected: {_fileMode},
                  onSelectionChanged: (s) {
                    setState(() => _fileMode = s.first);
                    if (_fileMode == _FileMode.receive && _inbox == null) _defaultInbox();
                  },
                ),
                const SizedBox(height: 8),
                switch (_fileMode) {
                  _FileMode.none => const SizedBox.shrink(),
                  _FileMode.send => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('对方输入令牌后可以一键接收这些文件。', style: theme.textTheme.bodySmall),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.attach_file), label: const Text('添加文件')),
                            OutlinedButton.icon(onPressed: _pickFolderToSend, icon: const Icon(Icons.create_new_folder_outlined), label: const Text('添加文件夹')),
                          ],
                        ),
                        for (final p in _paths)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.insert_drive_file_outlined),
                            title: Text(p.split('/').last, overflow: TextOverflow.ellipsis),
                            subtitle: Text(p, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _paths.remove(p))),
                          ),
                      ],
                    ),
                  _FileMode.folder => Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(_folder ?? '选择要共享的文件夹'),
                          trailing: TextButton(
                            onPressed: () async {
                              final d = await FilePicker.getDirectoryPath(dialogTitle: '选择要共享的文件夹');
                              if (d != null) setState(() => _folder = d);
                            },
                            child: const Text('选择'),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('允许对方上传和修改'),
                          value: _folderWritable,
                          onChanged: (v) => setState(() => _folderWritable = v),
                        ),
                      ],
                    ),
                  _FileMode.receive => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.download_outlined),
                      title: const Text('收到的文件放到'),
                      subtitle: Text(_inbox ?? '…'),
                      trailing: TextButton(
                        onPressed: () async {
                          final d = await FilePicker.getDirectoryPath(dialogTitle: '选择接收目录');
                          if (d != null) setState(() => _inbox = d);
                        },
                        child: const Text('更改'),
                      ),
                    ),
                },
              ],
            ),
          ),
          _Section(
            title: '端口与网络',
            child: Column(
              children: [
                TextField(
                  controller: _ports,
                  enabled: !_allPorts,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '本机端口（可选）',
                    hintText: '例如 8080 或 80, 443, 3000-3005',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本机所有端口'),
                  value: _allPorts,
                  onChanged: (v) => setState(() => _allPorts = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('让对方通过我的网络上网'),
                  subtitle: const Text('出口节点：对方可用 SOCKS5 代理访问我这边的局域网和互联网'),
                  value: _exitNode,
                  onChanged: (v) => setState(() => _exitNode = v),
                ),
                if (caps?.sshServer ?? false)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('免密 SSH 登录'),
                    subtitle: const Text('拿到令牌的人可以用当前用户身份登录本机，仅限临时调试'),
                    value: _ssh,
                    onChanged: (v) => setState(() => _ssh = v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.qr_code_2),
            label: const Text('生成令牌'),
            onPressed: _ready && !_busy ? _start : null,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ports.dispose();
    super.dispose();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
