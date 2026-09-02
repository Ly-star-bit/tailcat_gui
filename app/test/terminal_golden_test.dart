// Renders the terminal chrome to PNGs so its look can be reviewed without
// launching the app. Update with: flutter test --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tailcat_gui/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('key bar', (tester) async {
    tester.view.physicalSize = const Size(1400, 60);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final terminal = Terminal();
    // The modifier object outlives rebuilds, exactly as it does on the screen.
    late StateSetter rebuild;
    final keys = TerminalStickyModifiers(defaultInputHandler, onChanged: () => rebuild(() {}));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF1A1B26),
        body: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Align(
              alignment: Alignment.bottomCenter,
              child: TerminalKeyBar(
                keys: keys,
                terminal: terminal,
                sendCtrl: (_) {},
                onPaste: () {},
              ),
            );
          },
        ),
      ),
    ));
    await expectLater(find.byType(TerminalKeyBar), matchesGoldenFile('goldens/key_bar.png'));

    // Tapping Ctrl must visibly change the key: it is a sticky modifier
    // and the user needs to see that it is armed.
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(keys.ctrl, isTrue);
    await expectLater(find.byType(TerminalKeyBar), matchesGoldenFile('goldens/key_bar_ctrl.png'));
  });
}
