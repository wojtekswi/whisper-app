@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

struct PreparedAudio: Sendable {
    let pcmURL: URL
    let durationMilliseconds: Int64
}

enum MediaPreparer {
    static let maximumDurationSeconds: Double = 4 * 60 * 60

    static func inspect(_ url: URL) async throws -> MediaDetails {
        if url.pathExtension.lowercased() == "mkv" {
            return try await FFmpegDecoder.inspect(url)
        }
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = try await defaultTrack(from: tracks) else {
                throw TranscriptionError.noAudioTrack
            }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { throw TranscriptionError.unreadableAsset }
            guard seconds <= maximumDurationSeconds else { throw TranscriptionError.tooLong }
            let language = try await track.load(.languageCode) ?? "Unknown language"
            return MediaDetails(
                url: url,
                durationMilliseconds: Int64((seconds * 1_000).rounded()),
                audioTrackDescription: language,
                audioTrackID: track.trackID,
                preparationBackend: .avFoundation
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.unreadableAsset
        }
    }

    static func prepare(
        _ details: MediaDetails,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedAudio {
        if details.preparationBackend == .ffmpeg {
            return try await FFmpegDecoder.prepare(details, cancellation: cancellation, progress: progress)
        }

        do {
            return try await prepareWithAVFoundation(details, cancellation: cancellation, progress: progress)
        } catch is TranscriptionError where cancellation.isCancelled {
            throw TranscriptionError.cancelled
        } catch {
            // AVFoundation rejects some otherwise valid MP4 audio tracks. Retry with
            // the bundled decoder so users are not limited by its codec support.
            return try await FFmpegDecoder.prepare(details, cancellation: cancellation, progress: progress)
        }
    }

    private static func prepareWithAVFoundation(
        _ details: MediaDetails,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedAudio {
        let accessGranted = details.url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { details.url.stopAccessingSecurityScopedResource() }
        }
        let asset = AVURLAsset(url: details.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == details.audioTrackID }) else {
            throw TranscriptionError.noAudioTrack
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "com.whispertranscriber.media-preparer", qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try prepareSynchronously(asset, track: track, details: details, cancellation: cancellation, progress: progress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func prepareSynchronously(
        _ asset: AVURLAsset,
        track: AVAssetTrack,
        details: MediaDetails,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> PreparedAudio {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptionError.invalidAudio }
        reader.add(output)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whisper Transcriber", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pcmURL = directory.appendingPathComponent("\(UUID().uuidString).f32")
        FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: pcmURL)
        defer {
            try? file.close()
            if reader.status != .completed { try? FileManager.default.removeItem(at: pcmURL) }
            cancellation.clearHandler()
        }

        cancellation.install { reader.cancelReading() }
        guard reader.startReading() else { throw TranscriptionError.unreadableAsset }

        var samplesWritten: Int64 = 0
        let expectedSamples = max(1, details.durationMilliseconds * 16)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if cancellation.isCancelled { throw TranscriptionError.cancelled }
            try autoreleasepool {
                let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let targetStart = Int64((CMTimeGetSeconds(presentation) * 16_000).rounded())
                if targetStart > samplesWritten {
                    try writeSilence(to: file, byteCount: (targetStart - samplesWritten) * Int64(MemoryLayout<Float>.size))
                    samplesWritten = targetStart
                }

                guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    throw TranscriptionError.invalidAudio
                }
                var bytesAtOffset = 0
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &bytesAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
                      let dataPointer else {
                    throw TranscriptionError.invalidAudio
                }

                let overlapBytes = max(0, Int((samplesWritten - targetStart) * Int64(MemoryLayout<Float>.size)))
                guard overlapBytes < totalLength else { return }
                let payload = Data(bytes: dataPointer.advanced(by: overlapBytes), count: totalLength - overlapBytes)
                try file.write(contentsOf: payload)
                samplesWritten += Int64(payload.count / MemoryLayout<Float>.size)
                progress(min(0.99, Double(samplesWritten) / Double(expectedSamples)))
            }
        }

        if cancellation.isCancelled || reader.status == .cancelled { throw TranscriptionError.cancelled }
        guard reader.status == .completed else { throw TranscriptionError.invalidAudio }
        guard samplesWritten > 0 else { throw TranscriptionError.invalidAudio }
        progress(1)
        return PreparedAudio(pcmURL: pcmURL, durationMilliseconds: details.durationMilliseconds)
    }

    private static func defaultTrack(from tracks: [AVAssetTrack]) async throws -> AVAssetTrack? {
        for track in tracks where try await track.load(.isEnabled) {
            return track
        }
        return tracks.first
    }

    private static func writeSilence(to file: FileHandle, byteCount: Int64) throws {
        let chunk = Data(repeating: 0, count: 1_048_576)
        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunk.count)))
            try file.write(contentsOf: chunk.prefix(count))
            remaining -= Int64(count)
        }
    }
}
