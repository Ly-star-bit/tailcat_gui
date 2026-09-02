import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../widgets/token_field.dart';
import 'client_session_screen.dart';

/// `tailcat socks --listen <port> <token>`.
class SocksScreen extends ConsumerStatefulWidget {
  const SocksScreen({super.key});

  @override
  ConsumerState<SocksScreen> createState() => _SocksScreenState();
}

class _SocksScreenState extends ConsumerState<SocksScreen> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  final _listen = TextEditingController(text: '12000');
  bool _busy = false;

  Future<void> _start() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_socks', {
        'token': _token.text.trim(),
        'listen': _listen.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ClientSessionScreen(sessionId: res['session_id'] as String, title: 'SOCKS5 代理'),
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
      appBar: AppBar(title: const Text('SOCKS5 代理')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('对方需要以「作为出口节点」或「暴露所有端口」方式共享。本机会开一个 SOCKS5 端口，流量经加密隧道从对方网络发出。'),
            const SizedBox(height: 16),
            TokenField(controller: _token, autofocus: true),
            const SizedBox(height: 16),
            TextFormField(
              controller: _listen,
              decoration: const InputDecoration(
                labelText: '本机监听',
                hintText: '12000 或 0.0.0.0:12000',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? '请输入端口' : null,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.vpn_lock),
              label: const Text('启动代理'),
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
    _listen.dispose();
    super.dispose();
  }
}
