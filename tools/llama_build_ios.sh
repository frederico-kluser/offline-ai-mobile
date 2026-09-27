#!/usr/bin/env bash
# Compila o llama.cpp (tag pinada) para iOS: device arm64 + simulador arm64,
# com Metal embutido, e empacota como XCFramework estático para o Runner.
# Reproduzível: correr de tools/ do projeto. Requer Xcode + cmake.
set -euo pipefail

TAG="b11217"          # mesma tag do build Android (tem MiniCPM5 + parser minicpm5)
MIN_IOS="16.0"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/llama.cpp"
OUT="$HERE/../ios/Frameworks"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
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
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APPS=OFF
  cmake --build "$HERE/$1" --config Release --target llama --parallel "$(sysctl -n hw.ncpu)"
}

echo "== device (iphoneos, arm64) =="
build build-ios-device iphoneos
echo "== simulador (iphonesimulator, arm64) =="
build build-ios-sim iphonesimulator

# Bundle estático por plataforma (libtool do Xcode) + XCFramework
STAGE="$HERE/build-ios-xcframework"
rm -rf "$STAGE" "$OUT/llama.xcframework"
mkdir -p "$STAGE/device" "$STAGE/sim" "$OUT"

find_libs() { find "$1" -name "lib*.a" -path "*Release*" | grep -vE "ggml-BLAS|ggml-cpu_s" | sort; }

libtool -static -o "$STAGE/device/liboffline_llm.a" $(find_libs "$HERE/build-ios-device")
libtool -static -o "$STAGE/sim/liboffline_llm.a" $(find_libs "$HERE/build-ios-sim")

# headers (llama.h + ggml.h) para referência
mkdir -p "$STAGE/Headers"
cp "$SRC/include/llama.h" "$SRC/ggml/include/ggml.h" "$STAGE/Headers/" 2>/dev/null || true

xcodebuild -create-xcframework \
  -library "$STAGE/device/liboffline_llm.a" -headers "$STAGE/Headers" \
  -library "$STAGE/sim/liboffline_llm.a" -headers "$STAGE/Headers" \
  -output "$OUT/llama.xcframework"

echo "== XCFramework =="
ls -la "$OUT/llama.xcframework"/*/ | head -8
echo "LLAMA_IOS_OK"
