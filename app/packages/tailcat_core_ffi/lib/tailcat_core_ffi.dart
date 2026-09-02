/// Loads libtailcat_core and exposes its JSON command/event pipe.
///
/// The Go side never calls back into Dart; the app polls [poll] for events.
/// [call] blocks the calling isolate for the duration of the command, so run
/// slow commands (ping, list_remote) through `Isolate.run`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart';

export 'src/bindings.dart' show TailcatCoreBindings;

/// Environment variable that overrides where the native library is loaded
/// from (handy for `dart test` and headless smoke tests).
const String tailcatCoreLibEnv = 'TAILCAT_CORE_LIB';

class TailcatCore {
  TailcatCore._(this._b, this.libraryPath);

  final TailcatCoreBindings _b;

  /// Where the library was loaded from (informational).
  final String libraryPath;

  /// Opens the native library. Tries, in order: [libraryPath], the
  /// [tailcatCoreLibEnv] variable, then the platform's bundled location.
  static TailcatCore open({String? libraryPath}) {
    final candidates = <String>[
      ?libraryPath,
      ?_envOverride,
      ...defaultLibraryCandidates(),
    ];
    Object? lastError;
    for (final c in candidates) {
      try {
        final lib = DynamicLibrary.open(c);
        return TailcatCore._(TailcatCoreBindings(lib), c);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      'could not load libtailcat_core (tried ${candidates.join(', ')}): $lastError',
    );
  }

  static String? get _envOverride {
    final p = Platform.environment[tailcatCoreLibEnv];
    return (p == null || p.isEmpty) ? null : p;
  }

  /// Platform-specific places the bundled library may live.
  static List<String> defaultLibraryCandidates() {
    if (Platform.isAndroid) {
      return const ['libtailcat_core.so'];
    }
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return ['$exeDir\\tailcat_core.dll', 'tailcat_core.dll'];
    }
    if (Platform.isMacOS) {
      // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Frameworks/
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return [
        '$exeDir/../Frameworks/libtailcat_core.dylib',
        '@rpath/libtailcat_core.dylib',
        'libtailcat_core.dylib',
      ];
    }
    if (Platform.isLinux) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return ['$exeDir/lib/libtailcat_core.so', 'libtailcat_core.so'];
    }
    throw UnsupportedError('unsupported platform ${Platform.operatingSystem}');
  }

  /// Initialises the engine. [configJson] may be empty or a JSON object with
  /// "data_dir" and "derpmap_url". Returns true on success.
  bool init([String configJson = '{}']) {
    final p = configJson.toNativeUtf8();
    try {
      return _b.init(p) == 0;
    } finally {
      malloc.free(p);
    }
  }

  /// Runs one JSON request and returns the JSON response string.
  String call(String requestJson) {
    final p = requestJson.toNativeUtf8();
    try {
      return _take(_b.call(p));
    } finally {
      malloc.free(p);
    }
  }

  /// Drains queued events as a JSON string `{"events":[...]}`.
  String poll() => _take(_b.poll());

  /// Static version string; never freed.
  String get version => _b.version().toDartString();

  /// Stops all sessions and releases the engine.
  void shutdown() => _b.shutdown();

  String _take(Pointer<Utf8> p) {
    if (p == nullptr) return '';
    try {
      return p.toDartString();
    } finally {
      _b.free(p);
    }
  }
}
