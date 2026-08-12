import Foundation

enum FFmpegDecoder {
    static func inspect(_ source: URL) async throws -> MediaDetails {
        let accessGranted = source.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { source.stopAccessingSecurityScopedResource() }
        }
        return try await Task.detached(priority: .userInitiated) {
            let output = try run(executable: try executableURL(named: "ffprobe"), arguments: [
                "-v", "error",
                "-show_entries", "format=duration:stream=codec_type:stream_tags=language,title",
                "-of", "json",
                source.path
            ])
            let probe = try JSONDecoder().decode(Probe.self, from: output)
            guard let audio = probe.streams.first(where: { $0.codecType == "audio" }),
                  let duration = Double(probe.format.duration ?? ""), duration.isFinite, duration > 0 else {
                throw TranscriptionError.noAudioTrack
            }
            guard duration <= MediaPreparer.maximumDurationSeconds else {
                throw TranscriptionError.tooLong
            }
            let name = audio.tags?.title ?? audio.tags?.language ?? "Default audio track"
            return MediaDetails(
                url: source,
                durationMilliseconds: Int64((duration * 1_000).rounded()),
                audioTrackDescription: name,
                audioTrackID: -1,
                preparationBackend: .ffmpeg
            )
        }.value
    }

    static func prepare(
        _ details: MediaDetails,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedAudio {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "com.whispertranscriber.ffmpeg", qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try prepareSynchronously(details, cancellation: cancellation, progress: progress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func prepareSynchronously(
        _ details: MediaDetails,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> PreparedAudio {
        let accessGranted = details.url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { details.url.stopAccessingSecurityScopedResource() }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whisper Transcriber", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pcmURL = directory.appendingPathComponent("\(UUID().uuidString).f32")
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: pcmURL) }
            cancellation.clearHandler()
        }

        let process = Process()
        process.executableURL = try executableURL(named: "ffmpeg")
        process.arguments = [
            "-nostdin", "-v", "error",
            "-i", details.url.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_f32le",
            "-f", "f32le",
            pcmURL.path
        ]
        let errors = Pipe()
        process.standardError = errors
        cancellation.install { process.terminate() }
        try process.run()
        process.waitUntilExit()

        if cancellation.isCancelled || process.terminationStatus != 0 {
            if cancellation.isCancelled { throw TranscriptionError.cancelled }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TranscriptionError.nativeEngine(message.isEmpty ? "FFmpeg could not decode this MKV file." : message)
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: pcmURL.path)[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw TranscriptionError.invalidAudio
        }
        progress(1)
        succeeded = true
        return PreparedAudio(pcmURL: pcmURL, durationMilliseconds: details.durationMilliseconds)
    }

    static func executableURL(named name: String) throws -> URL {
        let bundleName = "WhisperTranscriber_WhisperTranscriber.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName, isDirectory: true).appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent(name),
            executableDirectory.appendingPathComponent(bundleName, isDirectory: true).appendingPathComponent(name),
            executableDirectory.appendingPathComponent(name)
        ].compactMap { $0 }

        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw TranscriptionError.nativeEngine("Bundled \(name) executable is missing. Rebuild the app with Scripts/build-app.sh.")
    }

    private static func run(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TranscriptionError.nativeEngine(message.isEmpty ? "FFprobe could not inspect this MKV file." : message)
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private struct Probe: Decodable {
        let format: Format
        let streams: [Stream]
    }

    private struct Format: Decodable {
        let duration: String?
    }

    private struct Stream: Decodable {
        let codecType: String
        let tags: Tags?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case tags
        }
    }

    private struct Tags: Decodable {
        let language: String?
        let title: String?
    }
}
