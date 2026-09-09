import Darwin
import Foundation

/// A short-lived, read-only app-server conversation. No thread or turn is
/// created. Initialization and each page are acknowledged before the next
/// request; stdout is bounded and the entire conversation has one deadline.
struct CodexAppServerModelProbe: CodexModelCatalogProbing {
    var timeout: TimeInterval = 15

    func models(executablePath: String, environment: [String: String]) async throws -> [CodexModelInfo] {
        let cancellation = CodexModelProbeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try conversation(executablePath: executablePath, environment: environment, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func conversation(
        executablePath: String, environment: [String: String], cancellation: CodexModelProbeCancellation
    ) throws -> [CodexModelInfo] {
        try cancellation.check()
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexModelProbeError.unavailableExecutable
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Do not retain provider diagnostics that may contain account details.
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        defer {
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile()
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let writer = input.fileHandleForWriting.fileDescriptor
        guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0,
              fcntl(writer, F_SETFL, O_NONBLOCK) == 0 else { throw CodexModelProbeError.exited }
        let reader = output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data()
        var receivedBytes = 0

        func send(_ message: [String: Any]) throws {
            try cancellation.check()
            var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(10)
            // Even a broken server that stops reading cannot block discovery
            // indefinitely (for example when returning a very large cursor).
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try cancellation.check()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexModelProbeError.timedOut }
                    let count = write(writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0 && errno == EINTR { continue }
                    guard count < 0 && errno == EAGAIN else { throw CodexModelProbeError.exited }
                    var descriptor = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                }
            }
        }

        func response(id: Int) throws -> [String: Any] {
            while true {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexModelProbeError.timedOut }
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw CodexModelProbeError.invalidResponse
                    }
                    guard object["id"] as? Int == id else { continue }
                    if object["error"] != nil { throw CodexModelProbeError.rpcError }
                    guard let result = object["result"] as? [String: Any] else { throw CodexModelProbeError.invalidResponse }
                    return result
                }
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw CodexModelProbeError.exited
                }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(reader, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexModelProbeError.exited }
                receivedBytes += count
                guard receivedBytes <= 4 * 1024 * 1024 else { throw CodexModelProbeError.outputLimit }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "astra_model_discovery", "version": "1.0"]
        ]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        var models: [CodexModelInfo] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for id in 2...101 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            try send(["id": id, "method": "model/list", "params": params])
            let result = try response(id: id)
            let page = try JSONDecoder().decode(CodexModelPage.self, from: JSONSerialization.data(withJSONObject: result))
            models += page.data
            guard let next = page.nextCursor else { return models }
            guard !next.isEmpty, seenCursors.insert(next).inserted else { throw CodexModelProbeError.repeatedCursor }
            cursor = next
        }
        throw CodexModelProbeError.outputLimit
    }
}

private struct CodexModelPage: Decodable {
    var data: [CodexModelInfo]
    var nextCursor: String?
}

private final class CodexModelProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
