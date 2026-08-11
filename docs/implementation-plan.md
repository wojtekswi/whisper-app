# Whisper Transcriber Implementation Plan

Status: Approved

Date: 2026-08-11

## Goal

Build a one-window native macOS app that accepts one audio or video file by
drag-and-drop or file picker, transcribes it fully on-device, shows meaningful
progress, previews timestamped segments, and exports synchronized WebVTT.

The language picker specifies the spoken source language or Auto Detect. The
first version does not translate text into another language.

## Product Scope

- Personal-use app for Apple Silicon.
- Native SwiftUI interface.
- Fully local inference through `whisper.cpp` and converted OpenAI Whisper
  models.
- One audio or video file at a time.
- Source-language selection with Auto Detect.
- User-selectable Whisper models, downloaded and cached on demand.
- Visible model download, audio preparation, model loading, and transcription
  progress.
- Cooperative cancellation.
- Timestamped transcript preview and WebVTT export.
- Maximum supported input duration of four hours.
- Default audio track when media contains multiple tracks.
- Subtitle timing aligned with the original media timeline.

## Technical Baseline

- macOS 15 or newer.
- Swift 6.
- Xcode 26.
- Apple Silicon arm64 target for the first version.
- `whisper.cpp` v1.9.2 pinned to an exact release commit.
- Metal acceleration enabled in Release builds.
- No Python runtime or cloud API. FFmpeg is bundled only for Matroska decoding.

## Architecture

```text
SwiftUI View
    |
@MainActor TranscriptionViewModel
    |  owns one JobID and state machine
    v
TranscriptionCoordinator
    |-- ModelStore actor
    |-- MediaPreparer dedicated queue
    |-- WhisperEngine and native worker queue
    `-- WebVTTEncoder
                         |
                         v
             C ABI WhisperBridge.cpp
                         |
                         v
          pinned whisper.cpp XCFramework
