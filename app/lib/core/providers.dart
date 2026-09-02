import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'engine.dart';
import 'models.dart';

/// Overridden in main() with a started [Engine].
final engineProvider = Provider<Engine>((ref) {
  throw UnimplementedError('engineProvider must be overridden');
});

final capsProvider = FutureProvider<Caps>((ref) => ref.watch(engineProvider).caps());

/// All sessions keyed by id, reduced from engine events.
class SessionsNotifier extends StateNotifier<Map<String, Session>> {
  SessionsNotifier(this._engine) : super(const {}) {
    _sub = _engine.events.listen(_onEvent);
    _seed();
  }

  final Engine _engine;
  StreamSubscription<EngineEvent>? _sub;

  Future<void> _seed() async {
    try {
      final rows = await _engine.listSessions();
      state = {...state, for (final s in rows) s.id: state[s.id] ?? s};
    } catch (_) {}
  }

  void _onEvent(EngineEvent ev) {
    final id = ev.sessionId;
    if (id == null) return;
    final prev = state[id];
    switch (ev) {
      case SessionStateEvent():
        state = {...state, id: Session.fromJson(ev.raw, previous: prev)};
      case TokenReadyEvent():
        if (prev != null) state = {...state, id: prev.copyWith(token: ev.token)};
      case PathEvent():
        if (prev != null) {
          final info = Map<String, dynamic>.from(prev.info);
          if (ev.peers != null) info['peers'] = ev.peers;
          state = {...state, id: prev.copyWith(path: ev.path, info: info)};
        }
      case ErrorEvent():
        if (prev != null) state = {...state, id: prev.copyWith(lastError: ev.message)};
      case LogEvent():
      case ProgressEvent():
      case UnknownEvent():
        break;
    }
  }

  Future<void> stop(String id) => _engine.stop(id);

  void remove(String id) {
    final s = state[id];
    if (s == null || s.state.isActive) return;
    state = {...state}..remove(id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final sessionsProvider = StateNotifierProvider<SessionsNotifier, Map<String, Session>>(
  (ref) => SessionsNotifier(ref.watch(engineProvider)),
);

final sessionProvider = Provider.family<Session?, String>(
  (ref, id) => ref.watch(sessionsProvider)[id],
);

final activeSessionCountProvider = Provider<int>(
  (ref) => ref.watch(sessionsProvider).values.where((s) => s.state.isActive).length,
);

/// Transfers keyed by "sessionId|file".
class TransfersNotifier extends StateNotifier<Map<String, Transfer>> {
  TransfersNotifier(Engine engine) : super(const {}) {
    _sub = engine.events.listen((ev) {
      if (ev is ProgressEvent) {
        final t = ev.transfer;
        state = {...state, t.key: t};
      }
    });
  }
  StreamSubscription<EngineEvent>? _sub;

  void clearFinished() {
    state = {for (final e in state.entries) if (!e.value.done) e.key: e.value};
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final transfersProvider = StateNotifierProvider<TransfersNotifier, Map<String, Transfer>>(
  (ref) => TransfersNotifier(ref.watch(engineProvider)),
);

final sessionTransfersProvider = Provider.family<List<Transfer>, String>((ref, id) {
  return ref.watch(transfersProvider).values.where((t) => t.sessionId == id).toList();
});

/// Last 500 log lines (info and above; debug lines are kept only when
/// [showDebugLogsProvider] is on).
class LogNotifier extends StateNotifier<List<LogLine>> {
  LogNotifier(Engine engine, this._ref) : super(const []) {
    _sub = engine.events.listen((ev) {
      String? msg;
      String level = 'info';
      if (ev is LogEvent) {
        msg = ev.msg;
        level = ev.level;
      } else if (ev is ErrorEvent) {
        msg = ev.message;
        level = 'error';
      }
      if (msg == null) return;
      if (level == 'debug' && !_ref.read(showDebugLogsProvider)) return;
      final next = [...state, LogLine(ts: ev.ts, level: level, msg: msg, sessionId: ev.sessionId)];
      state = next.length > 500 ? next.sublist(next.length - 500) : next;
    });
  }
  final Ref _ref;
  StreamSubscription<EngineEvent>? _sub;

  void clear() => state = const [];

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final showDebugLogsProvider = StateProvider<bool>((_) => false);

final logProvider = StateNotifierProvider<LogNotifier, List<LogLine>>(
  (ref) => LogNotifier(ref.watch(engineProvider), ref),
);
