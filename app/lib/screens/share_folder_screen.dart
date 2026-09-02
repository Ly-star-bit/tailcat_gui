import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'server_screen.dart';

enum ShareFolderMode { receive, share }

/// Starts a file-serving server: a write-only drop box ("receive") or a
/// read-only / read-write share. Desktop may also enable the SSH shell.
class ShareFolderScreen extends ConsumerStatefulWidget {
  const ShareFolderScreen({super.key, required this.mode, this.allowSsh = false});

  final ShareFolderMode mode;
  final bool allowSsh;

  @override
  ConsumerState<ShareFolderScreen> createState() => _ShareFolderScreenState();
}

class _ShareFolderScreenState extends ConsumerState<ShareFolderScreen> {
  String? _dir;
  String _fileMode = 'ro';
  bool _ssh = false;
  bool _busy = false;

  bool get isReceive => widget.mode == ShareFolderMode.receive;

  @override
  void initState() {
    super.initState();
    if (isReceive) _defaultInbox();
  }

  Future<void> _defaultInbox() async {
    try {
      final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      if (mounted) setState(() => _dir ??= base.path);
    } catch (_) {}
  }

  Future<void> _pick() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: isReceive ? '选择接收目录' : '选择要共享的文件夹');
    if (d != null) setState(() => _dir = d);
  }

  Future<void> _start() async {
    final dir = _dir;
    if (dir == null) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_server', {
        'files': {'dir': dir, 'mode': isReceive ? 'wo' : _fileMode},
        'ssh': _ssh,
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ServerScreen(sessionId: res['session_id'] as String, title: isReceive ? '接收文件' : '共享文件夹'),
      ));
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isReceive ? '接收文件' : '共享文件夹')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            isReceive
                ? '对方拿到令牌后可以把文件放进这个目录，但看不到目录里已有的内容。'
                : '对方拿到令牌后可以浏览并下载这个文件夹；选择「可写」则也能上传。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(isReceive ? '接收目录' : '共享目录'),
            subtitle: Text(_dir ?? '未选择'),
            trailing: TextButton(onPressed: _pick, child: const Text('选择')),
          ),
          if (!isReceive) ...[
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ro', label: Text('只读'), icon: Icon(Icons.visibility_outlined)),
                ButtonSegment(value: 'rw', label: Text('可写'), icon: Icon(Icons.edit_outlined)),
              ],
              selected: {_fileMode},
              onSelectionChanged: (s) => setState(() => _fileMode = s.first),
            ),
          ],
          if (widget.allowSsh)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同时开放免密 SSH'),
              subtitle: const Text('任何拿到令牌的人都能以当前用户身份登录本机，仅用于临时调试。'),
              value: _ssh,
              onChanged: (v) => setState(() => _ssh = v),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.qr_code_2),
            label: const Text('生成令牌'),
            onPressed: _dir == null || _busy ? null : _start,
          ),
        ],
      ),
    );
  }
}
