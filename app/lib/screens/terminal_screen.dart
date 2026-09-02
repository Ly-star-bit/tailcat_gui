import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../core/engine.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../util/errors.dart';

/// Tokyo Night, a dark palette that stays readable at small sizes on a
/// phone screen while keeping the 16 ANSI colours distinguishable.
const _bg = Color(0xFF1A1B26);
const _surface = Color(0xFF20222F);
const _border = Color(0xFF2C2E40);
const _fg = Color(0xFFC0CAF5);
const _dim = Color(0xFF7A85B0);
const _accent = Color(0xFF7AA2F7);
const _keyBg = Color(0xFF2A2D3E);

const _terminalTheme = TerminalTheme(
  cursor: Color(0xFFC0CAF5),
  selection: Color(0x8033467C),
  foreground: _fg,
  background: _bg,
  black: Color(0xFF15161E),
  red: Color(0xFFF7768E),
  green: Color(0xFF9ECE6A),
  yellow: Color(0xFFE0AF68),
  blue: Color(0xFF7AA2F7),
  magenta: Color(0xFFBB9AF7),
  cyan: Color(0xFF7DCFFF),
  white: Color(0xFFA9B1D6),
  brightBlack: Color(0xFF414868),
  brightRed: Color(0xFFF7768E),
  brightGreen: Color(0xFF9ECE6A),
  brightYellow: Color(0xFFE0AF68),
  brightBlue: Color(0xFF7AA2F7),
  brightMagenta: Color(0xFFBB9AF7),
  brightCyan: Color(0xFF7DCFFF),
  brightWhite: Color(0xFFC0CAF5),
  searchHitBackground: Color(0xFFE0AF68),
  searchHitBackgroundCurrent: Color(0xFFFF9E64),
  searchHitForeground: Color(0xFF15161E),
);

