import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailcat_gui/core/engine.dart';
import 'package:tailcat_gui/core/providers.dart';
import 'package:tailcat_gui/screens/client_session_screen.dart';
import 'package:tailcat_gui/screens/home_screen.dart';
import 'package:tailcat_gui/screens/server_screen.dart';
import 'package:tailcat_gui/screens/share_port_screen.dart';

import 'fake_backend.dart';

Future<(FakeCoreBackend, Engine)> startEngine({Map<String, dynamic>? caps}) async {
  final backend = FakeCoreBackend(caps: caps);
  // Long intervals so the periodic timer never fires inside pumpWidget.
  final engine = Engine(backend, activeInterval: const Duration(days: 1), idleInterval: const Duration(days: 1));
  await engine.start();
  return (backend, engine);
}

Widget app(Engine engine, Widget home) => ProviderScope(
      overrides: [engineProvider.overrideWithValue(engine)],
      child: MaterialApp(home: home),
    );

void main() {
  testWidgets('home lists every action and shows core version', (tester) async {
    final (_, engine) = await startEngine();
    await tester.pumpWidget(app(engine, const HomeScreen()));
    await tester.pumpAndSettle();

    for (final label in ['接收文件', '发送文件', '共享文件夹', '浏览并下载', '共享端口', '连接端口', 'SOCKS5 代理']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('tailcat v0.4.0'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('share port form starts a server and shows its token', (tester) async {
    // Tall viewport so the QR card and the stop button fit without scrolling.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (backend, engine) = await startEngine();
    backend.responses['start_server'] = {'session_id': 'server-1'};
    await tester.pumpWidget(app(engine, const SharePortScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), '8080, 8443');
    await tester.tap(find.text('生成令牌'));
    // The "starting" card shows a spinner, so pumpAndSettle would never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final start = backend.calls.firstWhere((c) => c['op'] == 'start_server');
    expect(start['args']['ports'], [8080, 8443]);
    expect(find.byType(ServerScreen), findsOneWidget);

    // The core reports "starting" first, then the token.
    backend.emit({'type': 'session_state', 'session_id': 'server-1', 'kind': 'server', 'state': 'starting', 'detail': 'selecting relay'});
    engine.pump();
    await tester.pump();
    expect(find.text('正在选择中继并生成令牌…'), findsOneWidget);

    backend.emitServerStarted(token: 'tcHELLO', info: {'ports': [8080, 8443]});
    engine.pump();
    await tester.pumpAndSettle();

    expect(find.text('tcHELLO'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('断开并停止'), findsOneWidget);

    backend.responses['stop'] = {};
    await tester.ensureVisible(find.text('断开并停止'));
    await tester.tap(find.text('断开并停止'));
    await tester.pumpAndSettle();
    final stop = backend.calls.lastWhere((c) => c['op'] == 'stop');
    expect(stop['args']['session_id'], 'server-1');
    engine.dispose();
  });

  testWidgets('share port form rejects bad ports', (tester) async {
    final (backend, engine) = await startEngine();
    await tester.pumpWidget(app(engine, const SharePortScreen()));
    await tester.enterText(find.byType(TextFormField), 'abc');
    await tester.tap(find.text('生成令牌'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无效端口'), findsOneWidget);
    expect(backend.calls.where((c) => c['op'] == 'start_server'), isEmpty);
    engine.dispose();
  });

  testWidgets('client session screen shows forward address and path', (tester) async {
    final (backend, engine) = await startEngine();
    await tester.pumpWidget(app(engine, const ClientSessionScreen(sessionId: 'forward-1', title: '连接端口')));
    backend.emit({
      'type': 'session_state', 'session_id': 'forward-1', 'kind': 'forward', 'state': 'running',
      'local_port': 9000, 'remote_port': 8080, 'listen': '127.0.0.1:9000',
    });
    backend.emit({'type': 'path', 'session_id': 'forward-1', 'via': 'direct', 'detail': '1.2.3.4:41641', 'latency_ms': 2.0});
    engine.pump();
    await tester.pumpAndSettle();

    expect(find.text('127.0.0.1:9000'), findsOneWidget);
    expect(find.textContaining('直连'), findsOneWidget);
    expect(find.text('断开连接'), findsOneWidget);
    engine.dispose();
  });
}
