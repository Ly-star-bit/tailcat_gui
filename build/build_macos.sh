#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) libtailcat_core.dylib for macOS.
# Requires only the Xcode Command Line Tools (clang) and Go.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DEST="$OUT/macos"
mkdir -p "$DEST"
export CGO_ENABLED=1 GOOS=darwin MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

GOARCH=arm64 go_build_shared "$DEST/libtailcat_core-arm64.dylib"
GOARCH=amd64 go_build_shared "$DEST/libtailcat_core-amd64.dylib"
lipo -create -output "$DEST/libtailcat_core.dylib" \
  "$DEST/libtailcat_core-arm64.dylib" "$DEST/libtailcat_core-amd64.dylib"
rm -f "$DEST/libtailcat_core-arm64.dylib" "$DEST/libtailcat_core-amd64.dylib"

# Load by @rpath so the Flutter bundle can embed it in Frameworks/.
install_name_tool -id "@rpath/libtailcat_core.dylib" "$DEST/libtailcat_core.dylib"
codesign --force --sign - "$DEST/libtailcat_core.dylib" >/dev/null 2>&1 || true

echo "built $DEST/libtailcat_core.dylib"
lipo -info "$DEST/libtailcat_core.dylib"
nm -gU "$DEST/libtailcat_core.dylib" | grep -E ' _tc_' || { echo "missing tc_ exports" >&2; exit 1; }