enum _Phase { connecting, connected, failed, finished }

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
  static const _fontSizeKey = 'terminal_font_size';
  static const _minFont = 9.0;
  static const _maxFont = 22.0;

  late final _keys = TerminalStickyModifiers(defaultInputHandler, onChanged: () => setState(() {}));
  late final _terminal = Terminal(maxLines: 6000, inputHandler: _keys);
  final _controller = TerminalController();
  late final Engine _engine;

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<EngineEvent>? _engineEvents;

  String _title = '';
  String _remoteTitle = '';
  _Phase _phase = _Phase.connecting;
  double _fontSize = 13;

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
        _writeNotice(friendlyError(EngineException(ev.code, ev.message)), error: true);
      } else if (ev is LogEvent && ev.level != 'debug') {
        _writeNotice(ev.msg);
      }
    });
    _title = widget.title;
    _loadFontSize();
    _connect();
  }

  Future<void> _loadFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_fontSizeKey);
      if (v != null && mounted) setState(() => _fontSize = v.clamp(_minFont, _maxFont));
    } catch (_) {}
  }

  Future<void> _setFontSize(double v) async {
    setState(() => _fontSize = v.clamp(_minFont, _maxFont));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontSizeKey, _fontSize);
    } catch (_) {}
  }

  /// Writes an app message into the scrollback, visually distinct from
  /// whatever the remote shell prints.
  void _writeNotice(String msg, {bool error = false}) {
    final color = error ? '\x1b[38;2;247;118;142m' : '\x1b[38;2;122;133;176m';
    _terminal.write('\r\n$color❯ $msg\x1b[0m\r\n');
  }

  Future<void> _connect() async {
    setState(() => _phase = _Phase.connecting);
    _writeNotice('正在连接 127.0.0.1:${widget.localPort}');
    try {
      final socket = await SSHSocket.connect(
        '127.0.0.1',
        widget.localPort,
        timeout: const Duration(seconds: 30),
      );
      // The tunnel already proved who the peer is and the server accepts
      // SSH's "none" method. Passing a password callback would make
      // dartssh2 skip "none" and try password auth, which the server does
      // not offer, so it closes the connection before authentication.
      final client = SSHClient(socket, username: 'tailcat');
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
        if (mounted && t.isNotEmpty) setState(() => _remoteTitle = t);
      };
      const decoder = Utf8Decoder(allowMalformed: true);
      session.stdout.cast<List<int>>().transform(decoder).listen(_terminal.write);
      session.stderr.cast<List<int>>().transform(decoder).listen(_terminal.write);
      unawaited(session.done.whenComplete(() {
        if (!mounted) return;
        _writeNotice('会话已结束');
        setState(() => _phase = _Phase.finished);
      }));

      setState(() => _phase = _Phase.connected);
    } catch (e) {
      if (!mounted) return;
      _writeNotice(friendlyError(e), error: true);
      setState(() => _phase = _Phase.failed);
    }
  }

  void _reconnect() {
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _terminal.buffer.clear();
    _terminal.buffer.setCursor(0, 0);
    _connect();
  }

  /// Sends a raw control byte, e.g. 3 for Ctrl-C.
  void _sendCtrl(int code) => _terminal.textInput(String.fromCharCode(code));

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _terminal.paste(text);
  }

  Future<void> _copySelection() async {
    final range = _controller.selection;
    if (range == null) return;
    final text = _terminal.buffer.getText(range);
    _controller.clearSelection();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  @override
  void dispose() {
    _engineEvents?.cancel();
    _session?.close();
    _client?.close();
    _controller.dispose();
    // The forward exists only for this terminal; free the local port.
    unawaited(_engine.stop(widget.sessionId).catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: base.colorScheme.copyWith(primary: _accent, surface: _surface),
      ),
      child: Scaffold(
        backgroundColor: _bg,
        appBar: _buildAppBar(),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: TerminalView(
                  _terminal,
                  controller: _controller,
                  theme: _terminalTheme,
                  textStyle: TerminalStyle(fontSize: _fontSize, height: 1.25),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  autofocus: true,
                  backgroundOpacity: 0,
                ),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final (dotColor, statusText) = switch (_phase) {
      _Phase.connecting => (const Color(0xFFE0AF68), '正在连接'),
      _Phase.connected => (const Color(0xFF9ECE6A), '已连接 · tailcat@127.0.0.1:${widget.localPort}'),
      _Phase.failed => (const Color(0xFFF7768E), '连接失败'),
      _Phase.finished => (_dim, '会话已结束'),
    };
    return AppBar(
      backgroundColor: _surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleSpacing: 8,
      iconTheme: const IconThemeData(color: _fg),
      shape: const Border(bottom: BorderSide(color: _border)),
      title: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: dotColor.withValues(alpha: 0.5), blurRadius: 6)],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _remoteTitle.isNotEmpty ? _remoteTitle : _title,
                  style: const TextStyle(color: _fg, fontSize: 15, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  statusText,
                  style: const TextStyle(color: _dim, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (_phase == _Phase.finished || _phase == _Phase.failed)
          IconButton(
            tooltip: '重新连接',
            icon: const Icon(Icons.refresh, color: _fg),
            onPressed: _reconnect,
          ),
        PopupMenuButton<String>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert, color: _fg),
          color: _surface,
          onSelected: (v) {
            switch (v) {
              case 'bigger':
                _setFontSize(_fontSize + 1);
              case 'smaller':
                _setFontSize(_fontSize - 1);
              case 'clear':
                _terminal.buffer.clear();
                _terminal.buffer.setCursor(0, 0);
              case 'paste':
                _paste();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'bigger',
              enabled: _fontSize < _maxFont,
              child: const _MenuRow(icon: Icons.text_increase, label: '字号放大'),
            ),
            PopupMenuItem(
              value: 'smaller',
              enabled: _fontSize > _minFont,
              child: const _MenuRow(icon: Icons.text_decrease, label: '字号缩小'),
            ),
            const PopupMenuItem(value: 'paste', child: _MenuRow(icon: Icons.content_paste, label: '粘贴')),
            const PopupMenuItem(value: 'clear', child: _MenuRow(icon: Icons.cleaning_services_outlined, label: '清屏')),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    if (_phase == _Phase.failed) {
      return _BottomStrip(
        child: Row(
          children: [
            const Expanded(
              child: Text('连接失败，可以重试', style: TextStyle(color: _dim, fontSize: 13)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: _bg),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新连接'),
              onPressed: _reconnect,
            ),
          ],
        ),
      );
    }
    if (_phase != _Phase.connected) return const SizedBox.shrink();

    // When text is selected, the key bar makes way for a copy action.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.selection != null) {
          return _BottomStrip(
            child: Row(
              children: [
                const Expanded(child: Text('已选中文本', style: TextStyle(color: _dim, fontSize: 13))),
                TextButton(
                  onPressed: _controller.clearSelection,
                  child: const Text('取消', style: TextStyle(color: _dim)),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: _bg),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                  onPressed: _copySelection,
                ),
              ],
            ),
          );
        }
        return TerminalKeyBar(
          keys: _keys,
          terminal: _terminal,
          sendCtrl: _sendCtrl,
          onPaste: _paste,
        );
      },
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _fg),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: _fg)),
      ],
    );
  }
}

