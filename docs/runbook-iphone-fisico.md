# Runbook — gate final no iPhone físico

O que falta validar (única pendência real do projeto): **o Metal em dispositivo
Apple real** está equivalente ao macOS nativo (já verificado) — o simulador
não serve de gate porque o seu Metal é incompleto.

## O que é preciso do utilizador (5 minutos, uma vez)

1. **AnyDesk → macmini** → Xcode → *Settings → Accounts* → iniciar sessão com
   o Apple ID (Personal Team aparece como "Personal Team").
2. Ligar o iPhone por USB e tocar em **"Confiar"** ("Trust This Computer") +
   ativar *Developer Mode* (Definições → Privacidade → Developer Mode).

Depois disto, tudo é CLI (repetível quantas vezes quiser).

## O que eu executo a seguir (sem intervenção)

```bash
# 1. detetar o device
xcrun devicectl list devices
# 2. build + instalação (flutter regista o device no Personal Team)
cd /Volumes/Ext2TB/Projects/offline-ai-mobile
flutter run -d <UDID>            # ou: flutter build ipa --export-options-plist
# 3. gate de qualidade (o mesmo E2E, agora com METAL real)
flutter test integration_test -d <UDID>
```

## Critérios de aprovação (os mesmos do simulador + extras)

- [ ] `Laya decide` = valores do oráculo (billing/urgent)
- [ ] `MiniCPM5 gera texto` com o detector anti-mojibake VERDE
- [ ] `ToolLoop` termina com `final_answer` e resposta coerente
- [ ] **NOVO**: com `gpuLayers=-1` (Metal) a saída está limpa (é este o gate)
- [ ] Medir tok/s (CPU vs Metal) e registar no CoALA

Se o Metal em device real também corromper (improvável — o macOS nativo está
limpo): aplicar o roteiro do dossiê §Q6 (workarounds `GGML_METAL_TENSOR_DISABLE=1`
→ Q8_0 → tag nova) e, só se nada resolver, considerar as rotas MLX/LiteRT
(pesquisadas no dossiê M2/M3) ou o port nativo (M4/M5, 40–57 dias).

## Notas de signing (Personal Team, sem conta paga)

- Limites: 3 apps/device, profiles válidos 7 dias → rebuild semanal.
- Depois do 1º setup, tudo CLI: `xcodebuild -allowProvisioningUpdates` +
  `xcrun devicectl device install app`.
- Conta paga (99 USD/ano): profiles 1 ano, 100 devices, TestFlight.
