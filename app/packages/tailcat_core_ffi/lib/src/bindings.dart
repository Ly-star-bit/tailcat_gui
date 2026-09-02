// Hand-written dart:ffi bindings for src/bridge.h.
//
// Keep in sync with core/bridge/bridge.h:
//   int         tc_init(const char* config_json);
//   char*       tc_call(const char* request_json);
//   char*       tc_poll(void);
//   void        tc_free(char* p);
//   const char* tc_version(void);
//   void        tc_shutdown(void);
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef TcInitC = Int32 Function(Pointer<Utf8>);
typedef TcInitDart = int Function(Pointer<Utf8>);
typedef TcCallC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef TcCallDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef TcPollC = Pointer<Utf8> Function();
typedef TcPollDart = Pointer<Utf8> Function();
typedef TcFreeC = Void Function(Pointer<Utf8>);
typedef TcFreeDart = void Function(Pointer<Utf8>);
typedef TcVersionC = Pointer<Utf8> Function();
typedef TcVersionDart = Pointer<Utf8> Function();
typedef TcShutdownC = Void Function();
typedef TcShutdownDart = void Function();

/// Raw function pointers looked up in the loaded library.
class TailcatCoreBindings {
  TailcatCoreBindings(DynamicLibrary lib)
      : init = lib.lookupFunction<TcInitC, TcInitDart>('tc_init'),
        call = lib.lookupFunction<TcCallC, TcCallDart>('tc_call'),
        poll = lib.lookupFunction<TcPollC, TcPollDart>('tc_poll'),
        free = lib.lookupFunction<TcFreeC, TcFreeDart>('tc_free'),
        version = lib.lookupFunction<TcVersionC, TcVersionDart>('tc_version'),
        shutdown =
            lib.lookupFunction<TcShutdownC, TcShutdownDart>('tc_shutdown');

  final TcInitDart init;
  final TcCallDart call;
  final TcPollDart poll;
  final TcFreeDart free;
  final TcVersionDart version;
  final TcShutdownDart shutdown;
}