class _BottomStrip extends StatelessWidget {
  const _BottomStrip({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: child,
    );
  }
}

/// The keys a soft keyboard does not offer, grouped: modifiers, common
/// control codes, navigation, then punctuation that is buried on phone
/// keyboards.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.keys,
    required this.terminal,
    required this.sendCtrl,
    required this.onPaste,
  });

  final TerminalStickyModifiers keys;
  final Terminal terminal;
  final void Function(int code) sendCtrl;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            _Key(label: 'Ctrl', active: keys.ctrl, onTap: () => keys.ctrl = !keys.ctrl),
            _Key(label: 'Alt', active: keys.alt, onTap: () => keys.alt = !keys.alt),
            _Key(label: 'Esc', onTap: () => terminal.keyInput(TerminalKey.escape)),
            _Key(label: 'Tab', onTap: () => terminal.keyInput(TerminalKey.tab)),
            const _KeyDivider(),
            _Key(label: '^C', onTap: () => sendCtrl(3)),
            _Key(label: '^D', onTap: () => sendCtrl(4)),
            _Key(label: '^Z', onTap: () => sendCtrl(26)),
            _Key(label: '^L', onTap: () => sendCtrl(12)),
            const _KeyDivider(),
            _Key(icon: Icons.keyboard_arrow_up, onTap: () => terminal.keyInput(TerminalKey.arrowUp)),
            _Key(icon: Icons.keyboard_arrow_down, onTap: () => terminal.keyInput(TerminalKey.arrowDown)),
            _Key(icon: Icons.keyboard_arrow_left, onTap: () => terminal.keyInput(TerminalKey.arrowLeft)),
            _Key(icon: Icons.keyboard_arrow_right, onTap: () => terminal.keyInput(TerminalKey.arrowRight)),
            const _KeyDivider(),
            _Key(label: '|', onTap: () => terminal.textInput('|')),
            _Key(label: '~', onTap: () => terminal.textInput('~')),
            _Key(label: '/', onTap: () => terminal.textInput('/')),
            _Key(label: '-', onTap: () => terminal.textInput('-')),
            const _KeyDivider(),
            _Key(icon: Icons.content_paste, onTap: onPaste),
          ],
        ),
      ),
    );
  }
}

class _KeyDivider extends StatelessWidget {
  const _KeyDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      color: _border,
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.label, this.icon, required this.onTap, this.active = false});

  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: active ? _accent : _keyBg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: icon != null
                ? Icon(icon, size: 18, color: active ? _bg : _fg)
                : Text(
                    label!,
                    style: TextStyle(
                      color: active ? _bg : _fg,
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      fontFamily: 'monospace',
                    ),
                  ),
          ),
        ),
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
