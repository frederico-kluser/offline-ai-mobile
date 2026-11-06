#!/usr/bin/env bash
# Build da app "anonymous-browser mobile" — reutiliza os artefactos nativos do
# app de exemplo (llama.cpp via FFI): os jniLibs/xcframework são construídos
# pelo ./build.sh da RAIZ do monorepo (tools/llama_build*.sh) e aqui são só
# copiados. Os modelos (Laya ONNX + MiniCPM5-2B GGUF) seguem o catálogo do
# ab_core — descarregar na app de exemplo (aba Modelos).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if [ -f "$ROOT/android/app/src/main/jniLibs/arm64-v8a/libllama.so" ]; then
  mkdir -p "$HERE/android/app/src/main/jniLibs"
  cp -R "$ROOT/android/app/src/main/jniLibs/." "$HERE/android/app/src/main/jniLibs/"
  echo "  OK    jniLibs Android copiados do app de exemplo"
else
  echo "  AVISO jniLibs Android ausentes — corre ./build.sh na raiz do monorepo" >&2
fi

if [ "$(uname -s)" = "Darwin" ] && [ -d "$ROOT/ios/pods/llama_ffi" ]; then
  mkdir -p "$HERE/ios/pods"
  cp -R "$ROOT/ios/pods/llama_ffi" "$HERE/ios/pods/"
  echo "  OK    llama.xcframework iOS copiado do app de exemplo"
fi

command -v flutter >/dev/null || { echo "Erro: flutter não está no PATH — Solução: export PATH=/Volumes/Ext2TB/dev-tools/flutter/bin:\$PATH" >&2; exit 1; }

flutter pub get >/dev/null

case "$(uname -s)" in
  Darwin) flutter build ios --no-codesign ;;
  Linux)  flutter build apk --release ;;
esac

echo "== BUILD_OK =="
