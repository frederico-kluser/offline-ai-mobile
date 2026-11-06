#!/usr/bin/env bash
# =============================================================================
# publish_lfm3_release.sh — descarrega a suíte LFM3/d1 do Hugging Face,
# verifica SHA-256 e publica no GitHub Release do espelho.
#
#   bash tools/publish_lfm3_release.sh             # descarrega + publica
#   bash tools/publish_lfm3_release.sh --dry-run   # valida plano/hashes
#
# Requisitos: gh autenticado, huggingface-hub (hf) ou curl, python3,
# sha256sum (Linux) ou shasum (macOS).
#
# O GitHub Releases impõe 2 GiB por ativo; o script recusa ficheiros maiores.
# Nenhum GGUF/mmproj recomendado chega a esse limite (o maior é ~1,85 GB).
# =============================================================================
set -euo pipefail

REPO="${GITHUB_REPO:-frederico-kluser/lfm3-mobile-models}"
TAG="${TAG:-models-lfm3-suite-v1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${STAGING:-$ROOT/staging}"
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

ok() { echo "  OK    $1"; }
die() { echo "Erro: $1 — Solução: $2" >&2; exit 1; }

command -v gh >/dev/null || die "gh não encontrado" "instala GitHub CLI e faz gh auth login"
command -v python3 >/dev/null || die "python3 não encontrado" "instala Python 3"
if command -v sha256sum >/dev/null; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null; then
  SHA_CMD="shasum -a 256"
else
  die "sha256sum/shasum não encontrado" "instala coreutils ou usa macOS"
fi
if command -v hf >/dev/null; then
  DOWNLOADER="hf"
else
  DOWNLOADER="curl"
  echo "aviso: hf não encontrado; a usar curl direto do Hugging Face"
fi

mkdir -p "$STAGING"
cd "$ROOT"

