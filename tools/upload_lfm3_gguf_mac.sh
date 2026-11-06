#!/usr/bin/env bash
# Upload dos GGUF/mmproj da suíte LFM3/d1 para o release do espelho.
# Corre no Mac mini (rede rápida); usa curl + shasum + gh autenticado.
set -euo pipefail

OUT="${OUT:-/Volumes/Ext2TB/tmp-models/lfm3-release}"
REPO="${GITHUB_REPO:-frederico-kluser/lfm3-mobile-models}"
TAG="${TAG:-models-lfm3-suite-v1}"
mkdir -p "$OUT"

# asset|repo|sha256
FILES=$(cat <<'EOF'
LFM3-1.7B-QAD-Q4_0.gguf|LiquidAI/LFM3-1.7B-GGUF|43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452
LFM3-1.7B-Q4_K_M.gguf|LiquidAI/LFM3-1.7B-GGUF|3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4
LFM3-1.7B-Q8_0.gguf|LiquidAI/LFM3-1.7B-GGUF|8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6
LFM3-VL-2B-Q4_K_M.gguf|LiquidAI/LFM3-VL-2B-GGUF|56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb
mmproj-LFM3-VL-2B-Q8_0.gguf|LiquidAI/LFM3-VL-2B-GGUF|c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab
LFM3-Audio-2B-Q4_K_M.gguf|LiquidAI/LFM3-Audio-2B-GGUF|9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2
mmproj-LFM3-Audio-2B-Q8_0.gguf|LiquidAI/LFM3-Audio-2B-GGUF|2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365
LFM3-Omni-2B-Q4_K_M.gguf|LiquidAI/LFM3-Omni-2B-GGUF|9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2
mmproj-LFM3-Omni-2B-Q4_K_M.gguf|LiquidAI/LFM3-Omni-2B-GGUF|0a746c0794782a16d4456b230c2a0b5888a2d94a6677211edbed7d7a4177a39a
d1-2B-Q4_K_M.gguf|LiquidAI/d1-2B-GGUF|adca5789ad30ae6027e8e936749bb9f19673097492ab26fa1c5b69643ca50b4b
mmproj-d1-2B-Q8_0.gguf|LiquidAI/d1-2B-GGUF|62cc6d74fd1e5b1d6b48518566bf4c0cfd2468079a0c096ea323b74eed01e0d1
d1-Omni-2B-Q8_0.gguf|LiquidAI/d1-Omni-2B-GGUF|aedf1a7c341b4281979423dbc39e9c3d3ad1da8834156c8e75af5399ca3b0861
mmproj-d1-Omni-2B-Q8_0.gguf|LiquidAI/d1-Omni-2B-GGUF|31778160ac0ec70f9b59f296aa1c8e70cbd1eb7e3a3ff873d695aaa4c7b8d674
d1-omni-600M-Q8_0.gguf|LiquidAI/d1-omni-600M-GGUF|cd94463f4cac9c700ec6750df8df005bb6846de410e159d1f5e985e1171693d3
mmproj-d1-omni-600M-Q8_0.gguf|LiquidAI/d1-omni-600M-GGUF|df887978550cdbb45f0f57d7b436a0f844689f9f561395a144ced500606c3a89
EOF
)

while IFS='|' read -r asset repo sha; do
  [ -n "$asset" ] || continue
  f="$OUT/$asset"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$sha" ]; then
    echo "OK   $asset (já presente)"
    continue
  fi
  echo ">> $asset"
  rm -f "$f" "$f.part"
  curl -L --fail --retry 3 --retry-delay 5 \
    "https://huggingface.co/$repo/resolve/main/$asset" -o "$f.part"
  actual="$(shasum -a 256 "$f.part" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    echo "ERRO: SHA-256 de $asset não confere ($actual)" >&2
    exit 1
  fi
  mv "$f.part" "$f"
  echo "OK   $asset ($(du -h "$f" | awk '{print $1}'))"
done <<< "$FILES"

echo "== a enviar para $REPO @ $TAG =="
gh release upload "$TAG" "$OUT"/*.gguf --repo "$REPO" --clobber
echo "== UPLOAD_OK =="
