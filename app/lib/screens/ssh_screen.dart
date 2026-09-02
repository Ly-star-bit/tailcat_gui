import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../platform/terminal_launcher.dart';
import '../widgets/token_field.dart';
import 'client_session_screen.dart';

/// Desktop only: forwards a local port to the server's SSH and hands the
/// command to the system terminal.
class SshScreen extends ConsumerStatefulWidget {
  const SshScreen({super.key});

  @override
  ConsumerState<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends ConsumerState<SshScreen> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  bool _busy = false;
  bool _openTerminal = true;

  Future<void> _start() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(engineProvider).call('start_ssh_forward', {'token': _token.text.trim()});
      final cmd = res['command'] as String;
      if (_openTerminal) await openTerminalWith(cmd);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ClientSessionScreen(sessionId: res['session_id'] as String, title: 'SSH', sshCommand: cmd),
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
      appBar: AppBar(title: const Text('SSH 登录')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('对方需要在「共享文件夹」里开启免密 SSH（或用命令行 tailcat serve no-auth-ssh）。'),
            const SizedBox(height: 16),
            TokenField(controller: _token, autofocus: true),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('连接后自动打开系统终端'),
              value: _openTerminal,
              onChanged: (v) => setState(() => _openTerminal = v),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.terminal),
              label: const Text('连接'),
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
    super.dispose();
  }
}
