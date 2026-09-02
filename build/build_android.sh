#!/usr/bin/env bash
# Builds libtailcat_core.so for Android (arm64-v8a, x86_64 by default).
# Needs the Android NDK: set ANDROID_NDK_HOME, or ANDROID_HOME with ndk/<ver>.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || { echo "Android NDK not found; set ANDROID_NDK_HOME" >&2; exit 1; }

HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"   # NDK ships darwin-x86_64 even on arm64 Macs
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG"
[ -d "$TOOLCHAIN" ] || { echo "NDK toolchain not found at $TOOLCHAIN" >&2; exit 1; }

API="${ANDROID_API:-24}"
ABIS="${ABIS:-arm64-v8a x86_64}"
export CGO_ENABLED=1 GOOS=android

for ABI in $ABIS; do
  case "$ABI" in
    arm64-v8a)   GOARCH=arm64; TRIPLE=aarch64-linux-android ;;
    x86_64)      GOARCH=amd64; TRIPLE=x86_64-linux-android ;;
    armeabi-v7a) GOARCH=arm; export GOARM=7; TRIPLE=armv7a-linux-androideabi ;;
    *) echo "unknown ABI $ABI" >&2; exit 1 ;;
  esac
  export GOARCH CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang" CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  go_build_shared "$OUT/android/$ABI/libtailcat_core.so"
  echo "built $OUT/android/$ABI/libtailcat_core.so"
done
