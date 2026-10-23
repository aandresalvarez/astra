import Foundation
import HostControlToolSupport

/// Adapts the synchronous broker transport to an app-owned asynchronous read.
/// A timeout or stopped run cancels the actual operation. Its task retains its
/// producer lease until it settles; cancellation never grants cleanup early.
final class BrokeredMailReadBridge: BrokeredMailReading, @unchecked Sendable {
    enum Failure: Error { case mainThread, stopped, timedOut }
    private let read: @MainActor @Sendable (MailReadRequest) async throws -> Data
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(timeout: TimeInterval = 120,
         read: @escaping @MainActor @Sendable (MailReadRequest) async throws -> Data) {
        self.timeout = timeout
        self.read = read
    }

    func readMail(_ request: MailReadRequest) throws -> Data {
        guard !Thread.isMainThread else { throw Failure.mainThread }
        let answer = Answer()
        let signal = DispatchSemaphore(value: 0)
        let id = UUID()
        lock.lock()
        guard !stopped else { lock.unlock(); throw Failure.stopped }
        let operation = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                let data = try await read(request)
                try Task.checkCancellation()
                answer.set(.success(data))
            } catch { answer.set(.failure(error)) }
            lock.withLock { _ = tasks.removeValue(forKey: id) }
            signal.signal()
        }
        // Completion also takes the lock, so it cannot remove itself before
        // it has been registered, even when a cached read returns immediately.
        tasks[id] = operation
        lock.unlock()
        guard signal.wait(timeout: .now() + timeout) == .success else {
            operation.cancel()
            throw Failure.timedOut
        }
        guard let result = answer.value else { throw Failure.stopped }
        return try result.get()
    }

    func cancelPendingReads() {
        let pending = lock.withLock { Array(tasks.values) }
        for operation in pending { operation.cancel() }
    }

    func closeMailAccess() {
        let pending = lock.withLock {
            stopped = true
            return Array(tasks.values)
        }
        for operation in pending { operation.cancel() }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Data, Error>?
        var value: Result<Data, Error>? { lock.withLock { stored } }
        func set(_ value: Result<Data, Error>) { lock.withLock { stored = value } }
    }
}
