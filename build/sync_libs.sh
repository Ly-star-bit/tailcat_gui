#!/usr/bin/env bash
# Copies built native libraries into the Flutter FFI plugin so `flutter build`
# bundles them. Missing platforms are skipped.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

copy() { # <src> <dst>
  if [ -f "$1" ]; then mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "  $2"; fi
}

echo "syncing native libraries into $PLUGIN"
for ABI in arm64-v8a x86_64 armeabi-v7a; do
  copy "$OUT/android/$ABI/libtailcat_core.so" "$PLUGIN/android/src/main/jniLibs/$ABI/libtailcat_core.so"
done
copy "$OUT/macos/libtailcat_core.dylib" "$PLUGIN/macos/Libraries/libtailcat_core.dylib"
copy "$OUT/windows/x64/tailcat_core.dll" "$PLUGIN/windows/lib/tailcat_core.dll"
copy "$CORE/bridge/bridge.h" "$PLUGIN/src/bridge.h"
