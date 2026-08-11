import Foundation

struct TranscriptSegment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
}

struct WhisperLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let supported = [
        WhisperLanguage(code: "auto", name: "Auto Detect"),
        WhisperLanguage(code: "en", name: "English"),
        WhisperLanguage(code: "pl", name: "Polish"),
        WhisperLanguage(code: "de", name: "German"),
        WhisperLanguage(code: "es", name: "Spanish"),
        WhisperLanguage(code: "fr", name: "French"),
        WhisperLanguage(code: "it", name: "Italian"),
        WhisperLanguage(code: "pt", name: "Portuguese"),
        WhisperLanguage(code: "uk", name: "Ukrainian"),
        WhisperLanguage(code: "ja", name: "Japanese")
    ]
}

struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let remoteURL: URL

    static let catalog = [
        WhisperModel(id: "tiny", name: "Tiny", summary: "Fastest, lowest accuracy", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!),
        WhisperModel(id: "base", name: "Base", summary: "Small multilingual model", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!),
        WhisperModel(id: "small", name: "Small", summary: "Balanced default", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!),
        WhisperModel(id: "medium", name: "Medium", summary: "Better accuracy", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!),
        WhisperModel(id: "large-v3-turbo", name: "Large v3 Turbo", summary: "Best practical speed and quality", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!),
        WhisperModel(id: "large-v3", name: "Large v3", summary: "Highest-cost quality", remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!)
    ]
}

enum AppPhase: Equatable {
    case idle
    case fileSelected
    case inspecting
    case downloadingModel
    case verifyingModel
    case preparingAudio
    case loadingModel
    case transcribing
    case cancelling
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .fileSelected: return "Ready to transcribe"
        case .inspecting: return "Inspecting file..."
        case .downloadingModel: return "Downloading model..."
        case .verifyingModel: return "Verifying model..."
        case .preparingAudio: return "Preparing audio..."
        case .loadingModel: return "Loading model..."
        case .transcribing: return "Transcribing..."
        case .cancelling: return "Cancelling..."
        case .completed: return "Transcript complete"
        case .failed: return "Unable to transcribe"
        }
    }

    var isWorking: Bool {
        switch self {
        case .inspecting, .downloadingModel, .verifyingModel, .preparingAudio, .loadingModel, .transcribing, .cancelling:
            return true
        default:
            return false
        }
    }
}

struct MediaDetails: Sendable {
    let url: URL
    let durationMilliseconds: Int64
    let audioTrackDescription: String
    let audioTrackID: Int32
    let preparationBackend: MediaPreparationBackend
}

enum MediaPreparationBackend: Equatable, Sendable {
    case avFoundation
    case ffmpeg
}

struct ModelDownloadProgress: Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    var description: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        guard let totalBytes else { return "Downloaded \(received)" }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let percentage = Int((fraction ?? 0) * 100)
        return "Downloaded \(received) of \(total) (\(percentage)%)"
    }
}

enum TranscriptionError: LocalizedError {
    case noAudioTrack
    case tooLong
    case unreadableAsset
    case cancelled
    case nativeEngine(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This file does not contain an audio track."
        case .tooLong: return "Version 1 supports files up to four hours long."
        case .unreadableAsset: return "macOS could not read this media file."
        case .cancelled: return "Transcription cancelled."
        case .nativeEngine(let message): return message
        case .invalidAudio: return "The file could not be converted to 16 kHz mono audio."
        }
    }
}
