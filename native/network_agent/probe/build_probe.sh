#!/usr/bin/env bash
# Compila el helper coordi.probe.Probe a dex, lo empaca en un jar y lo embebe
# como header C (src/probe_dex.h). Correr tras editar Probe.java.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENT="$ROOT/.."
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"

ANDROID_JAR="$(ls -1d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
D8="$(ls -1 "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)"

if [[ -z "$ANDROID_JAR" || -z "$D8" ]]; then
  echo "ERROR: falta android.jar o d8 en $SDK" >&2
  exit 1
fi

rm -rf "$ROOT/out" && mkdir -p "$ROOT/out"
javac -source 8 -target 8 -cp "$ANDROID_JAR" -d "$ROOT/out" "$ROOT"/coordi/probe/Probe.java
"$D8" --min-api 26 --output "$ROOT/out" $(find "$ROOT/out" -name '*.class')
( cd "$ROOT/out" && zip -q coordi_probe.jar classes.dex )

{
  echo "// Generado por probe/build_probe.sh — NO editar a mano."
  echo "// coordi_probe.jar (classes.dex del helper coordi.probe.Probe) embebido."
  echo "#pragma once"
  echo "#include <cstddef>"
  xxd -i -n g_probeJar "$ROOT/out/coordi_probe.jar" \
    | sed 's/unsigned char/const unsigned char/; s/unsigned int/const unsigned int/'
} > "$AGENT/src/probe_dex.h"

echo "Listo: $AGENT/src/probe_dex.h ($(wc -c < "$ROOT/out/coordi_probe.jar") bytes de jar)"
