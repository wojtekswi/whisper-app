#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/WhisperTranscriber.app"
output="$root/build/WhisperTranscriber-macos-arm64.dmg"
volume_name="Whisper Transcriber"
stage="$(mktemp -d "$root/build/dmg-stage.XXXXXX")"

if [[ ! -d "$app" ]]; then
  print -u2 "Missing $app. Build, notarize, and staple the app before creating a DMG."
  exit 1
fi

xcrun stapler validate "$app"

cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

cp -R "$app" "$stage/Whisper Transcriber.app"
ln -s /Applications "$stage/Applications"

rm -f "$output"
hdiutil create -volname "$volume_name" -srcfolder "$stage" -ov -format UDZO -imagekey zlib-level=9 "$output"
codesign --force --sign "${SIGNING_IDENTITY:-Developer ID Application: GGS IT CONSULTING Sp. z o.o. (MLPCTPHBYK)}" "$output"
print "Created $output"
