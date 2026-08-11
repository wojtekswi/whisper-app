#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source_icon="$root/whisper-icon.icon"
output_icon="$root/Resources/WhisperTranscriber.icns"
temporary_directory="$(mktemp -d "$root/build/icon-compile.XXXXXX")"

if [[ ! -d "$source_icon" ]]; then
  print -u2 "Missing $source_icon"
  exit 1
fi

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

xcrun actool \
  --compile "$temporary_directory" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon "whisper-icon" \
  --output-partial-info-plist "$temporary_directory/partial.plist" \
  "$source_icon"

cp "$temporary_directory/whisper-icon.icns" "$output_icon"
