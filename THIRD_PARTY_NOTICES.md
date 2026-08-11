# Third-Party Notices

Whisper Transcriber is licensed under the MIT License. It includes or uses the
following third-party components.

## whisper.cpp

- Project: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- Revision: `306c88f4d1286aec1bf96e544632897886af5501`
- License: MIT
- Copyright: 2023-2026 The ggml authors

The app links the whisper.cpp and ggml libraries. The complete MIT license is
included in the app bundle as `Contents/Resources/Licenses/whisper.cpp-MIT.txt`.

## FFmpeg

- Project: [FFmpeg](https://github.com/FFmpeg/FFmpeg)
- Version: n8.0.1
- Revision: `894da5ca7d742e4429ffb2af534fcda0103ef593`
- License: LGPL-2.1-or-later

The app bundles separate `ffmpeg` and `ffprobe` executables solely for local
Matroska audio decoding. `Scripts/build-ffmpeg.sh` builds them with GPL,
version-3, and nonfree components disabled. The corresponding FFmpeg source is
available at the revision above, and this project's source and build script are
available from the GitHub release tag that distributed the app. The full LGPL
2.1 text is included in the app bundle as
`Contents/Resources/Licenses/FFmpeg-LGPL-2.1.txt`.

The bundled FFmpeg executables include code based in part on the work of the
Independent JPEG Group.

## Whisper models

The app does not bundle model weights. It downloads the user's selected model
on demand from [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp),
which declares an MIT license. Model downloads are stored separately in the
user's Application Support directory.

## Apple frameworks

The app uses Foundation, Accelerate, Metal, AVFoundation, and SwiftUI supplied
by macOS. These frameworks are not redistributed; their use is governed by
Apple's applicable license terms.
