import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../util/format.dart';
import 'server_screen.dart';

/// `tailcat serve <ports>` / `serve all` / `serve exit-node`.
class SharePortScreen extends ConsumerStatefulWidget {
  const SharePortScreen({super.key});

  @override
  ConsumerState<SharePortScreen> createState() => _SharePortScreenState();
}

class _SharePortScreenState extends ConsumerState<SharePortScreen> {
  final _form = GlobalKey<FormState>();
  final _ports = TextEditingController(text: '8080');
  bool _all = false;
  bool _exitNode = false;
  bool _busy = false;

  Future<void> _start() async {
    if (!_all && !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_server', {
        'ports': _all ? <int>[] : parsePorts(_ports.text),
        'all': _all,
        'exit_node': _exitNode,
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ServerScreen(sessionId: res['session_id'] as String, title: '共享端口'),
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
      appBar: AppBar(title: const Text('共享端口')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('对方连接后，访问自己本地的映射端口就等于访问你这里的端口。'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _ports,
              enabled: !_all,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '本机端口',
                hintText: '例如 8080 或 80, 443, 3000-3005',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                try {
                  if (parsePorts(v ?? '').isEmpty) return '请输入至少一个端口';
                } on FormatException catch (e) {
                  return e.message;
                }
                return null;
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('暴露本机所有端口'),
              subtitle: const Text('等同于 tailcat serve all'),
              value: _all,
              onChanged: (v) => setState(() => _all = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('作为出口节点'),
              subtitle: const Text('允许对方经由本机访问局域网和互联网（配合 SOCKS5）'),
              value: _exitNode,
              onChanged: (v) => setState(() => _exitNode = v),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.qr_code_2),
              label: const Text('生成令牌'),
              onPressed: _busy ? null : _start,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ports.dispose();
    super.dispose();
  }
}
