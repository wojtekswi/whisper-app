import Foundation
import WhisperBridge

final class WhisperEngine {
    private let queue = DispatchQueue(label: "com.whispertranscriber.inference", qos: .userInitiated)

    func transcribe(
        modelURL: URL,
        audio: PreparedAudio,
        language: WhisperLanguage,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let run = NativeRun(modelURL: modelURL, audioURL: audio.pcmURL, language: language.code) else {
            throw TranscriptionError.nativeEngine("The native transcription engine could not start.")
        }
        cancellation.install { run.cancel() }
        defer {
            cancellation.clearHandler()
            try? FileManager.default.removeItem(at: audio.pcmURL)
        }

        let poller = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                progress(run.progress)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }

        let result = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: run.execute())
            }
        }

        if result != 0 {
            let message = run.error
            if cancellation.isCancelled { throw TranscriptionError.cancelled }
            throw TranscriptionError.nativeEngine(message)
        }

        return run.segments
    }
}

private final class NativeRun: @unchecked Sendable {
    private let pointer: OpaquePointer

    init?(modelURL: URL, audioURL: URL, language: String) {
        guard let pointer = wt_run_create(modelURL.path, audioURL.path, language) else { return nil }
        self.pointer = pointer
    }

    deinit {
        wt_run_destroy(pointer)
    }

    var progress: Double {
        Double(wt_run_progress(pointer)) / 100
    }

    var error: String {
        String(cString: wt_run_error(pointer))
    }

    var segments: [TranscriptSegment] {
        let count = wt_run_segment_count(pointer)
        return (0..<count).map { index in
            let segment = wt_run_segment_at(pointer, Int32(index))
            return TranscriptSegment(
                startMilliseconds: segment.start_milliseconds,
                endMilliseconds: segment.end_milliseconds,
                text: String(cString: segment.text)
            )
        }
    }

    func cancel() {
        wt_run_cancel(pointer)
    }

    func execute() -> Int32 {
        wt_run_execute(pointer)
    }
}
