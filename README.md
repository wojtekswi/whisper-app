# Whisper Transcriber

Native macOS app for transcribing one audio or video file locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp), previewing timestamped segments, and exporting WebVTT subtitles. Models are downloaded on demand and stored outside the app bundle.

## Requirements

- Apple Silicon Mac running macOS 15 or later
- Xcode 26 with Swift 6.2
- CMake and make

## Build And Run

Clone with the native dependencies:

```sh
git clone --recurse-submodules https://github.com/wojtekswi/whisper-app.git
cd whisper-app
```

Build whisper.cpp before any Swift build, test, or run command:

```sh
zsh Scripts/build-whisper.sh
swift run WhisperTranscriber
```

## Test

```sh
swift test
swift test --filter WebVTTEncoderTests
```

## Package

Build a signed release app at `build/WhisperTranscriber.app`:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh Scripts/build-app.sh
```

The packaging script compiles `whisper-icon.icon`, rebuilds whisper.cpp and the
constrained arm64 FFmpeg binaries, then signs the app.

Create a drag-to-Applications DMG after notarizing and stapling the app:

```sh
zsh Scripts/build-dmg.sh
```

The DMG opens with `Whisper Transcriber.app` and an `Applications` shortcut.
Drag the app icon onto `Applications` to install it. Submit and staple the DMG
itself before sharing it as a GitHub Release asset.

## Notes

- `Vendor/whisper.cpp` and `Vendor/ffmpeg` are pinned Git submodules. After a non-recursive clone, run `git submodule update --init --recursive`.
- Models are cached in `~/Library/Application Support/Whisper Transcriber/Models/`.
- FFmpeg is bundled only to decode Matroska (`.mkv`) media. AVFoundation handles other supported audio and video formats.
