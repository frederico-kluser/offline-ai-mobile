#!/usr/bin/env bash
# Build "do zero" do offline-ai-mobile — um comando para qualquer máquina.
#   ./build.sh            # constrói dependências nativas (se faltarem) + app
#   ./build.sh --check    # só verifica o estado, não constrói
#
# Porquê: os artefactos nativos (jniLibs Android / llama.xcframework iOS) são
# reprodutíveis mas ficam FORA do git (~500 MB). Sem eles o flutter build falha
# com "library not found" — este script deteta e constrói o que falta.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
CHECK_ONLY="${1:-}"

ok()   { echo "  OK    $1"; }
miss() { echo "  FALTA $1"; }
die()  { echo "Erro: $1 — Solução: $2" >&2; exit 1; }

echo "== offline-ai-mobile · preflight =="
command -v flutter >/dev/null || die "flutter não está no PATH" \
  "instala o Flutter 3.47+ e adiciona flutter/bin ao PATH"

NEED_ANDROID=0; NEED_IOS=0
case "$(uname -s)" in
  Darwin) NEED_IOS=1 ;;
  Linux)  NEED_ANDROID=1 ;;
esac

# Presença de artefactos nativos
if [ -f "android/app/src/main/jniLibs/arm64-v8a/libllama.so" ]; then
  ok "jniLibs Android (libllama.so arm64 + x86_64)"
else
  miss "jniLibs Android — necessário para flutter build apk"
  NEED_ANDROID=1
fi
if [ "$(uname -s)" = "Darwin" ] && [ -f "ios/pods/llama_ffi/llama.xcframework/Info.plist" ]; then
  ok "llama.xcframework iOS (device + simulador)"
elif [ "$(uname -s)" = "Darwin" ]; then
  miss "llama.xcframework iOS — necessário para flutter build ios"
  NEED_IOS=1
fi

if [ "$CHECK_ONLY" = "--check" ]; then
  echo "== check: $([ $NEED_ANDROID -eq 0 ] && [ $NEED_IOS -eq 0 ] && echo TUDO_PRONTO || echo FALTAM_ARTEFACTOS) =="
  exit 0
fi

# Constrói o que falta (uma vez; depois é só flutter build)
if [ $NEED_ANDROID -eq 1 ]; then
  echo "== llama.cpp Android (x86_64 + arm64-v8a) =="
  [ -n "${ANDROID_HOME:-}" ] || die "ANDROID_HOME não definido" \
    "instala Android SDK 36 + NDK 27.2 e exporta ANDROID_HOME"
  bash tools/llama_build.sh
fi
if [ $NEED_IOS -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  echo "== llama.cpp iOS (device + simulador, Metal embutido) =="
  xcodebuild -version >/dev/null 2>&1 || die "Xcode não encontrado" \
    "instala o Xcode e corre: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  bash tools/llama_build_ios.sh
fi

echo "== flutter pub get =="
flutter pub get >/dev/null

echo "== app =="
case "$(uname -s)" in
  Darwin)
    flutter build ios --no-codesign 2>&1 | tail -2
    flutter build ios --simulator 2>&1 | tail -2
    ;;
  Linux)
    flutter build apk --release 2>&1 | tail -2
    ;;
esac

echo "== BUILD_OK =="