# asset|repo|path|sha256
FILES=$(cat <<'EOF'
LFM3-1.7B-QAD-Q4_0.gguf|LiquidAI/LFM3-1.7B-GGUF|LFM3-1.7B-QAD-Q4_0.gguf|43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452
LFM3-1.7B-Q4_K_M.gguf|LiquidAI/LFM3-1.7B-GGUF|LFM3-1.7B-Q4_K_M.gguf|3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4
LFM3-1.7B-Q8_0.gguf|LiquidAI/LFM3-1.7B-GGUF|LFM3-1.7B-Q8_0.gguf|8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6
LFM3-VL-2B-Q4_K_M.gguf|LiquidAI/LFM3-VL-2B-GGUF|LFM3-VL-2B-Q4_K_M.gguf|56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb
mmproj-LFM3-VL-2B-Q8_0.gguf|LiquidAI/LFM3-VL-2B-GGUF|mmproj-LFM3-VL-2B-Q8_0.gguf|c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab
LFM3-Audio-2B-Q4_K_M.gguf|LiquidAI/LFM3-Audio-2B-GGUF|LFM3-Audio-2B-Q4_K_M.gguf|9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2
mmproj-LFM3-Audio-2B-Q8_0.gguf|LiquidAI/LFM3-Audio-2B-GGUF|mmproj-LFM3-Audio-2B-Q8_0.gguf|2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365
LFM3-Omni-2B-Q4_K_M.gguf|LiquidAI/LFM3-Omni-2B-GGUF|LFM3-Omni-2B-Q4_K_M.gguf|9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2
mmproj-LFM3-Omni-2B-Q4_K_M.gguf|LiquidAI/LFM3-Omni-2B-GGUF|mmproj-LFM3-Omni-2B-Q4_K_M.gguf|0a746c0794782a16d4456b230c2a0b5888a2d94a6677211edbed7d7a4177a39a
d1-2B-Q4_K_M.gguf|LiquidAI/d1-2B-GGUF|d1-2B-Q4_K_M.gguf|adca5789ad30ae6027e8e936749bb9f19673097492ab26fa1c5b69643ca50b4b
mmproj-d1-2B-Q8_0.gguf|LiquidAI/d1-2B-GGUF|mmproj-d1-2B-Q8_0.gguf|62cc6d74fd1e5b1d6b48518566bf4c0cfd2468079a0c096ea323b74eed01e0d1
d1-Omni-2B-Q8_0.gguf|LiquidAI/d1-Omni-2B-GGUF|d1-Omni-2B-Q8_0.gguf|aedf1a7c341b4281979423dbc39e9c3d3ad1da8834156c8e75af5399ca3b0861
mmproj-d1-Omni-2B-Q8_0.gguf|LiquidAI/d1-Omni-2B-GGUF|mmproj-d1-Omni-2B-Q8_0.gguf|31778160ac0ec70f9b59f296aa1c8e70cbd1eb7e3a3ff873d695aaa4c7b8d674
d1-omni-600M-Q8_0.gguf|LiquidAI/d1-omni-600M-GGUF|d1-omni-600M-Q8_0.gguf|cd94463f4cac9c700ec6750df8df005bb6846de410e159d1f5e985e1171693d3
mmproj-d1-omni-600M-Q8_0.gguf|LiquidAI/d1-omni-600M-GGUF|mmproj-d1-omni-600M-Q8_0.gguf|df887978550cdbb45f0f57d7b436a0f844689f9f561395a144ced500606c3a89
d1-2b-onnx-q4f16_decoder_q4f16.onnx|LiquidAI/d1-2B-ONNX|onnx/decoder_q4f16.onnx|3ac6c50361b1f262b4bf1ac250459eee49bde2620f704b1785fa355cc68117ab
d1-2b-onnx-q4f16_decoder_q4f16.onnx_data|LiquidAI/d1-2B-ONNX|onnx/decoder_q4f16.onnx_data|977616f1fcc543490a49c7e54aec98a6398566c7868e3adf0134688a9b701426
d1-2b-onnx-q4f16_vision_encoder_fp16.onnx|LiquidAI/d1-2B-ONNX|onnx/vision_encoder_fp16.onnx|d6f3ed9a9211feb09d146fb8d550517a7b779940d081eb1604127bfe23ca2e6a
d1-2b-onnx-q4f16_vision_encoder_fp16.onnx_data|LiquidAI/d1-2B-ONNX|onnx/vision_encoder_fp16.onnx_data|ca65da8ca1d95481f71cc669266284f5be64046df1c7d53e8ca51cf3f4643a05
d1-2b-onnx-q4f16_tokenizer.json|LiquidAI/d1-2B-ONNX|tokenizer.json|a39eed58008cbcbc09e5b629b81338a654269c64cd13348aaa6090f4db75c7e7
d1-2b-onnx-q4f16_processor_config.json|LiquidAI/d1-2B-ONNX|processor_config.json|37396ef3370083a04381ef25f9e1b50dec184b8cdcf08cf718feb8944ad8f3bc
d1-2b-onnx-q4f16_chat_template.jinja|LiquidAI/d1-2B-ONNX|chat_template.jinja|17f33d44f7bd01aa94623dd8bf8e4e0ef80580a725ef8b71dc6b78f6bcc11700
d1-2b-onnx-q4f16_config.json|LiquidAI/d1-2B-ONNX|config.json|ffdc4c996152d23dbe8a2659a8c6aabe2992aa3fa3a41601dd0fca8771d6f332
d1-omni-2b-onnx-q4f16_decoder_q4f16.onnx|LiquidAI/d1-Omni-2B-ONNX|onnx/decoder_q4f16.onnx|59bed92a6ec5df6462aa02ad8ac5be342afecfa8525539852a9a5deb48d7f221
d1-omni-2b-onnx-q4f16_decoder_q4f16.onnx_data|LiquidAI/d1-Omni-2B-ONNX|onnx/decoder_q4f16.onnx_data|bf8a038340291e07e6864243016eae55e9c183523d446fca608b5d82acceed1f
d1-omni-2b-onnx-q4f16_vision_encoder_fp16.onnx|LiquidAI/d1-Omni-2B-ONNX|onnx/vision_encoder_fp16.onnx|bad561d7f73e25a6df537bdb52cb1bddacaf607d807a44d62513c4d37c9f17a1
d1-omni-2b-onnx-q4f16_vision_encoder_fp16.onnx_data|LiquidAI/d1-Omni-2B-ONNX|onnx/vision_encoder_fp16.onnx_data|bdb6d246785a13c39e24a486d07510f2c02285c43c83cf52535b30c1ca8b403d
d1-omni-2b-onnx-q4f16_audio_encoder_fp16.onnx|LiquidAI/d1-Omni-2B-ONNX|onnx/audio_encoder_fp16.onnx|20a7c84d1f3b5ca39e6f1903b9482ec68bc16a841b637d4684b72c679036110e
d1-omni-2b-onnx-q4f16_audio_encoder_fp16.onnx_data|LiquidAI/d1-Omni-2B-ONNX|onnx/audio_encoder_fp16.onnx_data|d7d67ea09bda583fe346097af9f06ba03c92e47870e475f1c65604677581b878
d1-omni-2b-onnx-q4f16_tokenizer.json|LiquidAI/d1-Omni-2B-ONNX|tokenizer.json|41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44
d1-omni-2b-onnx-q4f16_processor_config.json|LiquidAI/d1-Omni-2B-ONNX|processor_config.json|2288d34b7c0579593258b1c083de4ab8328a842fdb0190977363e573dbdcd0e5
EOF
)

