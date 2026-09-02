import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tailcat_gui/core/engine.dart';
import 'package:tailcat_gui/core/probe.dart';
import 'package:tailcat_gui/core/providers.dart';
import 'package:tailcat_gui/screens/client_session_screen.dart';
import 'package:tailcat_gui/screens/connect_screen.dart';
import 'package:tailcat_gui/screens/home_screen.dart';
import 'package:tailcat_gui/screens/peer_screen.dart';
import 'package:tailcat_gui/screens/server_screen.dart';
import 'package:tailcat_gui/screens/share_screen.dart';

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

void tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const probeSendShare = {
  'reachable': true, 'via': 'direct', 'detail': '1.2.3.4:41641', 'latency_ms': 3.0,
  'manifest': {
    'app': 'tailcat-gui', 'version': 'dev', 'name': 'my-laptop', 'platform': 'darwin',
    'ports': [8080], 'exit_node': true,
    'files': {'mode': 'ro', 'items': [{'name': 'photo.jpg', 'size': 1024, 'is_dir': false}]},
  },
  'sftp': true, 'sftp_list': true, 'ssh_shell': false, 'cli_fallback': false,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home offers share and connect and shows core version', (tester) async {
    final (_, engine) = await startEngine();
    await tester.pumpWidget(app(engine, const HomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('发送文件'), findsOneWidget);
    expect(find.textContaining('tailcat v0.4.0'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('share screen builds one start_server call from several sections', (tester) async {
    tallViewport(tester);
    final (backend, engine) = await startEngine();
    backend.responses['start_server'] = {'session_id': 'server-1'};
    await tester.pumpWidget(app(engine, const ShareScreen()));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '生成令牌')).enabled, isFalse);
    await tester.enterText(find.widgetWithText(TextField, '本机端口（可选）'), '8080, 8443');
    await tester.tap(find.text('让对方通过我的网络上网'));
    await tester.tap(find.text('免密 SSH 登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成令牌'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final start = backend.calls.firstWhere((c) => c['op'] == 'start_server');
    expect(start['args']['ports'], [8080, 8443]);
    expect(start['args']['exit_node'], isTrue);
    expect(start['args']['ssh'], isTrue);
    expect(start['args']['all'], isFalse);
    expect(find.byType(ServerScreen), findsOneWidget);

    backend.emitServerStarted(token: 'tcHELLO', info: {'ports': [8080, 8443], 'exit_node': true});
    engine.pump();
    await tester.pumpAndSettle();
    expect(find.text('tcHELLO'), findsOneWidget);
    expect(find.text('断开并停止'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('connect screen probes the token and opens the peer screen', (tester) async {
    tallViewport(tester);
    final (backend, engine) = await startEngine();
    backend.responses['probe'] = probeSendShare;
    await tester.pumpWidget(app(engine, const ConnectScreen()));
    await tester.enterText(find.byType(TextFormField), 'tcSOMETOKEN');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    expect(backend.calls.lastWhere((c) => c['op'] == 'probe')['args']['token'], 'tcSOMETOKEN');
    expect(find.byType(PeerScreen), findsOneWidget);
    expect(find.textContaining('my-laptop'), findsWidgets);
    expect(find.textContaining('对方发来 1 项文件'), findsOneWidget);
    expect(find.text('全部接收'), findsOneWidget);
    expect(find.text('端口 8080'), findsOneWidget);
    expect(find.text('开启 SOCKS5 代理'), findsOneWidget);
    expect(find.text('SSH 登录'), findsNothing);
    engine.dispose();
  });

  testWidgets('connect screen shows a friendly error when unreachable', (tester) async {
    final (backend, engine) = await startEngine();
    backend.responses['probe'] = Exception('connect: server not reachable: context deadline exceeded');
    await tester.pumpWidget(app(engine, const ConnectScreen()));
    await tester.enterText(find.byType(TextFormField), 'tcSOMETOKEN');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连不上对方'), findsOneWidget);
    expect(find.byType(PeerScreen), findsNothing);
    engine.dispose();
  });

  testWidgets('peer screen maps a known port with one tap', (tester) async {
    tallViewport(tester);
    final (backend, engine) = await startEngine();
    backend.responses['start_forward'] = {'session_id': 'forward-1', 'local_port': 8080};
    final probe = ProbeResult.fromJson(probeSendShare);
    await tester.pumpWidget(app(engine, PeerScreen(token: 'tcX', probe: probe)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('映射到本机'));
    // The pushed session screen spins until the core reports state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final fw = backend.calls.lastWhere((c) => c['op'] == 'start_forward');
    expect(fw['args']['remote_port'], 8080);
    expect(find.byType(ClientSessionScreen), findsOneWidget);
    engine.dispose();
  });

  testWidgets('peer screen for a CLI drop box offers sending and manual ports', (tester) async {
    tallViewport(tester);
    final (_, engine) = await startEngine();
    final probe = ProbeResult.fromJson(const {
      'reachable': true, 'via': 'derp', 'detail': 'DERP(sfo)', 'latency_ms': 40.0,
      'sftp': true, 'sftp_list': false, 'ssh_shell': false, 'cli_fallback': true,
    });
    await tester.pumpWidget(app(engine, PeerScreen(token: 'tcX', probe: probe)));
    await tester.pumpAndSettle();
    expect(find.text('对方在等待接收文件'), findsOneWidget);
    expect(find.text('对方用的是命令行 tailcat'), findsOneWidget);
    expect(find.text('映射'), findsOneWidget);
    engine.dispose();
  });
}
