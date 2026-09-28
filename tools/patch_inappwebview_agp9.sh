#!/usr/bin/env bash
# Corrige o pacote `flutter_inappwebview_android` (pub cache) para o AGP 9.
#
# Problema: AGP 9 (Gradle 9.3.1) rejeita `getDefaultProguardFile('proguard-android.txt')`
# ("no longer supported since it includes -dontoptimize…") e o
# flutter_inappwebview_android 1.1.3 (último estável) ainda o chama em
# `android/build.gradle` — o `flutter build` rebenta na avaliação do projeto
# ':flutter_inappwebview_android'.
#
# Correção: renomear para `proguard-android-optimize.txt` — exatamente a migração
# que a mensagem do AGP pede e que o upstream já fez na 1.2.0-beta.3 (inutilizável
# por agora: a platform-interface beta quebra a API do flutter_inappwebview 6.1.5
# e das implementações ios/macos/windows 1.1.x).
#
# Idempotente; corre depois do `flutter pub get` (o pub cache não é regenerado por
# um get normal — só por `pub cache clean`/upgrade de versão, casos em que este
# script volta a ser preciso). Chamar também no macmini antes de builds iOS.
#
# Uso: bash tools/patch_inappwebview_agp9.sh [--check]
#   --check  só verifica (exit 1 se o patch for necessário); não escreve.

set -euo pipefail

CHECK_ONLY=""
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
PKG_DIR="$PUB_CACHE/hosted/pub.dev/flutter_inappwebview_android-1.1.3"
GRADLE="$PKG_DIR/android/build.gradle"
OLD="getDefaultProguardFile('proguard-android.txt')"
NEW="getDefaultProguardFile('proguard-android-optimize.txt')"

die() { echo "Erro: $1 — Solução: $2" >&2; exit 1; }

[ -f "$GRADLE" ] || die "pacote não encontrado em $GRADLE" \
  "corre 'flutter pub get' primeiro (ou define PUB_CACHE)"

if ! grep -qF "$OLD" "$GRADLE"; then
  if grep -qF "$NEW" "$GRADLE"; then
    echo "OK: patch AGP 9 já aplicado ($GRADLE)"
    exit 0
  fi
  die "ficheiro inesperado (nem '$OLD' nem '$NEW')" \
    "o flutter_inappwebview_android 1.1.3 mudou? rever o patch manualmente"
fi

if [ -n "$CHECK_ONLY" ]; then
  echo "FALTA: patch AGP 9 por aplicar em $GRADLE"
  exit 1
fi

# sed -i portável (GNU vs BSD): sufixo explícito faz backup em .agp9.bak
sed -i.agp9.bak "s/$OLD/$NEW/g" "$GRADLE"
echo "OK: patch AGP 9 aplicado (backup: $GRADLE.agp9.bak)"
