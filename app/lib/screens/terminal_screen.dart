import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../core/engine.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../util/errors.dart';

/// An in-app SSH terminal.
///
/// The engine has already forwarded a local port to the peer's port 22, so
/// this connects to 127.0.0.1 and never touches the network itself. The peer
/// authenticated us through the WireGuard tunnel, so the SSH layer needs no
/// password and the host key is irrelevant.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sessionId,
    required this.localPort,
    this.title = 'SSH',
  });

  /// Engine session owning the port forward; stopped when this screen closes.
  final String sessionId;
  final int localPort;
  final String title;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final _keys = TerminalStickyModifiers(defaultInputHandler, onChanged: () => setState(() {}));
  late final Engine _engine;
  late final _terminal = Terminal(maxLines: 4000, inputHandler: _keys);

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<EngineEvent>? _engineEvents;
  String _title = '';
  String? _error;
  bool _connected = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // ref is unusable from dispose(), so keep the engine we need to stop with.
    _engine = ref.read(engineProvider);
    // The tunnel lives in the engine, so its errors explain far more than
    // "connection closed" ever could. Show them inside the terminal.
    _engineEvents = _engine.events.listen((ev) {
      if (ev.sessionId != widget.sessionId) return;
      if (ev is ErrorEvent) {
        _terminal.write('\r\n\x1b[31m${friendlyError(EngineException(ev.code, ev.message))}\x1b[0m\r\n');
      } else if (ev is LogEvent && ev.level != 'debug') {
        _terminal.write('\x1b[90m${ev.msg}\x1b[0m\r\n');
      }
    });
    _title = widget.title;
    _connect();
  }

  Future<void> _connect() async {
    _terminal.write('正在连接 127.0.0.1:${widget.localPort} …\r\n');
    try {
      final socket = await SSHSocket.connect(
        '127.0.0.1',
        widget.localPort,
        timeout: const Duration(seconds: 30),
      );
      // The tunnel already proved who the peer is; tailcat's SSH server
      // accepts the "none" method, so no credentials are exchanged.
      final client = SSHClient(socket, username: 'tailcat', onPasswordRequest: () => '');
      _client = client;

      final session = await client.shell(
        pty: SSHPtyConfig(width: _terminal.viewWidth, height: _terminal.viewHeight),
      );
      if (!mounted) {
        session.close();
        client.close();
        return;
      }
      _session = session;
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _terminal.onOutput = (data) => session.write(utf8.encode(data));
      _terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph);
      _terminal.onTitleChange = (t) {
        if (mounted && t.isNotEmpty) setState(() => _title = t);
      };
      const decoder = Utf8Decoder(allowMalformed: true);
      session.stdout.cast<List<int>>().transform(decoder).listen(_terminal.write);
      session.stderr.cast<List<int>>().transform(decoder).listen(_terminal.write);
      unawaited(session.done.whenComplete(() {
        if (!mounted) return;
        _terminal.write('\r\n\x1b[90m[会话已结束]\x1b[0m\r\n');
        setState(() => _finished = true);
      }));

      setState(() => _connected = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
      _terminal.write('\r\n\x1b[31m${friendlyError(e)}\x1b[0m\r\n');
    }
  }

  /// Sends a raw control byte, e.g. 3 for Ctrl-C.
  void _sendCtrl(int code) => _terminal.textInput(String.fromCharCode(code));

  @override
  void dispose() {
    _engineEvents?.cancel();
    _session?.close();
    _client?.close();
    // The forward exists only for this terminal; free the local port.
    unawaited(_engine.stop(widget.sessionId).catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF12131A),
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_finished)
            IconButton(
              tooltip: '重新连接',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() {
                  _finished = false;
                  _connected = false;
                  _error = null;
                });
                _terminal.buffer.clear();
                _connect();
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                color: theme.colorScheme.errorContainer,
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            Expanded(
              child: TerminalView(
                _terminal,
                autofocus: true,
                backgroundOpacity: 0,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
            if (_connected) _KeyBar(keys: _keys, terminal: _terminal, sendCtrl: _sendCtrl),
          ],
        ),
      ),
    );
  }
}

/// Keys a soft keyboard does not offer: Esc, Tab, Ctrl and the arrows.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.keys, required this.terminal, required this.sendCtrl});

  final TerminalStickyModifiers keys;
  final Terminal terminal;
  final void Function(int code) sendCtrl;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1D1F29),
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            _key('Esc', onTap: () => terminal.keyInput(TerminalKey.escape)),
            _key('Tab', onTap: () => terminal.keyInput(TerminalKey.tab)),
            _key('Ctrl', active: keys.ctrl, onTap: () => keys.ctrl = !keys.ctrl),
            _key('Alt', active: keys.alt, onTap: () => keys.alt = !keys.alt),
            _key('^C', onTap: () => sendCtrl(3)),
            _key('^D', onTap: () => sendCtrl(4)),
            _key('^Z', onTap: () => sendCtrl(26)),
            _key('^L', onTap: () => sendCtrl(12)),
            _iconKey(Icons.arrow_upward, () => terminal.keyInput(TerminalKey.arrowUp)),
            _iconKey(Icons.arrow_downward, () => terminal.keyInput(TerminalKey.arrowDown)),
            _iconKey(Icons.arrow_back, () => terminal.keyInput(TerminalKey.arrowLeft)),
            _iconKey(Icons.arrow_forward, () => terminal.keyInput(TerminalKey.arrowRight)),
            _key('|', onTap: () => terminal.textInput('|')),
            _key('~', onTap: () => terminal.textInput('~')),
            _key('/', onTap: () => terminal.textInput('/')),
            _key('-', onTap: () => terminal.textInput('-')),
          ],
        ),
      ),
    );
  }

  Widget _key(String label, {required VoidCallback onTap, bool active = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: active ? Colors.white24 : Colors.white10,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }

  Widget _iconKey(IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 32),
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white10,
          foregroundColor: Colors.white,
        ),
        onPressed: onTap,
        child: Icon(icon, size: 16),
      ),
    );
  }
}

/// Ctrl and Alt as one-shot modifiers: tap Ctrl, then a letter, and the
/// letter is delivered as a control sequence. A soft keyboard has no
/// modifier keys of its own, so the terminal has to fake them.
class TerminalStickyModifiers implements TerminalInputHandler {
  TerminalStickyModifiers(this._inner, {this.onChanged});

  final TerminalInputHandler _inner;
  final VoidCallback? onChanged;

  bool _ctrl = false;
  bool _alt = false;

  bool get ctrl => _ctrl;
  set ctrl(bool v) {
    _ctrl = v;
    onChanged?.call();
  }

  bool get alt => _alt;
  set alt(bool v) {
    _alt = v;
    onChanged?.call();
  }

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!_ctrl && !_alt) return _inner(event);
    final out = _inner(event.copyWith(
      ctrl: _ctrl || event.ctrl,
      alt: _alt || event.alt,
    ));
    _ctrl = false;
    _alt = false;
    onChanged?.call();
    return out;
  }
}
