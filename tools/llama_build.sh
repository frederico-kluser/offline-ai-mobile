#!/usr/bin/env bash
# =============================================================================
# tools/llama_build.sh — build reproduzível do llama.cpp para Android
#
# Compila o llama.cpp (tag PINADA) como bibliotecas partilhadas para
# x86_64 (emulador) e arm64-v8a (device) e copia as .so para
# android/app/src/main/jniLibs/<abi>/ (empacotadas pela APK e carregadas
# pelo Dart via DynamicLibrary.open('libllama.so')).
#
# Uso:
#   ./tools/llama_build.sh              # ambos os ABIs
#   ./tools/llama_build.sh arm64-v8a    # um ABI
#   ./tools/llama_build.sh --force      # re-clona e reconfigura do zero
#
# Requisitos fixos (ver tools/llama_ffi.md):
#   - Android NDK 27.2.12479018
#   - CMake 3.22.1 (kit do Android SDK, com ninja)
# =============================================================================
set -euo pipefail

# ---- Pinagem ---------------------------------------------------------------
LLAMA_TAG="b11217"   # release com arquitetura/tokenizer MiniCPM5 (>= b10883)
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"

# ---- Paths da máquina ------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_DIR="$SCRIPT_DIR/llama.cpp"
BUILD_ROOT="$SCRIPT_DIR/llama-build"
JNI_LIBS="$PROJECT_DIR/android/app/src/main/jniLibs"

ANDROID_SDK="${ANDROID_SDK_HOME:-/home/ondokai/Android/Sdk}"
NDK="$ANDROID_SDK/ndk/27.2.12479018"
CMAKE_KIT="$ANDROID_SDK/cmake/3.22.1"
CMAKE="$CMAKE_KIT/bin/cmake"
NINJA="$CMAKE_KIT/bin/ninja"
TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"

ANDROID_PLATFORM="android-26"   # min API para DynamicLibrary.open por nome

ALL_ABIS=(x86_64 arm64-v8a)
ABIS=()
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    x86_64|arm64-v8a) ABIS+=("$arg") ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done
[ ${#ABIS[@]} -eq 0 ] && ABIS=("${ALL_ABIS[@]}")

# ---- Sanidade do toolchain -------------------------------------------------
[ -x "$CMAKE" ] || { echo "ERRO: cmake não encontrado em $CMAKE" >&2; exit 1; }
[ -x "$NINJA" ] || { echo "ERRO: ninja não encontrado em $NINJA" >&2; exit 1; }
[ -f "$TOOLCHAIN_FILE" ] || { echo "ERRO: toolchain não encontrado em $TOOLCHAIN_FILE" >&2; exit 1; }

# ---- Fonte pinada ----------------------------------------------------------
if [ "$FORCE" = "1" ] && [ -d "$LLAMA_DIR" ]; then
  echo ">> --force: a remover $LLAMA_DIR"
  rm -rf "$LLAMA_DIR"
fi
if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo ">> a clonar $LLAMA_REPO @ $LLAMA_DIR"
  git clone --depth 1 --branch "$LLAMA_TAG" "$LLAMA_REPO" "$LLAMA_DIR"
else
  HAVE_TAG="$(git -C "$LLAMA_DIR" describe --tags --exact-match 2>/dev/null || echo none)"
  if [ "$HAVE_TAG" != "$LLAMA_TAG" ]; then
    echo "ERRO: $LLAMA_DIR está em '$HAVE_TAG', esperado '$LLAMA_TAG' (use --force)" >&2
    exit 1
  fi
  echo ">> fonte já presente: $LLAMA_DIR ($LLAMA_TAG)"
fi

# ---- Build por ABI ---------------------------------------------------------
for ABI in "${ABIS[@]}"; do
  BUILD_DIR="$BUILD_ROOT/$ABI"
  echo "=============================================================="
  echo ">> llama.cpp $LLAMA_TAG | ABI=$ABI | $ANDROID_PLATFORM"
  echo "=============================================================="

  "$CMAKE" -S "$LLAMA_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_MTMD=OFF

  "$CMAKE" --build "$BUILD_DIR" --target llama -j "$(nproc)"

  # ---- Publicação em jniLibs ------------------------------------------------
  DEST="$JNI_LIBS/$ABI"
  mkdir -p "$DEST"
  # O CMake do llama.cpp concentra as .so partilhadas em <build>/bin/.
  found=0
  for so in "$BUILD_DIR"/bin/libllama.so "$BUILD_DIR"/bin/libggml*.so; do
    [ -f "$so" ] || continue
    cp -v "$so" "$DEST/"
    found=1
  done
  [ "$found" = "1" ] || { echo "ERRO: nenhuma .so encontrada em $BUILD_DIR" >&2; exit 1; }

  echo ">> $ABI publicado em $DEST:"
  for f in "$DEST"/*.so; do
    echo "   $(basename "$f") — $(file -b "$f" | cut -c1-60)"
  done
done

echo ">> concluído: $(printf '%s ' "${ABIS[@]}")→ $JNI_LIBS"