```

SwiftUI and app state remain on the main actor. Audio preparation and
`whisper_full` never run on Swift's cooperative executor. Each job has a
thread-safe cancellation handle that can cancel `AVAssetReader` or set the
native abort flag without waiting for an occupied actor.

## Main Flow

1. Accept a dropped or selected URL and hold its security-scoped access for the
   inspection and preparation lifetime.
2. Inspect the asset asynchronously, choose its default audio track, read its
   duration and metadata, and reject protected, audio-less, corrupt,
   unsupported, empty, or over-four-hour inputs.
3. Preflight free disk space for the selected model, model-download staging,
   temporary PCM, and a safety margin.
4. Ensure the selected model exists. Download it over HTTPS when needed, show
   byte progress, stream SHA-256 verification, and atomically promote the
   verified file into Application Support.
5. Use `AVAssetReaderAudioMixOutput` with only the default track to produce
   16 kHz, mono, Float32 PCM. Stream samples to a private temporary file rather
   than retaining the complete recording in Swift memory.
6. Preserve the original media timeline by using each sample buffer's
   presentation timestamp, inserting silence for positive gaps, and trimming
   overlaps. Four hours of prepared PCM requires approximately 880 MiB.
7. Close the PCM writer, memory-map it read-only in the native bridge, and run
   Whisper on a dedicated serial worker.
8. Poll native atomic progress at 5 to 10 Hz. Use Whisper's abort callback for
   cooperative cancellation.
9. Copy segment text and timestamps into Swift-owned values before releasing
   native result memory.
10. Preview the segments and generate UTF-8 WebVTT. Save atomically using a
    native save panel with `<source-name>.vtt` as the default filename.
11. Release the model lease, mapping, temporary PCM, source-file access, and all
    run handles on success, failure, or completed cancellation.

## Interface

The app uses one window whose content changes with the current phase.

### Empty And Ready State

```text
+--------------------------------------------------------------+
| Whisper Transcriber                         [Model v] [Lang v]|
+--------------------------------------------------------------+
|                                                              |
|              Drop an audio or video file here                |
|                      or [Choose File...]                      |
|             MP3, M4A, WAV, MP4, MOV and more                 |
|                                                              |
+--------------------------------------------------------------+
| Selected: interview.mp4 - 01:24:18                            |
|                                           [Transcribe]        |
+--------------------------------------------------------------+
```

### Active State

The drop area becomes a status panel:

```text
Preparing audio... / Downloading model... / Transcribing...
[======================-------] 68%  57:31 / 84:18  [Cancel]
```

### Completed State

Show timestamped segments in a native scroll view with these actions:

- `Copy Text`
- `Save VTT...`
- `New File`

Errors remain inline with a retry action instead of using modal alerts. Model
and language controls remain visible before a run and lock while work is active.
If completed output has not been saved, replacing it requires confirmation.

## App State

Use one explicit state machine:

```swift
idle
fileSelected
inspecting
downloadingModel
verifyingModel
preparingAudio
loadingModel
transcribing
cancelling
completed
failed
```

Every operation carries a monotonically increasing `JobID`. Progress or
completion from an old job is ignored, preventing a canceled run from
overwriting a newer one. Progress is monotonic, clamped, throttled, and
phase-specific. The UI reports indeterminate progress when total work is
unknown.

## Native Boundary

Expose a small `extern "C"` interface from `WhisperBridge.cpp`:

- Opaque model, run, and result handles.
- Explicit create, execute, cancel, progress, result-access, and destroy
  functions.
- Fixed-width values and stable error codes only.
- No C++ exceptions, STL types, or borrowed Whisper strings crossing into
  Swift.
- A native atomic cancel flag connected to
  `whisper_full_params.abort_callback`.
- A native atomic progress value connected to Whisper's progress callback.
- Read-only PCM mapping retained until inference fully stops.
- One active run per Whisper context.
- Result text copied before the context is reused or destroyed.

The bridge checks PCM size, four-byte alignment, empty input, and conversion to
Whisper's signed sample-count type before calling the library. Cancellation
changes the UI to `Cancelling...`; model contexts and PCM are not released until
the native call returns.

The native bridge owns all Whisper pointers and catches all C++ exceptions. It
must always release contexts, mappings, file descriptors, callback data, and
result allocations through explicit RAII-backed cleanup.

## Whisper Configuration

Offer multilingual model choices only:

| Model | Positioning |
| --- | --- |
| Tiny | Fastest, lowest accuracy |
| Base | Small download |
| Small | Default balanced choice |
| Medium | Better accuracy, larger memory use |
| Large v3 Turbo | Best practical speed and quality |
| Large v3 | Highest-cost quality option |

Set `translate = false`, enable segment timestamps, disable console and
special-token output, and pass either the selected Whisper language code or
Auto. Exclude `.en` models because this app supports multilingual source
selection.

Metal is enabled in Release builds. Core ML encoder artifacts are deferred
because they multiply model packaging and download complexity. Add a smoke test
that confirms the expected accelerated backend loads.

## Model Storage

Store models under:

```text
~/Library/Application Support/Whisper Transcriber/Models/
```

The bundled manifest records:

- Stable model ID and display name.
- Exact HTTPS URL.
- Expected byte count.
- SHA-256 digest.
- Model and quantization format.
- Multilingual capability.
- Compatible pinned Whisper revision.

Downloads use unique staging names on the same filesystem as the final file.
Require a 2xx response, reject HTTPS-to-HTTP redirects, enforce the maximum
expected size, hash incrementally, and move atomically only after size and
checksum match. Coalesce duplicate requests for the same model.

Verify installed models before first use in each app session. Keep a lease while
a model is loaded so it cannot be deleted. The model menu shows installed and
download sizes and provides `Remove Download` for inactive models. Exclude model
storage from backups.

Persist resumable download data when `URLSession` supplies it. Clean stale
partial files on startup and after unrecoverable failure or cancellation.

## Media Rules

- Support formats AVFoundation can decode, explicitly tested with WAV, MP3,
  M4A/AAC, MOV, and MP4.
- Support MKV through bundled arm64 FFmpeg and FFprobe executables. The
  constrained LGPL build decodes common Matroska audio codecs and writes 16 kHz
  mono Float32 PCM for Whisper.
- Validate media by loading the asset and audio track, not by filename extension
  alone.
- For multiple audio tracks, select the asset's default enabled audio track and
  show its title or language in the file details.
- Preserve original media timing for VTT synchronization.
- Reject inputs longer than four hours before creating temporary PCM.
- Reject DRM-protected, audio-less, empty, unreadable, and unsupported assets
  with specific user-facing errors.
- Inspect the actual audio format emitted by AVFoundation and fail safely if it
  is not canonical 16 kHz mono Float32 PCM.
- Check `AVAssetReader.status` and `error` after the sample loop.
- Use an autorelease pool around long sample-buffer loops.
- Check short writes and disk exhaustion while preparing PCM.

## WebVTT Rules

Output one cue per Whisper segment:

```vtt
WEBVTT

