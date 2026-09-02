#!/usr/bin/env bash
# Shared settings for the native-library build scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
OUT="${OUT:-$ROOT/build/out}"
PLUGIN="$ROOT/app/packages/tailcat_core_ffi"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
LDFLAGS="-s -w -X tailcat_gui/core/engine.Version=$VERSION"

# Optional size-trimming build tags from tailcat's build-tags.txt.
TAGS="${TAGS:-}"
if [ -z "$TAGS" ] && [ -f "$ROOT/build/tags.txt" ]; then
  TAGS="$(tr '\n' ' ' < "$ROOT/build/tags.txt")"
fi

go_build_shared() { # <output> [extra go args...]
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  (cd "$CORE" && go build -trimpath -buildmode=c-shared ${TAGS:+-tags "$TAGS"} -ldflags "$LDFLAGS" -o "$out" "$@" ./bridge)
  # cgo emits a header next to the library; keep the hand-written one canonical.
  rm -f "${out%.*}.h"
}
