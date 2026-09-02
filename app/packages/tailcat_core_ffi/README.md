# tailcat_core_ffi

`dart:ffi` loader for `libtailcat_core`, the Go shared library that wraps
[tailcat](https://github.com/tailscale/tailcat) for the Tailcat GUI.

The library is **prebuilt** by the scripts in `../../../build/` and copied here
by `build/sync_libs.sh`:

| Platform | Location in this package                          |
|----------|---------------------------------------------------|
| Android  | `android/src/main/jniLibs/<abi>/libtailcat_core.so` |
| macOS    | `macos/Libraries/libtailcat_core.dylib` (universal) |
| Windows  | `windows/lib/tailcat_core.dll`                    |

The C contract is `src/bridge.h`; the Dart bindings in `lib/src/bindings.dart`
are hand-written to match it.

```dart
final core = TailcatCore.open();
core.init('{}');
print(core.call('{"op":"get_caps"}'));
print(core.poll());
```

Set `TAILCAT_CORE_LIB=/path/to/libtailcat_core.dylib` to load a specific
build (used by headless tests).