00:00:00.000 --> 00:00:03.420
Cue text
```

Use integer timestamp arithmetic, UTF-8, and LF line endings. Preserve Unicode
and intentional line breaks. Escape `&`, `<`, and `>`, strip NUL and disallowed
control characters, maintain cue ordering, and apply original media timeline
offsets. Drop or repair zero-length cues deterministically. Hours may exceed two
digits.

## Sandbox And File Access

Enable App Sandbox with these capabilities:

- User-selected file read/write access.
- Outgoing network access for model downloads.

Hold security-scoped input access until audio preparation finishes, then release
it because inference uses only the app-owned PCM file. Do not persist
security-scoped bookmarks in the first version.

Use private, uniquely named temporary files inside the app container. Cleanup
occurs after native inference has completely stopped, including on cancellation
and failure. Remove abandoned job files on the next launch.

## Project Layout

```text
WhisperTranscriber.xcodeproj
WhisperTranscriber/
  App/
    WhisperTranscriberApp.swift
    AppCommands.swift
  Transcription/
    TranscriptionView.swift
    TranscriptionViewModel.swift
    TranscriptionState.swift
  Domain/
    Transcript.swift
    WhisperModel.swift
    WhisperLanguage.swift
  Services/
    TranscriptionCoordinator.swift
    ModelStore.swift
    MediaPreparer.swift
    WhisperEngine.swift
    WebVTTEncoder.swift
    FFmpegDecoder.swift
    ScopedFileAccess.swift
  Native/
    WhisperBridge.h
    WhisperBridge.cpp
  Resources/
    Models.json
    Acknowledgements.txt
Vendor/
  whisper.cpp/
  ffmpeg/
Scripts/
  build-whisper-xcframework.sh
  build-ffmpeg.sh
