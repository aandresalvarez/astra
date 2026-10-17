import Darwin
import Foundation

/// Serializes a pipe's reads *and delivery*. Once the provider is reaped,
/// only bytes already buffered belong to its final drain; an escaped child
/// retaining the write end must never delay completion waiting for EOF.
final class AgentProcessPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readAvailable(consume: (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        drainAvailable(consume: consume)
    }

    /// Called after disabling readability callbacks and reaping the provider.
    /// A callback already queued may still execute, but cannot deliver more
    /// output after this final drain or touch the closed descriptor.
    func finish(consume: (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        drainAvailable(consume: consume)
        try? handle.close()
    }

    private func drainAvailable(consume: (Data) -> Void) {
        let fd = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 65_536)
        // More than the pipe's capacity, but finite even if an escaped writer
        // keeps streaming. During a live run the next callback takes the rest.
        for _ in 0..<16 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            consume(Data(chunk[..<count]))
        }
    }
}
