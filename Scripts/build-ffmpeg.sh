#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source_dir="$root/Vendor/ffmpeg"
prefix="$source_dir/build-macos"
resources="$root/Sources/WhisperTranscriber/Resources"

cd "$source_dir"
make distclean >/dev/null 2>&1 || true

# Keep the bundled decoder LGPL-only and limited to local Matroska audio decoding.
./configure \
  --prefix="$prefix" \
  --arch=arm64 \
  --target-os=darwin \
  --disable-debug \
  --disable-doc \
  --disable-network \
  --disable-autodetect \
  --disable-everything \
  --enable-ffmpeg \
  --enable-ffprobe \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-swresample \
  --enable-protocol=file \
  --enable-demuxer=matroska \
  --enable-muxer=pcm_f32le \
  --enable-encoder=pcm_f32le \
  --enable-filter=aresample \
  --enable-decoder=aac,ac3,alac,eac3,flac,mp3,opus,pcm_f32le,pcm_s16le,pcm_s24le,pcm_s32le,vorbis \
  --enable-parser=aac,ac3,flac,mpegaudio,opus,vp3,vorbis \
  --enable-runtime-cpudetect \
  --enable-small

make -j "$(sysctl -n hw.ncpu)"
mkdir -p "$resources"
cp ffmpeg "$resources/ffmpeg"
cp ffprobe "$resources/ffprobe"
chmod 755 "$resources/ffmpeg" "$resources/ffprobe"
