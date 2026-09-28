#!/usr/bin/env bash
# Instala e valida a app num iPhone FÍSICO a partir do macmini.
# Uso: ./instalar-iphone.sh            (auto-deteta o device ligado)
#      ./instalar-iphone.sh --test     (instala + corre o E2E de qualidade)
#
# Pré-requisitos (uma vez, ver docs/runbook-iphone-fisico.md):
#   1. iPhone ligado por USB ao macmini + "Confiar" + Developer Mode ON
#   2. Apple ID registado no Xcode (Settings > Accounts) — Personal Team
set -euo pipefail

PROJ="/Volumes/Ext2TB/Projects/offline-ai-mobile"
export PATH=/Volumes/Ext2TB/dev-tools/flutter/bin:$PATH
export LANG=en_US.UTF-8
cd "$PROJ"

echo "== 1. device ligado? =="
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/{print $2; exit}')
if [ -z "${UDID:-}" ]; then
  echo "Erro: nenhum iPhone detetado — Solução: liga o iPhone por USB ao macmini,"
  echo "      toca 'Confiar' no telemóvel e ativa Developer Mode (Definições > Privacidade)"
  exit 3
fi
echo "  device: $UDID"

echo "== 2. team de assinatura =="
TEAM=$(xcodebuild -showBuildSettings -project ios/Runner.xcodeproj 2>/dev/null | awk -F' = ' '/DEVELOPMENT_TEAM/{print $2; exit}')
if [ -z "${TEAM:-}" ]; then
  echo "Erro: sem DEVELOPMENT_TEAM — Solução: no Xcode (via AnyDesk): Settings > Accounts"
  echo "      > login do Apple ID; depois eu preencho o team automaticamente."
  exit 3
fi
echo "  team: $TEAM"

echo "== 3. build + instalação =="
flutter build ios --debug --dart-define=FLUTTER_TEST=false 2>&1 | tail -2
xcrun devicectl device install app --device "$UDID" build/ios/iphoneos/Runner.app 2>&1 | tail -2
xcrun devicectl device process launch --device "$UDID" dev.offlineai.offlineAiMobile 2>&1 | tail -1

if [ "${1:-}" = "--test" ]; then
  echo "== 4. E2E de qualidade (gate METAL real) =="
  flutter test integration_test -d "$UDID" 2>&1 | grep -E "TOOLLOOP|passed|failed|degenerado|\+[0-9]+ " | tail -6
fi

echo "== INSTALADO_NO_IPHONE =="
