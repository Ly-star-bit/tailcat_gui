import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailcat_gui/core/engine.dart';
import 'package:tailcat_gui/core/models.dart';
import 'package:tailcat_gui/core/providers.dart';
import 'package:tailcat_gui/util/format.dart';

import 'fake_backend.dart';

void main() {
  group('Engine', () {
    test('call unwraps result and throws EngineException on error', () async {
      final backend = FakeCoreBackend();
      backend.responses['start_forward'] = {'session_id': 'forward-1', 'local_port': 9000};
      final engine = Engine(backend);
      await engine.start();
      expect(backend.initialised, isTrue);

      final r = await engine.call('start_forward', {'token': 'tcX', 'remote_port': 80});
      expect(r['local_port'], 9000);
      expect(backend.calls.last['args'], {'token': 'tcX', 'remote_port': 80});

      expect(() => engine.call('nope'), throwsA(isA<EngineException>().having((e) => e.code, 'code', 'bad_request')));
      engine.dispose();
      expect(backend.shutdownCalled, isTrue);
    });

    test('pump emits typed events and tracks active sessions', () async {
      final backend = FakeCoreBackend();
      final engine = Engine(backend);
      await engine.start();
      final seen = <EngineEvent>[];
      engine.events.listen(seen.add);

      backend.emit({'type': 'session_state', 'session_id': 's1', 'kind': 'forward', 'state': 'running'});
      backend.emit({'type': 'progress', 'session_id': 's1', 'file': 'a.bin', 'bytes': 5, 'total': 10, 'direction': 'up'});
      backend.emit({'type': 'path', 'session_id': 's1', 'via': 'direct', 'detail': '1.2.3.4:5', 'latency_ms': 3.5});
      engine.pump();
      await Future<void>.delayed(Duration.zero);

      expect(seen.map((e) => e.runtimeType).toList(), [SessionStateEvent, ProgressEvent, PathEvent]);
      expect((seen[1] as ProgressEvent).transfer.fraction, 0.5);
      expect((seen[2] as PathEvent).path.isDirect, isTrue);
      expect(engine.hasActiveSessions, isTrue);

      backend.emit({'type': 'session_state', 'session_id': 's1', 'kind': 'forward', 'state': 'stopped'});
      engine.pump();
      expect(engine.hasActiveSessions, isFalse);
      engine.dispose();
    });
  });

  group('providers', () {
    test('sessions reduce state, token, path and errors', () async {
      final backend = FakeCoreBackend();
      final engine = Engine(backend);
      await engine.start();
      final container = ProviderContainer(overrides: [engineProvider.overrideWithValue(engine)]);
      addTearDown(container.dispose);
      container.listen(sessionsProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);

      final id = backend.emitServerStarted(token: 'tcABC', info: {'ports': [8080]});
      backend.emit({'type': 'path', 'session_id': id, 'via': 'derp', 'detail': 'DERP(sfo)', 'peers': 1});
      backend.emit({'type': 'error', 'session_id': id, 'code': 'x', 'message': 'boom'});
      engine.pump();
      await Future<void>.delayed(Duration.zero);

      final s = container.read(sessionsProvider)[id]!;
      expect(s.kind, SessionKind.server);
      expect(s.state, SessionState.running);
      expect(s.token, 'tcABC');
      expect(s.path?.via, 'derp');
      expect(s.peers, 1);
      expect(s.lastError, 'boom');
      expect(s.summary, contains('8080'));
      expect(container.read(activeSessionCountProvider), 1);

      // Terminal state: remove() is allowed only then.
      container.read(sessionsProvider.notifier).remove(id);
      expect(container.read(sessionsProvider).containsKey(id), isTrue);
      backend.emit({'type': 'session_state', 'session_id': id, 'kind': 'server', 'state': 'stopped'});
      engine.pump();
      await Future<void>.delayed(Duration.zero);
      container.read(sessionsProvider.notifier).remove(id);
      expect(container.read(sessionsProvider).containsKey(id), isFalse);
      engine.dispose();
    });

    test('transfers and logs are collected', () async {
      final backend = FakeCoreBackend();
      final engine = Engine(backend);
      await engine.start();
      final container = ProviderContainer(overrides: [engineProvider.overrideWithValue(engine)]);
      addTearDown(container.dispose);
      container.listen(transfersProvider, (_, _) {});
      container.listen(logProvider, (_, _) {});

      backend.emit({'type': 'progress', 'session_id': 'send-1', 'file': 'a', 'bytes': 1, 'total': 2, 'direction': 'up'});
      backend.emit({'type': 'progress', 'session_id': 'send-1', 'file': 'a', 'bytes': 2, 'total': 2, 'direction': 'up', 'done': true});
      backend.emit({'type': 'log', 'level': 'debug', 'msg': 'hidden'});
      backend.emit({'type': 'log', 'level': 'info', 'msg': 'shown'});
      engine.pump();
      await Future<void>.delayed(Duration.zero);

      final t = container.read(sessionTransfersProvider('send-1'));
      expect(t.single.done, isTrue);
      expect(container.read(logProvider).map((l) => l.msg), ['shown']);
      container.read(transfersProvider.notifier).clearFinished();
      expect(container.read(transfersProvider), isEmpty);
      engine.dispose();
    });
  });

  group('format', () {
    test('bytes and ports', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
      expect(parsePorts('80, 443 3000-3002'), [80, 443, 3000, 3001, 3002]);
      expect(() => parsePorts('70000'), throwsFormatException);
      expect(() => parsePorts('abc'), throwsFormatException);
    });
  });
}
