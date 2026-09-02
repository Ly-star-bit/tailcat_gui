import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../widgets/token_field.dart';
import 'client_session_screen.dart';

/// Local listener forwarding to a remote port on the token's server.
class ConnectPortScreen extends ConsumerStatefulWidget {
  const ConnectPortScreen({super.key});

  @override
  ConsumerState<ConnectPortScreen> createState() => _ConnectPortScreenState();
}

class _ConnectPortScreenState extends ConsumerState<ConnectPortScreen> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  final _remote = TextEditingController(text: '8080');
  final _local = TextEditingController(text: '9000');
  bool _bindAll = false;
  bool _busy = false;

  Future<void> _start() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_forward', {
        'token': _token.text.trim(),
        'remote_port': int.parse(_remote.text.trim()),
        'local_port': int.tryParse(_local.text.trim()) ?? 0,
        'bind_all': _bindAll,
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ClientSessionScreen(sessionId: res['session_id'] as String, title: '连接端口'),
      ));
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _port(String? v, {bool allowZero = false}) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < (allowZero ? 0 : 1) || n > 65535) return '端口应为 ${allowZero ? 0 : 1}-65535';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接端口')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TokenField(controller: _token, autofocus: true),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _remote,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '对方端口', border: OutlineInputBorder()),
                    validator: _port,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _local,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '本机端口（0=随机）', border: OutlineInputBorder()),
                    validator: (v) => _port(v, allowZero: true),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许局域网内其他设备访问本机端口'),
              subtitle: const Text('监听 0.0.0.0 而非 127.0.0.1'),
              value: _bindAll,
              onChanged: (v) => setState(() => _bindAll = v),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cable),
              label: const Text('开始映射'),
              onPressed: _busy ? null : _start,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _token.dispose();
    _remote.dispose();
    _local.dispose();
    super.dispose();
  }
}
