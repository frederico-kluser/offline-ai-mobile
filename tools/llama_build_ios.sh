#!/usr/bin/env bash
# =============================================================================
# tools/llama_build_ios.sh — llama.cpp b12088 para iOS (device + simulador)
#
# Compila libllama + libmtmd + common + ggml como estáticas, com Metal
# embutido, e empacota num XCFramework em ios/pods/llama_ffi/.
#
# A revisão b12088 inclui LFM3, libmtmd (visão/vídeo/áudio) e o endpoint
# /v1/systemone; o Podfile faz force_load de liboffline_llm.a.
#
# Requisitos: Xcode 27+, CMake, ninja (ou Makefiles), macOS.
# =============================================================================
set -euo pipefail

TAG="${LLAMA_TAG:-b12088}"
MIN_IOS="${MIN_IOS:-16.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${LLAMA_DIR:-$HERE/llama.cpp}"
OUT="$HERE/../ios/pods/llama_ffi"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
else
  HAVE="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || echo none)"
  if [ "$HAVE" != "$TAG" ]; then
    git -C "$SRC" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
    git -C "$SRC" checkout -q "$TAG"
  fi
fi

build() { # $1=build-dir $2=sysroot
  cmake -S "$SRC" -B "$HERE/$1" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    ${2:+-DCMAKE_OSX_SYSROOT="$2"} \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_COMMON=ON \
    -DLLAMA_BUILD_MTMD=ON \
    -DLLAMA_BUILD_APPS=OFF
  cmake --build "$HERE/$1" --config Release --target llama mtmd \
    --parallel "$(sysctl -n hw.ncpu)"
}

echo "== device (iphoneos, arm64) =="
build build-ios-device iphoneos
echo "== simulador (iphonesimulator, arm64) =="
build build-ios-sim iphonesimulator

# Bundle estático por plataforma (libtool do Xcode) + XCFramework
STAGE="$HERE/build-ios-xcframework"
rm -rf "$STAGE" "$OUT/llama.xcframework"
mkdir -p "$STAGE/device" "$STAGE/sim" "$OUT"

find_libs() {
  find "$1" -name "lib*.a" -path "*Release*" \
    | grep -vE "ggml-BLAS|ggml-cpu_s" | sort
}

DEVICE_LIBS="$(find_libs "$HERE/build-ios-device")"
SIM_LIBS="$(find_libs "$HERE/build-ios-sim")"
[ -n "$DEVICE_LIBS" ] || { echo "ERRO: sem .a device" >&2; exit 1; }
[ -n "$SIM_LIBS" ] || { echo "ERRO: sem .a simulador" >&2; exit 1; }
echo "$DEVICE_LIBS" | grep -q "libmtmd.a" || {
  echo "ERRO: libmtmd.a não foi compilada (LFM3 multimodal exige libmtmd)" >&2
  exit 1
}

# shellcheck disable=SC2086
libtool -static -o "$STAGE/device/liboffline_llm.a" $DEVICE_LIBS
# shellcheck disable=SC2086
libtool -static -o "$STAGE/sim/liboffline_llm.a" $SIM_LIBS

# headers (llama.h + ggml.h + mtmd.h) para referência/FFI
mkdir -p "$STAGE/Headers"
cp "$SRC/include/llama.h" "$SRC/ggml/include/ggml.h" "$STAGE/Headers/" 2>/dev/null || true
cp "$SRC/tools/mtmd/mtmd.h" "$STAGE/Headers/" 2>/dev/null || true

xcodebuild -create-xcframework \
  -library "$STAGE/device/liboffline_llm.a" -headers "$STAGE/Headers" \
  -library "$STAGE/sim/liboffline_llm.a" -headers "$STAGE/Headers" \
  -output "$OUT/llama.xcframework"

echo "== XCFramework =="
ls -la "$OUT/llama.xcframework"/*/ | head -8
echo "LLAMA_IOS_OK ($TAG)"
