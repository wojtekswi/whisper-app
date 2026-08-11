#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source_dir="$root/Vendor/whisper.cpp"
build_dir="$source_dir/build-macos"

cmake -S "$source_dir" -B "$build_dir" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" --config Release -j "$(sysctl -n hw.ncpu)"
