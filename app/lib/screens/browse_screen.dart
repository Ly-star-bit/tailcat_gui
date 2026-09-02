import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../util/format.dart';
import '../widgets/token_field.dart';
import 'client_session_screen.dart';

/// Lists a remote share and downloads selected entries.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  String _dir = '.';
  List<RemoteEntry>? _entries;
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  Future<void> _list([String? dir]) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(engineProvider).call('list_remote', {'token': _token.text.trim(), 'dir': dir ?? _dir});
      final rows = (res['entries'] as List?) ?? const [];
      setState(() {
        _dir = dir ?? _dir;
        _entries = [for (final r in rows) RemoteEntry.fromJson((r as Map).cast<String, dynamic>())]
          ..sort((a, b) => a.isDir == b.isDir ? a.name.compareTo(b.name) : (a.isDir ? -1 : 1));
        _selected.clear();
      });
    } on EngineException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    var dest = await FilePicker.getDirectoryPath(dialogTitle: '保存到');
    dest ??= (await getDownloadsDirectory())?.path;
    if (dest == null || !mounted) return;
    try {
      final res = await ref.read(engineProvider).call('download', {
        'token': _token.text.trim(),
        'remote_paths': _selected.toList(),
        'local_dir': dest,
      });
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ClientSessionScreen(sessionId: res['session_id'] as String, title: '下载'),
      ));
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('浏览并下载')),
      body: Form(
        key: _form,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TokenField(controller: _token, autofocus: true),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.folder_open),
                    label: const Text('连接并列出文件'),
                    onPressed: _busy ? null : () => _list('.'),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                ],
              ),
            ),
            if (entries != null)
              ListTile(
                dense: true,
                leading: _dir == '.'
                    ? const Icon(Icons.home_outlined)
                    : IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _busy ? null : () => _list(_parent(_dir)),
                      ),
                title: Text('/${_dir == '.' ? '' : _dir}', style: const TextStyle(fontFamily: 'monospace')),
              ),
            if (entries != null)
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('空目录'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          return CheckboxListTile(
                            value: _selected.contains(e.path),
                            onChanged: (v) => setState(() => v == true ? _selected.add(e.path) : _selected.remove(e.path)),
                            secondary: e.isDir
                                ? IconButton(icon: const Icon(Icons.folder), onPressed: _busy ? null : () => _list(e.path))
                                : const Icon(Icons.insert_drive_file_outlined),
                            title: Text(e.name),
                            subtitle: Text(e.isDir ? '文件夹（点击图标进入）' : formatBytes(e.size)),
                          );
                        },
                      ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: entries == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.download),
                  label: Text(_selected.isEmpty ? '勾选要下载的项目' : '下载 ${_selected.length} 项'),
                  onPressed: _selected.isEmpty ? null : _download,
                ),
              ),
            ),
    );
  }

  String _parent(String dir) {
    final i = dir.lastIndexOf('/');
    return i <= 0 ? '.' : dir.substring(0, i);
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }
}
