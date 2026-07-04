import Foundation
import ASTRACore

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

public enum AppleScriptSource {
    public static func stringLiteral(_ value: String) -> String {
        let safe = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(safe)\""
    }

    public static func errorStatement(_ message: String) -> String {
        "error \(stringLiteral(message))"
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
    let requestTimeout = timeout ?? 120
    let result = HardenedProcessExecutor().runSynchronously(HardenedProcessRequest(
        executable: executable,
        arguments: arguments,
        standardInput: input.map { Data($0.utf8) },
        timeout: requestTimeout,
        // Mail helpers can fan out to child processes (osascript, network
        // helpers); terminate the whole group on timeout so descendants can't
        // outlive the parent. Matches the connector-read reader's behavior.
        terminateProcessGroup: true
    ))
    if result.timedOut {
        throw ToolError(timeoutMessage ?? "\(executable) timed out after \(Int(requestTimeout)) seconds.")
    }
    if let launchError = result.launchError {
        throw ToolError(launchError)
    }
    return ProcessResult(
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode ?? -1
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
