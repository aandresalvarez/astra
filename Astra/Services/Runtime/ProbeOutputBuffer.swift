import Foundation

/// Collects a probe's stdout on a reader queue so the parent never blocks on a full pipe.
final class ProbeOutputBuffer {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data: Data?

    func finish(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
        ready.signal()
    }

    func wait(timeout: DispatchTime) -> Data? {
        guard ready.wait(timeout: timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
