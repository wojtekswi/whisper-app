import AppKit
import Foundation

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var details: MediaDetails?
    @Published private(set) var transcript: [TranscriptSegment] = []
    @Published private(set) var progress: Double?
    @Published private(set) var progressDetail: String?
    @Published var selectedModel = WhisperModel.catalog[2]
    @Published var selectedLanguage = WhisperLanguage.supported[0]

    private let modelStore = ModelStore()
    private let engine = WhisperEngine()
    private var activeJob: UUID?
    private var cancellation: CancellationToken?

    var fileName: String? { details?.url.lastPathComponent }
    var hasTranscript: Bool { !transcript.isEmpty }
    var canTranscribe: Bool { details != nil && !phase.isWorking }

    func selectFile(_ url: URL) {
        let job = UUID()
        activeJob = job
        phase = .inspecting
        progress = nil
        progressDetail = nil
        transcript = []
        cancellation?.cancel()

        Task {
            do {
                let fileDetails = try await MediaPreparer.inspect(url)
                guard isActive(job) else { return }
                details = fileDetails
                phase = .fileSelected
            } catch {
                guard isActive(job) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func transcribe() {
        guard let details, !phase.isWorking else { return }
        let job = UUID()
        activeJob = job
        let cancellation = CancellationToken()
        let progressSink = ProgressSink(viewModel: self, job: job)
        self.cancellation = cancellation
        transcript = []

        Task {
            do {
                phase = .downloadingModel
                progress = nil
                progressDetail = "Starting model download..."
                let modelURL = try await modelStore.ensureModel(selectedModel, cancellation: cancellation) { downloadProgress in
                    progressSink.update(downloadProgress?.fraction, detail: downloadProgress?.description)
                }
                guard isActive(job) else { return }

                phase = .verifyingModel
                progress = nil
                progressDetail = "Checking the downloaded model..."
                phase = .preparingAudio
                progressDetail = "Converting audio to Whisper format..."
                let prepared = try await MediaPreparer.prepare(details, cancellation: cancellation) { value in
                    progressSink.update(value, detail: "Converting audio to Whisper format...")
                }
                guard isActive(job) else { return }

                phase = .loadingModel
                progress = nil
                progressDetail = "Loading model into memory..."
                phase = .transcribing
                progressDetail = "Running Whisper locally..."
                let result = try await engine.transcribe(
                    modelURL: modelURL,
                    audio: prepared,
                    language: selectedLanguage,
                    cancellation: cancellation
                ) { value in
                    progressSink.update(value, detail: "Running Whisper locally...")
                }
                guard isActive(job) else { return }
                transcript = result
                progress = 1
                progressDetail = nil
                phase = .completed
            } catch {
                guard isActive(job) else { return }
                progress = nil
                progressDetail = nil
                if case TranscriptionError.cancelled = error {
                    phase = .fileSelected
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        guard phase.isWorking else { return }
        phase = .cancelling
        cancellation?.cancel()
    }

    func reset() {
        cancellation?.cancel()
        activeJob = nil
        cancellation = nil
        details = nil
        transcript = []
        progress = nil
        progressDetail = nil
        phase = .idle
    }

    func saveVTT() {
        guard let details, !transcript.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "vtt")!]
        panel.nameFieldStringValue = details.url.deletingPathExtension().lastPathComponent + ".vtt"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do {
                try WebVTTEncoder.encode(self.transcript).write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                self.phase = .failed("Could not save VTT: \(error.localizedDescription)")
            }
        }
    }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }

    fileprivate func isActive(_ job: UUID) -> Bool {
        activeJob == job
    }

    fileprivate func acceptProgress(_ value: Double?, detail: String?, for job: UUID) {
        guard isActive(job) else { return }
        progress = value
        progressDetail = detail
    }
}

private final class ProgressSink: @unchecked Sendable {
    private weak var viewModel: TranscriptionViewModel?
    private let job: UUID

    init(viewModel: TranscriptionViewModel, job: UUID) {
        self.viewModel = viewModel
        self.job = job
    }

    func update(_ value: Double?, detail: String?) {
        Task { @MainActor [weak viewModel, job] in
            viewModel?.acceptProgress(value, detail: detail, for: job)
        }
    }
}
