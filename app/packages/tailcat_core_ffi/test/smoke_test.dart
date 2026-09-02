// Headless smoke test: loads the real native library and round-trips a
// command. Skipped unless TAILCAT_CORE_LIB points at a built library, e.g.
//   TAILCAT_CORE_LIB=$PWD/../../../build/out/macos/libtailcat_core.dylib flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tailcat_core_ffi/tailcat_core_ffi.dart';

void main() {
  final lib = Platform.environment[tailcatCoreLibEnv];
  test(
    'native library answers get_caps and poll',
    () {
      final core = TailcatCore.open();
      expect(core.init('{}'), isTrue);
      expect(core.version, startsWith('core/'));

      final caps = jsonDecode(core.call('{"op":"get_caps"}')) as Map;
      expect(caps['ok'], isTrue);
      // Go's GOOS vs Dart's operatingSystem: darwin/macos differ in name.
      final goos = Platform.isMacOS ? 'darwin' : Platform.operatingSystem;
      expect((caps['result'] as Map)['platform'], goos);

      final bad = jsonDecode(core.call('garbage')) as Map;
      expect(bad['ok'], isFalse);
      expect((bad['error'] as Map)['code'], 'bad_request');

      final events = jsonDecode(core.poll()) as Map;
      expect(events['events'], isA<List>());
      core.shutdown();
    },
    skip: (lib == null || lib.isEmpty)
        ? 'set $tailcatCoreLibEnv to a built libtailcat_core'
        : false,
  );
}
