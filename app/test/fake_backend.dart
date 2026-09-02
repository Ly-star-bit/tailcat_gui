import 'dart:convert';

import 'package:tailcat_gui/core/core_backend.dart';

/// Scripted backend: canned responses per op plus an event queue tests can
/// push into, so the UI and providers run without the native library.
class FakeCoreBackend implements CoreBackend {
  FakeCoreBackend({Map<String, dynamic>? caps})
      : responses = {
          'get_caps': {
            'platform': 'darwin',
            'arch': 'arm64',
            'version': 'test',
            'tailcat': 'v0.4.0',
            'ssh_server': true,
            ...?caps,
          },
          'list_sessions': {'sessions': <dynamic>[]},
        };

  final Map<String, dynamic> responses;
  final List<Map<String, dynamic>> calls = [];
  final List<Map<String, dynamic>> _pending = [];
  bool initialised = false;
  bool shutdownCalled = false;
  int _seq = 0;

  /// Queue an event to be returned by the next poll.
  void emit(Map<String, dynamic> event) {
    _pending.add({'ts': DateTime.now().millisecondsSinceEpoch, ...event});
  }

  /// Convenience: emits the events a freshly started server produces.
  String emitServerStarted({String token = 'tcTESTTOKEN', Map<String, dynamic> info = const {}}) {
    final id = 'server-${++_seq}';
    emit({'type': 'session_state', 'session_id': id, 'kind': 'server', 'state': 'starting', 'detail': 'selecting relay', ...info});
    emit({'type': 'token_ready', 'session_id': id, 'token': token});
    emit({'type': 'session_state', 'session_id': id, 'kind': 'server', 'state': 'running', 'detail': 'listening', ...info});
    return id;
  }

  @override
  Future<void> init() async => initialised = true;

  @override
  Future<String> call(String requestJson) async {
    final req = jsonDecode(requestJson) as Map<String, dynamic>;
    calls.add(req);
    final op = req['op'] as String;
    final r = responses[op];
    if (r is Exception) return jsonEncode({'ok': false, 'error': {'code': 'internal', 'message': r.toString()}});
    if (r == null) {
      return jsonEncode({'ok': false, 'error': {'code': 'bad_request', 'message': 'unknown op $op'}});
    }
    return jsonEncode({'ok': true, 'result': r});
  }

  @override
  String poll() {
    final out = jsonEncode({'events': _pending});
    _pending.clear();
    return out;
  }

  @override
  String get version => 'core/test';

  @override
  void shutdown() => shutdownCalled = true;
}
