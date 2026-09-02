import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../widgets/token_field.dart';
import 'client_session_screen.dart';

/// Uploads chosen files to the server behind a token.
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key, this.initialToken});

  final String? initialToken;

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  final _form = GlobalKey<FormState>();
  late final _token = TextEditingController(text: widget.initialToken ?? '');
  final _remoteDir = TextEditingController(text: '.');
  final _paths = <String>[];
  bool _busy = false;

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(dialogTitle: '选择要发送的文件');
    setState(() {
      for (final f in files) {
        final p = f.path;
        if (p != null && !_paths.contains(p)) _paths.add(p);
      }
    });
  }

  Future<void> _pickFolder() async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '选择要发送的文件夹');
    if (d != null && !_paths.contains(d)) setState(() => _paths.add(d));
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate() || _paths.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('send_files', {
        'token': _token.text.trim(),
        'paths': _paths,
        'remote_dir': _remoteDir.text.trim().isEmpty ? '.' : _remoteDir.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ClientSessionScreen(sessionId: res['session_id'] as String, title: '发送文件'),
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
      appBar: AppBar(title: const Text('发送文件')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TokenField(controller: _token, autofocus: widget.initialToken == null),
            const SizedBox(height: 16),
            TextFormField(
              controller: _remoteDir,
              decoration: const InputDecoration(labelText: '对方目录（相对共享根目录）', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.attach_file), label: const Text('添加文件')),
                const SizedBox(width: 8),
                OutlinedButton.icon(onPressed: _pickFolder, icon: const Icon(Icons.create_new_folder_outlined), label: const Text('添加文件夹')),
              ],
            ),
            const SizedBox(height: 8),
            for (final p in _paths)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(p, overflow: TextOverflow.ellipsis),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _paths.remove(p))),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(_paths.isEmpty ? '先添加文件' : '发送 ${_paths.length} 项'),
              onPressed: _paths.isEmpty || _busy ? null : _send,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _token.dispose();
    _remoteDir.dispose();
    super.dispose();
  }
}
