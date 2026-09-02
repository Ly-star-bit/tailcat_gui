import 'dart:async';
import 'dart:convert';

import 'core_backend.dart';
import 'models.dart';

/// Typed façade over [CoreBackend]: JSON envelopes in, typed results and a
/// broadcast event stream out. Polls the core for events on a timer that
/// runs fast while sessions are active and slowly otherwise.
class Engine {
  Engine(this.backend, {this.activeInterval = const Duration(milliseconds: 150), this.idleInterval = const Duration(seconds: 1)});

  final CoreBackend backend;
  final Duration activeInterval;
  final Duration idleInterval;

  final _events = StreamController<EngineEvent>.broadcast();
  final _active = <String>{};
  Timer? _timer;
  bool _started = false;

  Stream<EngineEvent> get events => _events.stream;
  bool get hasActiveSessions => _active.isNotEmpty;
  String get version => backend.version;

  Future<void> start() async {
    if (_started) return;
    await backend.init();
    _started = true;
    _schedule();
  }

  /// Sends one command. Throws [EngineException] on `ok:false`.
  Future<Map<String, dynamic>> call(String op, [Map<String, dynamic> args = const {}]) async {
    final raw = await backend.call(jsonEncode({'op': op, 'args': args}));
    final m = jsonDecode(raw) as Map<String, dynamic>;
    if (m['ok'] == true) {
      final r = m['result'];
      pump();
      return r is Map<String, dynamic> ? r : <String, dynamic>{};
    }
    final err = (m['error'] as Map?)?.cast<String, dynamic>() ?? const {};
    throw EngineException(
      (err['code'] as String?) ?? 'internal',
      (err['message'] as String?) ?? 'unknown error',
    );
  }

  Future<Caps> caps() async => Caps.fromJson(await call('get_caps'));

  Future<List<Session>> listSessions() async {
    final r = await call('list_sessions');
    final rows = (r['sessions'] as List?) ?? const [];
    return [for (final row in rows) Session.fromJson((row as Map).cast<String, dynamic>())];
  }

  Future<void> stop(String sessionId) => call('stop', {'session_id': sessionId});

  /// Drains events from the core now and re-arms the timer.
  void pump() {
    if (!_started) return;
    List<dynamic> list;
    try {
      final m = jsonDecode(backend.poll()) as Map<String, dynamic>;
      list = (m['events'] as List?) ?? const [];
    } catch (_) {
      list = const [];
    }
    for (final raw in list) {
      final ev = EngineEvent.fromJson((raw as Map).cast<String, dynamic>());
      if (ev is SessionStateEvent && ev.sessionId != null) {
        if (ev.state.isActive) {
          _active.add(ev.sessionId!);
        } else {
          _active.remove(ev.sessionId!);
        }
      }
      _events.add(ev);
    }
    _schedule();
  }

  void _schedule() {
    final want = hasActiveSessions ? activeInterval : idleInterval;
    if (_timer != null && _timer!.isActive && _currentInterval == want) return;
    _timer?.cancel();
    _currentInterval = want;
    _timer = Timer.periodic(want, (_) => pump());
  }

  Duration? _currentInterval;

  void dispose() {
    _timer?.cancel();
    _events.close();
    if (_started) backend.shutdown();
  }
}
