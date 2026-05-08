import Foundation

public struct ToolError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public struct ProcessResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

private final class LockedDataBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

@discardableResult
public func runProcess(
    _ executable: String,
    arguments: [String] = [],
    input: String? = nil,
    timeout: TimeInterval? = nil,
    timeoutMessage: String? = nil
) throws -> ProcessResult {
    let process = Process()
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()
    let stdoutBuffer = LockedDataBuffer()
    let stderrBuffer = LockedDataBuffer()

    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    if input != nil {
        process.standardInput = stdinPipe
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdoutBuffer.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderrBuffer.append(handle.availableData)
    }

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        semaphore.signal()
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        throw error
    }

    if let input {
        if let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    if let timeout {
        let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
        if semaphore.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ToolError(timeoutMessage ?? "\(executable) timed out after \(Int(timeout)) seconds.")
        }
    } else {
        semaphore.wait()
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil

    return ProcessResult(
        stdout: stdoutBuffer.string(),
        stderr: stderrBuffer.string(),
        exitCode: process.terminationStatus
    )
}

public func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
    Swift.max(minValue, Swift.min(value, maxValue))
}

public func parseInt(_ value: String?, default defaultValue: Int) -> Int {
    guard let value, let parsed = Int(value) else { return defaultValue }
    return parsed
}

public func requireValue(after option: String, in args: inout [String]) throws -> String {
    guard !args.isEmpty else {
        throw ToolError("Missing value for \(option).")
    }
    return args.removeFirst()
}

public func percentEncodePathComponent(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

public func jsonObject(from data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data, options: [])
}

public func jsonObject(from string: String) throws -> Any {
    guard let data = string.data(using: .utf8) else {
        throw ToolError("Could not encode JSON text as UTF-8.")
    }
    return try jsonObject(from: data)
}

public func prettyJSONString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    return String(data: data, encoding: .utf8) ?? "{}"
}

public func printJSON(_ object: Any) throws {
    print(try prettyJSONString(object))
}

public func dictionaryValue(_ object: Any) -> [String: Any] {
    object as? [String: Any] ?? [:]
}

public func stringValue(_ object: Any?, key: String) -> String? {
    guard let dictionary = object as? [String: Any] else { return nil }
    return dictionary[key] as? String
}

public func compactDictionary(_ pairs: [(String, Any?)]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in pairs {
        if let value {
            result[key] = value
        }
    }
    return result
}

public func exitWithError(prefix: String, error: Error, asJSON: Bool = false, code: Int32 = 1) -> Int32 {
    let message: String
    if let toolError = error as? ToolError {
        message = toolError.message
    } else {
        message = String(describing: error)
    }

    if asJSON {
        if let data = try? JSONSerialization.data(
            withJSONObject: ["error": message],
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data(text.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
        }
    } else {
        FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
    }
    return code
}
