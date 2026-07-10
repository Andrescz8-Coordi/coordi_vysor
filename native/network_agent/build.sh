#!/usr/bin/env bash
# Compila libcoordi_net_agent.so para las ABIs Android más comunes.
# Requiere ANDROID_NDK_HOME (o NDK) apuntando al NDK r26+.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/../../assets/agents"
NDK="${ANDROID_NDK_HOME:-${NDK:-}}"

if [[ -z "$NDK" && -d "$HOME/Library/Android/sdk/ndk" ]]; then
  NDK="$(ls -1 "$HOME/Library/Android/sdk/ndk" | sort -V | tail -1)"
  NDK="$HOME/Library/Android/sdk/ndk/$NDK"
fi

if [[ -z "$NDK" ]]; then
  echo "ERROR: define ANDROID_NDK_HOME o instala NDK en Android SDK" >&2
  exit 1
fi

echo "Usando NDK: $NDK"

HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
if [[ "$HOST" == "darwin-arm64" ]]; then HOST="darwin-x86_64"; fi
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST"
CLANG="$TOOLCHAIN/bin/aarch64-linux-android21-clang++"

ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")
API=21

mkdir -p "$OUT"

for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a)   TRIPLE="aarch64-linux-android" ;;
    armeabi-v7a) TRIPLE="armv7a-linux-androideabi" ;;
    x86_64)      TRIPLE="x86_64-linux-android" ;;
  esac
  CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  BUILD="$ROOT/build/$ABI"
  mkdir -p "$BUILD"
  echo "==> Compilando $ABI"
  # slicer (third_party) necesita RTTI y excepciones (no pasar -fno-rtti/-fno-exceptions).
  "$CXX" \
    -shared -fPIC -O2 -std=c++17 \
    -static-libstdc++ \
    -I"$ROOT/src" \
    -I"$ROOT/include" \
    -I"$ROOT/third_party/slicer" \
    -I"$ROOT/third_party/slicer/export" \
    "$ROOT/src/agent.cpp" \
    "$ROOT/src/socket_emitter.cpp" \
    "$ROOT/src/url_connection_hooks.cpp" \
    "$ROOT/src/dex_instrument.cpp" \
    "$ROOT/src/probe_loader.cpp" \
    "$ROOT"/third_party/slicer/*.cc \
    -llog -lz \
    -o "$BUILD/libcoordi_net_agent.so"
  mkdir -p "$OUT/$ABI"
  cp "$BUILD/libcoordi_net_agent.so" "$OUT/$ABI/"
  echo "    -> $OUT/$ABI/libcoordi_net_agent.so"
done

echo "Listo. Los .so quedaron en assets/agents/"
