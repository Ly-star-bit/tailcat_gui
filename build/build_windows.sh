#!/usr/bin/env bash
# Cross-builds tailcat_core.dll (x86_64) from macOS/Linux using mingw-w64.
#   brew install mingw-w64
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "x86_64-w64-mingw32-gcc not found (brew install mingw-w64)" >&2; exit 1; }
export CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++
go_build_shared "$OUT/windows/x64/tailcat_core.dll"
echo "built $OUT/windows/x64/tailcat_core.dll"
