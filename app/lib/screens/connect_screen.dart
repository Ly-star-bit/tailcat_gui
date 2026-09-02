import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/probe.dart';
import '../core/providers.dart';
import '../core/recent.dart';
import '../util/errors.dart';
import '../widgets/token_field.dart';
import 'peer_screen.dart';

/// Paste a token, we find out what it offers, then show the actions.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key, this.initialToken, this.autoConnect = false});

  final String? initialToken;
  final bool autoConnect;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _form = GlobalKey<FormState>();
  late final _token = TextEditingController(text: widget.initialToken ?? '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect && (widget.initialToken ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    final token = _token.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final raw = await ref.read(engineProvider).call('probe', {'token': token});
      final probe = ProbeResult.fromJson(raw);
      await ref.read(recentPeersProvider.notifier).touch(token, probe.displayName);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PeerScreen(token: token, probe: probe),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('粘贴对方给你的令牌（或扫描二维码）。连接后会自动显示对方分享了什么。'),
            const SizedBox(height: 16),
            TokenField(controller: _token, autofocus: !widget.autoConnect),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: Text(_busy ? '正在连接…' : '连接'),
              onPressed: _busy ? null : _connect,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }
}
