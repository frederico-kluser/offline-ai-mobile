#!/usr/bin/env bash
# =============================================================================
# tools/llama_build.sh — build reproduzível do llama.cpp b12088 para Android
#
# Compila libllama.so, libmtmd.so e libggml*.so para arm64-v8a (device) e
# x86_64 (emulador), e copia-os para android/app/src/main/jniLibs/<abi>/.
#
# A revisão b12088 inclui:
#   - arquitetura LLM_ARCH_LFM3 e chat template LFM3 (desde b11938);
#   - templates de vídeo MTMD_VIDEO_TEMPLATE_LFM3 / _LFM3_OMNI (b11960+);
#   - fix #31374 (JSON grammar + enable_thinking=false) em b12005;
#   - tensores NVFP4 (PR #31608).
#
# Uso:
#   ./tools/llama_build.sh              # ambos os ABIs
#   ./tools/llama_build.sh arm64-v8a    # um ABI
#   ./tools/llama_build.sh --force      # re-clona e reconfigura do zero
#
# Requisitos: Android NDK 27.2.12479018, CMake 3.22.1 (kit do SDK), ninja.
# =============================================================================
set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b12088}"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_DIR="${LLAMA_DIR:-$PWD/third_party/llama.cpp}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/llama-android}"
JNI_LIBS="${JNI_LIBS:-$PWD/android/app/src/main/jniLibs}"

ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
NDK="${NDK_PATH:-$ANDROID_SDK/ndk/27.2.12479018}"
CMAKE_KIT="$ANDROID_SDK/cmake/3.22.1"
CMAKE="${CMAKE:-$CMAKE_KIT/bin/cmake}"
NINJA="${NINJA:-$CMAKE_KIT/bin/ninja}"
TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-28}"

ALL_ABIS=(arm64-v8a x86_64)
ABIS=()
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    arm64-v8a|x86_64) ABIS+=("$arg") ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done
[ ${#ABIS[@]} -eq 0 ] && ABIS=("${ALL_ABIS[@]}")

# ---- Sanidade do toolchain -------------------------------------------------
if [ ! -x "$CMAKE" ]; then
  CMAKE="$(command -v cmake || true)"
fi
if [ ! -x "$NINJA" ]; then
  NINJA="$(command -v ninja || true)"
fi
[ -n "$CMAKE" ] && [ -x "$CMAKE" ] || { echo "ERRO: cmake não encontrado" >&2; exit 1; }
[ -n "$NINJA" ] && [ -x "$NINJA" ] || { echo "ERRO: ninja não encontrado" >&2; exit 1; }
[ -f "$TOOLCHAIN_FILE" ] || { echo "ERRO: toolchain em falta: $TOOLCHAIN_FILE" >&2; exit 1; }

# ---- Fonte pinada ----------------------------------------------------------
if [ "$FORCE" = "1" ] && [ -d "$LLAMA_DIR" ]; then
  echo ">> --force: a remover $LLAMA_DIR"
  rm -rf "$LLAMA_DIR"
fi
if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo ">> a clonar $LLAMA_REPO @ $LLAMA_TAG"
  git clone --depth 1 --branch "$LLAMA_TAG" "$LLAMA_REPO" "$LLAMA_DIR"
else
  HAVE_TAG="$(git -C "$LLAMA_DIR" describe --tags --exact-match 2>/dev/null || echo none)"
  if [ "$HAVE_TAG" != "$LLAMA_TAG" ]; then
    echo ">> a atualizar $LLAMA_DIR: $HAVE_TAG -> $LLAMA_TAG"
    git -C "$LLAMA_DIR" fetch --depth 1 origin "refs/tags/$LLAMA_TAG:refs/tags/$LLAMA_TAG"
    git -C "$LLAMA_DIR" checkout -q "$LLAMA_TAG"
  fi
fi

# ---- Build por ABI ---------------------------------------------------------
for ABI in "${ABIS[@]}"; do
  BUILD_DIR="$BUILD_ROOT/$ABI"
  echo "=============================================================="
  echo ">> llama.cpp $LLAMA_TAG | ABI=$ABI | $ANDROID_PLATFORM"
  echo "=============================================================="

  EXTRA_CFLAGS=""
  if [ "$ABI" = "arm64-v8a" ]; then
    EXTRA_CFLAGS="-march=armv8.2-a+dotprod+fp16"
  fi

  "$CMAKE" -S "$LLAMA_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$EXTRA_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$EXTRA_CFLAGS" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_COMMON=ON \
    -DLLAMA_BUILD_MTMD=ON

  "$CMAKE" --build "$BUILD_DIR" --config Release --target llama mtmd \
    -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

  # ---- Publicação em jniLibs ------------------------------------------------
  DEST="$JNI_LIBS/$ABI"
  mkdir -p "$DEST"
  found_llama=0
  found_mtmd=0
  for so in "$BUILD_DIR"/bin/libllama.so "$BUILD_DIR"/bin/libmtmd.so "$BUILD_DIR"/bin/libggml*.so; do
    [ -f "$so" ] || continue
    cp -v "$so" "$DEST/"
    case "$(basename "$so")" in
      libllama.so) found_llama=1 ;;
      libmtmd.so) found_mtmd=1 ;;
    esac
  done
  [ "$found_llama" = "1" ] || { echo "ERRO: libllama.so não encontrada em $BUILD_DIR/bin" >&2; exit 1; }
  [ "$found_mtmd" = "1" ] || { echo "ERRO: libmtmd.so não encontrada (libmtmd obrigatório para LFM3)" >&2; exit 1; }

  echo ">> $ABI publicado em $DEST:"
  for f in "$DEST"/*.so; do
    echo "   $(basename "$f") — $(stat -c %s "$f" 2>/dev/null || stat -f %z "$f") bytes"
  done
done

echo ">> LLAMA_ANDROID_OK ($LLAMA_TAG)"
