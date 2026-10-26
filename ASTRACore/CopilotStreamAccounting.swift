import Foundation
import CoreFoundation

/// assistant.usage is per API call, unlike session.shutdown. Project identified
/// calls into session totals before either the monitor or recorder sees them.
public final class CopilotStreamAccounting: @unchecked Sendable {
    static let totalsKey = "_astra_copilot_session_usage"
    private let lock = NSLock()
    private var calls: [String: (input: Int, output: Int)] = [:]
    private var input: Int
    private var output: Int
    private var invalid = false
    public var hasInvalidUsage: Bool { lock.withLock { invalid } }
    public init(sessionInput: Int = 0, sessionOutput: Int = 0) {
        input = max(0, sessionInput); output = max(0, sessionOutput)
    }

    public func normalize(_ line: String) -> (line: String, invalidUsage: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return (line, false) }
        frame.removeValue(forKey: Self.totalsKey)
        guard frame["type"] as? String == "assistant.usage" else { return (encode(frame, fallback: line), false) }
        let data = frame["data"] as? [String: Any] ?? frame
        guard let id = frame["id"] as? String, !id.isEmpty else { return (encode(frame, fallback: line), false) }
        let reportedInput = data["inputTokens"] ?? data["input_tokens"]
        let reportedOutput = data["outputTokens"] ?? data["output_tokens"]
        guard reportedInput != nil || reportedOutput != nil else { return (encode(frame, fallback: line), false) }
        guard let nextInput = count(reportedInput),
              let nextOutput = count(reportedOutput),
              calls[id] != nil || calls.count < 10_000 else { invalid = true; return (encode(frame, fallback: line), true) }
        let previous = calls[id] ?? (0, 0)
        let next = (input: max(previous.input, nextInput), output: max(previous.output, nextOutput))
        input = ProviderUsageArithmetic.adding(input, next.input - previous.input)
        output = ProviderUsageArithmetic.adding(output, next.output - previous.output)
        calls[id] = next
        frame[Self.totalsKey] = ["input": input, "output": output]
        return (encode(frame, fallback: line), false)
    }
    private func count(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = value as? Int, count >= 0, Double(count) == number.doubleValue else { return nil }
        return count
    }
    private func encode(_ frame: [String: Any], fallback: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }
}
