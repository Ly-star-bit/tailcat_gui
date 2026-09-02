import 'dart:convert';
import 'dart:isolate';

import 'package:tailcat_core_ffi/tailcat_core_ffi.dart';

/// The raw string pipe to the Go core. Abstracted so tests can script it
/// without loading the native library.
abstract class CoreBackend {
  Future<void> init();

  /// Runs one JSON request and returns the JSON response.
  Future<String> call(String requestJson);

  /// Drains queued events as `{"events":[...]}`.
  String poll();

  String get version;

  void shutdown();
}

/// Production backend over dart:ffi.
class FfiCoreBackend implements CoreBackend {
  FfiCoreBackend({this.libraryPath, this.dataDir, this.derpMapUrl});

  final String? libraryPath;
  final String? dataDir;
  final String? derpMapUrl;

  late TailcatCore _core;
  late String _resolvedPath;

  @override
  Future<void> init() async {
    _core = TailcatCore.open(libraryPath: libraryPath);
    _resolvedPath = _core.libraryPath;
    final ok = _core.init(jsonEncode({
      if (dataDir != null) 'data_dir': dataDir,
      if (derpMapUrl != null) 'derpmap_url': derpMapUrl,
    }));
    if (!ok) throw StateError('tc_init failed');
  }

  @override
  Future<String> call(String requestJson) {
    // tc_call may block for seconds (ping, list_remote). Run it on a worker
    // isolate; the Go engine is process-global so re-opening the library
    // there reaches the same engine.
    final path = _resolvedPath;
    return Isolate.run(
      () => TailcatCore.open(libraryPath: path).call(requestJson),
      debugName: 'tailcat-call',
    );
  }

  @override
  String poll() => _core.poll();

  @override
  String get version => _core.version;

  @override
  void shutdown() => _core.shutdown();
}
