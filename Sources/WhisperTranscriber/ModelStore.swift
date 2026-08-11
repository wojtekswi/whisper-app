import CryptoKit
import Foundation

actor ModelStore {
    private let modelsDirectory: URL

    init(fileManager: FileManager = .default) {
        let support = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        modelsDirectory = support
            .appendingPathComponent("Whisper Transcriber", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func ensureModel(
        _ model: WhisperModel,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (ModelDownloadProgress?) async -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelsDirectory.appendingPathComponent("\(model.id).bin")
        let checksumFile = checksumURL(for: destination)

        if fileManager.fileExists(atPath: destination.path),
           fileManager.fileExists(atPath: checksumFile.path),
           try await checksum(for: destination) == String(contentsOf: checksumFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            return destination
        }

        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: checksumFile)
        await progress(nil)

        let staging = modelsDirectory.appendingPathComponent(".\(model.id).\(UUID().uuidString).partial")
        let stagingChecksum = checksumURL(for: staging)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: stagingChecksum)
        }

        let response = try await download(
            model.remoteURL,
            stagingURL: staging,
            cancellation: cancellation,
            progress: progress
        )
        if cancellation.isCancelled { throw TranscriptionError.cancelled }
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        guard response.url?.scheme == "https" else {
            throw URLError(.secureConnectionFailed)
        }

        await progress(nil)

        if cancellation.isCancelled { throw TranscriptionError.cancelled }
        let digest = try await checksum(for: staging)
        if cancellation.isCancelled { throw TranscriptionError.cancelled }
        try digest.data(using: .utf8)!.write(to: stagingChecksum, options: .atomic)
        try fileManager.moveItem(at: staging, to: destination)
        try fileManager.moveItem(at: stagingChecksum, to: checksumFile)
        return destination
    }

    func remove(_ model: WhisperModel) throws {
        let fileManager = FileManager.default
        let destination = modelsDirectory.appendingPathComponent("\(model.id).bin")
        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: checksumURL(for: destination))
    }

    private func checksumURL(for modelURL: URL) -> URL {
        modelURL.appendingPathExtension("sha256")
    }

    private func checksum(for fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            var hasher = SHA256()
            while true {
                let data = try file.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func download(
        _ url: URL,
        stagingURL: URL,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (ModelDownloadProgress?) async -> Void
    ) async throws -> URLResponse {
        let operation = ModelDownloadOperation(
            stagingURL: stagingURL,
            progress: progress,
            cancellation: cancellation
        )
        return try await operation.download(url)
    }
}

private final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let stagingURL: URL
    private let progressHandler: @Sendable (ModelDownloadProgress?) async -> Void
    private let cancellation: CancellationToken
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var response: URLResponse?
    private var storageError: Error?
    private var session: URLSession?

    init(
        stagingURL: URL,
        progress: @escaping @Sendable (ModelDownloadProgress?) async -> Void,
        cancellation: CancellationToken
    ) {
        self.stagingURL = stagingURL
        progressHandler = progress
        self.cancellation = cancellation
    }

    func download(_ url: URL) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: url)
            lock.unlock()

            cancellation.install { task.cancel() }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { await progressHandler(ModelDownloadProgress(bytesReceived: totalBytesWritten, totalBytes: total)) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
        } catch {
            lock.lock()
            storageError = error
            lock.unlock()
            return
        }
        lock.lock()
        response = downloadTask.response
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let response = self.response
        let storageError = self.storageError
        self.session = nil
        lock.unlock()

        if let error {
            continuation?.resume(throwing: cancellation.isCancelled ? TranscriptionError.cancelled : error)
        } else if let storageError {
            continuation?.resume(throwing: storageError)
        } else if let response {
            continuation?.resume(returning: response)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
