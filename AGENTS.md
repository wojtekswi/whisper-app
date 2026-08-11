# Whisper Transcriber

## Toolchain And Commands

- This is an Apple-Silicon macOS 15+ Swift Package (`Package.swift`), tested here with Xcode 26 / Swift 6.2.
- `zsh Scripts/build-whisper.sh` is required before `swift build` or `swift test`: the package links its native libraries from `Vendor/whisper.cpp/build-macos/`.
- Run all unit tests with `swift test`; run the current focused suite with `swift test --filter WebVTTEncoderTests`.
- `zsh Scripts/build-app.sh` is the release-packaging command. It rebuilds whisper.cpp and FFmpeg, runs `swift build -c release`, recreates `build/WhisperTranscriber.app`, bundles resources, and code-signs the app and bundled `ffmpeg`/`ffprobe` executables.
- `build-app.sh` defaults `SIGNING_IDENTITY` to a specific Developer ID identity; set that environment variable when the default is unavailable.
- `zsh Scripts/build-ffmpeg.sh` runs `make distclean`, configures a constrained arm64 LGPL-only FFmpeg build, and overwrites `Sources/WhisperTranscriber/Resources/ffmpeg` and `ffprobe`. Do not treat those executables as hand-maintained source files.

## Code Boundaries

- `Sources/WhisperTranscriber/WhisperTranscriberApp.swift` starts the SwiftUI app; `ContentView` binds to the `@MainActor` `TranscriptionViewModel`.
- Keep UI state on the main actor. `MediaPreparer`, `FFmpegDecoder`, and `WhisperEngine` deliberately move blocking work to dedicated dispatch queues; native inference must not run on Swift's cooperative executor.
- `Sources/WhisperBridge/` is the Swift/C++ boundary. Keep its C ABI opaque and do not pass C++ ownership or borrowed native strings into Swift.
- `Vendor/whisper.cpp` and `Vendor/ffmpeg` are third-party source trees. Avoid incidental edits; use the repository build scripts for their macOS artifacts.
- Model binaries are downloaded at runtime to `~/Library/Application Support/Whisper Transcriber/Models/`, not committed or bundled. `Sources/WhisperTranscriber/Resources/Models.json` pins the expected whisper.cpp version and supported model IDs.

## Source Of Truth

- Treat `Package.swift` and `Scripts/` as the current build definition. `docs/implementation-plan.md` is an approved design document but describes an aspirational Xcode-project layout that does not match the current Swift Package structure.
