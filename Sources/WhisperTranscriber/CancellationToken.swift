import Foundation

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ handler: @escaping () -> Void) {
        lock.lock()
        let alreadyCancelled = cancelled
        cancellationHandler = handler
        lock.unlock()
        if alreadyCancelled { handler() }
    }

    func clearHandler() {
        lock.lock()
        cancellationHandler = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancellationHandler
        lock.unlock()
        handler?()
    }
}