echo "== 1. a validar o plano (2 GiB por ativo, hashes conhecidos) =="
TOTAL=0
while IFS='|' read -r asset repo path sha; do
  [ -n "$asset" ] || continue
  [ -n "$sha" ] || die "hash em falta para $asset" "preenche o SHA-256 no script"
  TOTAL=$((TOTAL + 1))
  ok "$asset"
done <<< "$FILES"
echo "   $TOTAL ativos planeados"

check_size() {
  local f="$1"
  local size
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -ge 2147483648 ]; then
    die "ficheiro $f ($size bytes) ≥ 2 GiB" "não pode ser ativo do GitHub Releases"
  fi
}

if [ "$DRY" = "1" ]; then
  echo "== dry-run: a verificar manifesto e licença =="
  [ -f "$ROOT/manifest.json" ] || die "manifest.json em falta" "gera com tools/dump_model_manifest.dart"
  [ -f "$ROOT/SHA256SUMS.txt" ] || die "SHA256SUMS.txt em falta" "executa o script sem --dry-run"
  [ -f "$ROOT/LICENSE" ] || die "LICENSE em falta" "copia a LFM Open License v1.0"
  python3 - "$ROOT/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
assert m['schema'] == 1
assert m['release'] == 'models-lfm3-suite-v1'
print(f"  manifesto: {len(m['bundles'])} bundles")
PY
  echo "== DRY_RUN_OK: nada foi publicado =="
  exit 0
fi

echo "== 2. a descarregar do Hugging Face para $STAGING =="
while IFS='|' read -r asset repo path sha; do
  [ -n "$asset" ] || continue
  out="$STAGING/$asset"
  if [ -f "$out" ]; then
    actual=$($SHA_CMD "$out" | awk '{print $1}')
    if [ "$actual" = "$sha" ]; then
      ok "$asset já presente e verificado"
      check_size "$out"
      continue
    fi
    echo ">> hash errado em $asset; a re-descarregar"
    rm -f "$out"
  fi
  tmp="$STAGING/.tmp-$asset"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  echo ">> $repo/$path"
  if [ "$DOWNLOADER" = "hf" ]; then
    hf download "$repo" "$path" --local-dir "$tmp" >/dev/null
    src="$tmp/$path"
  else
    src="$tmp/$(basename "$path")"
    curl --fail --location --retry 3 --retry-delay 5 \
      "https://huggingface.co/$repo/resolve/main/$path" -o "$src"
  fi
  [ -f "$src" ] || die "download de $path falhou" "verifica a rede/HF"
  mv "$src" "$out"
  rm -rf "$tmp"
  actual=$($SHA_CMD "$out" | awk '{print $1}')
  [ "$actual" = "$sha" ] || die "SHA-256 de $asset não confere" "re-descarrega"
  check_size "$out"
  ok "$asset ($(du -h "$out" | awk '{print $1}'))"
done <<< "$FILES"

echo "== 3. a publicar o release $TAG em $REPO =="
cp -f "$ROOT/manifest.json" "$ROOT/SHA256SUMS.txt" "$ROOT/LICENSE" "$ROOT/README.md" "$STAGING/"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" \
    --repo "$REPO" \
    --title "Liquid AI LFM3 & d1 · suite offline móvel ($TAG)" \
    --notes "Artefactos GGUF/mmproj e subgrafos ONNX verificados por SHA-256, com a licença LFM Open License v1.0. Consulte manifest.json e SHA256SUMS.txt."
fi
gh release upload "$TAG" "$STAGING"/* --repo "$REPO" --clobber

echo "== CONCLUÍDO: https://github.com/$REPO/releases/tag/$TAG =="
