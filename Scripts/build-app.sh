#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/WhisperTranscriber.app"
binary="$root/.build/arm64-apple-macosx/release/WhisperTranscriber"
resource_bundle="$root/.build/arm64-apple-macosx/release/WhisperTranscriber_WhisperTranscriber.bundle"
signing_identity="${SIGNING_IDENTITY:-Developer ID Application: GGS IT CONSULTING Sp. z o.o. (MLPCTPHBYK)}"

zsh "$root/Scripts/build-whisper.sh"
zsh "$root/Scripts/build-ffmpeg.sh"
swift build -c release --package-path "$root" --product WhisperTranscriber

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/WhisperTranscriber"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/WhisperTranscriber.entitlements" "$app/Contents/Resources/"
cp "$root/Resources/WhisperTranscriber.icns" "$app/Contents/Resources/"
cp "$root/Resources/FFmpeg-LICENSE.txt" "$app/Contents/Resources/"
cp -R "$resource_bundle" "$app/Contents/Resources/"
codesign --force --options runtime --timestamp --sign "$signing_identity" "$app/Contents/Resources/WhisperTranscriber_WhisperTranscriber.bundle/ffmpeg"
codesign --force --options runtime --timestamp --sign "$signing_identity" "$app/Contents/Resources/WhisperTranscriber_WhisperTranscriber.bundle/ffprobe"
codesign --force --options runtime --timestamp --sign "$signing_identity" --entitlements "$root/Resources/WhisperTranscriber.entitlements" "$app"