WhisperTranscriberTests/
WhisperTranscriberIntegrationTests/
TestFixtures/
```

## Implementation Sequence

1. Scaffold the SwiftUI project, arm64 Release settings, sandbox entitlements,
   test targets, and pinned `whisper.cpp` source.
2. Build the official XCFramework reproducibly and complete a command-level
   spike that transcribes a short WAV with Metal.
3. Implement the native C ABI bridge and tests for invalid input, result
   ownership, repeated runs, model switching, progress, and cancellation.
4. Build a vertical slice using a preinstalled Tiny model: choose WAV,
   transcribe, preview segments, and export VTT.
5. Implement asset inspection and the timeline-preserving AVFoundation media
   preparation pipeline.
6. Add drag-and-drop, file picker, default-track metadata, four-hour validation,
   disk preflight, and temporary-file cleanup.
7. Implement the model manifest, verified and resumable downloads, cache
   validation, model leases, selection, and removal.
8. Add the complete job state machine, stale-`JobID` protection, phase progress,
   cancellation, and typed inline errors.
9. Finish the approved empty, active, completed, canceling, and error UI states.
10. Run unit, integration, sanitizer, format, long-file, cancellation, and
    target-machine performance tests.
11. Archive and run the personal build locally. Defer Developer ID signing,
    notarization, universal binaries, automatic updates, and CI until the app
    needs to be shared.

## Verification

### Unit Tests

- State-machine transitions and stale `JobID` rejection.
- Language-code mapping.
- Checked sample and file arithmetic.
- Model manifest and disk-space calculations.
- Typed error-to-UI mapping.
- WebVTT timestamp formatting, escaping, ordering, and boundary cases.

### Media Tests

- 8, 16, 44.1, 48, and 96 kHz sources.
- Mono, stereo, and multichannel sources.
- Integer and Float PCM.
- AAC, ALAC, MP3, and PCM containers.
- Audio tracks inside MOV and MP4.
- Leading offsets, edit-list gaps, overlap, and leading silence.
- Multiple audio tracks and deterministic default selection.
- Audio-less, corrupt, protected, zero-length, and truncated media.
- Cancellation at the beginning, middle, and end of preparation.
- Exact output format, sample count, timeline, and channel mix.

### Model Tests

Use an injected URL protocol to cover:

- Valid downloads and hashes.
- Incorrect hashes and truncated or oversized bodies.
- HTTP failures and insecure redirects.
- Cancellation and resumable downloads.
- Concurrent requests for one model.
- Existing valid and corrupt cache entries.
- Stale partial cleanup.
- Atomic replacement and disk-full errors.

### Native Tests

- Invalid model and PCM paths.
- Empty, misaligned, and malformed PCM.
- Cancellation before and during inference.
- Progress polling and stale-run races.
- Repeated model switching.
- Result copying followed by immediate context destruction.
- One short licensed speech fixture with a pinned small model.
- Metal backend smoke test.

Run Address Sanitizer for the native bridge and Thread Sanitizer for Swift
orchestration. Large-model and long-duration tests are opt-in and use
pre-provisioned models rather than downloading them on every test run.

### Acceptance And Performance Tests

- Short files in several languages.
- Auto Detect versus explicit source language.
- A 60-minute recording.
- A generated four-hour boundary fixture.
- Repeated cancel and restart loops.
- Peak resident memory and temporary disk usage.
- Real-time factor for each supported model on the target M5 Pro.
- Model-load time and cancellation latency.
- No leaked contexts, mappings, descriptors, temporary files, or source-file
  access handles.

## Done Criteria

- Dragging or choosing a supported file never blocks the interface.
- The selected source language and model are used.
- Model download, verification, audio preparation, loading, and transcription
  are visibly distinguished.
- Cancellation is immediate in the UI and safely stops at Whisper's next abort
  point.
- A four-hour supported file completes without sample-count overflow or
  uncontrolled Swift memory growth.
- Preview timestamps match the original media timeline.
- Exported VTT passes golden-format tests and synchronizes with the source
  video.
- Once a model is installed, transcription makes no network requests.
- Closing, canceling, retrying, and switching models leak no contexts, mappings,
  descriptors, or temporary files.

## Distribution Plan

The first version is built and archived locally through Xcode for use on the
development Mac. Model files remain separate downloads so the application
bundle stays small.

CI is explicitly deferred for the personal version. The local release gate is a
successful Release build plus the unit, integration, sanitizer, acceptance, and
target-machine performance checks described above.

If the app is shared later, add Developer ID signing, notarization, hardened
runtime verification, a universal binary or explicit Apple Silicon requirement,
automatic updates, and CI on a pinned macOS/Xcode runner.

## Deferred Scope

- Batch processing and queues.
- Folder watching.
- Subtitle editing.
- Speaker diarization.
- Live microphone transcription.
- Translation into another language.
- Core ML model variants.
- Intel Mac support.
- App Store distribution.
- Developer ID signing and notarization.
- Automatic updates.
- CI/CD.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| Native cancellation or ownership bug | Dedicated worker, opaque C ABI, atomic abort, RAII cleanup, sanitizer tests |
| Incorrect VTT timing | Preserve presentation timestamps and test gaps, offsets, overlap, and long-duration boundaries |
| Large file memory or disk pressure | Four-hour limit, streamed PCM preparation, memory mapping, checked arithmetic, disk preflight |
| Corrupt or incompatible model | Pinned manifest, exact revision, byte limit, streamed SHA-256, atomic promotion |
| Metal packaging failure | Reproducible XCFramework build and Release-backend smoke test |
| Stale asynchronous UI updates | Unique `JobID`, main-actor state, one active operation, throttled latest-value progress |

## Review Result

The initial engineering review scored 5/10 because cancellation, long-file
limits, audio-track policy, and timeline semantics were undefined. This plan
resolves those blockers with a dedicated native worker, cooperative abort
handle, four-hour cap, deterministic default-track selection, and
timeline-preserving PCM preparation.

Revised review result: 9/10, PASS.

Residual risk is concentrated in AVFoundation gap handling and native
cancellation latency. Both have explicit integration and stress tests before UI
polish.

## References

- [OpenAI Whisper](https://github.com/openai/whisper)
- [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp)
- [`whisper.cpp` SwiftUI example](https://github.com/ggml-org/whisper.cpp/tree/master/examples/whisper.swiftui)
- [AVAssetReaderAudioMixOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput)
