import Foundation

final class HostControlOperationCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func register(_ handler: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            handler()
            return nil
        }
        let id = UUID()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }

    var isSet: Bool {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}
