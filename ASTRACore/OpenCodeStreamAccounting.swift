import Foundation
import CoreFoundation

/// A derived, per-process view of OpenCode's per-step usage. Native fields stay
/// intact. Both monitor and recorder receive the same accumulated projection.
public final class OpenCodeStreamAccounting: @unchecked Sendable {
    static let totalsKey = "_astra_cumulative_usage"
    private struct Step { let message: String; var input: Int; var output: Int; var cost: Double }
    private let lock = NSLock()
    private var steps: [String: Step] = [:]
    private var input = 0
    private var output = 0
    private var cost = 0.0
    private var invalid = false
    public var hasInvalidUsage: Bool { lock.withLock { invalid } }

    public init() {}

    public func normalize(_ line: String) -> (line: String, invalidUsage: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return (line, false)
        }
        frame.removeValue(forKey: Self.totalsKey) // provider input can never supply our derived total
        guard frame["type"] as? String == "step_finish" else { return (encode(frame, fallback: line), false) }
        guard let part = frame["part"] as? [String: Any], part["type"] as? String == "step-finish",
              let session = frame["sessionID"] as? String, !session.isEmpty,
              part["sessionID"] as? String == session,
              let id = part["id"] as? String, !id.isEmpty,
              let message = part["messageID"] as? String, !message.isEmpty,
              let tokens = part["tokens"] as? [String: Any],
              let stepInput = count(tokens["input"]), let stepOutput = count(tokens["output"]),
              let reasoning = optionalCount(tokens["reasoning"]),
              tokens["cache"] == nil || tokens["cache"] is [String: Any],
              let read = optionalCount((tokens["cache"] as? [String: Any])?["read"]),
              let write = optionalCount((tokens["cache"] as? [String: Any])?["write"]),
              let stepCost = optionalCost(part["cost"]) else { return reject(frame, line) }
        let key = session + ":" + id
        let previous = steps[key] ?? Step(message: message, input: 0, output: 0, cost: 0)
        guard previous.message == message, steps[key] != nil || steps.count < 10_000 else {
            return reject(frame, line)
        }
        // Session.getUsage removes caches and reasoning from input/output.
        // Saturation is conservative: overflow cannot replenish a budget.
        let nextInput = max(previous.input, add(add(stepInput, read), write))
        let nextOutput = max(previous.output, add(stepOutput, reasoning))
        let nextCost = max(previous.cost, stepCost)
        let accumulatedInput = add(input, nextInput - previous.input)
        let accumulatedOutput = add(output, nextOutput - previous.output)
        guard !accumulatedInput.addingReportingOverflow(accumulatedOutput).overflow else { return reject(frame, line) }
        input = accumulatedInput
        output = accumulatedOutput
        cost = min(Double.greatestFiniteMagnitude, cost + (nextCost - previous.cost))
        steps[key] = Step(message: message, input: nextInput, output: nextOutput, cost: nextCost)
        frame[Self.totalsKey] = ["input": input, "output": output, "cost": cost]
        return (encode(frame, fallback: line), false)
    }

    private func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, let integer = value as? Int, integer >= 0,
              Double(integer) == number.doubleValue else { return nil }
        return integer
    }
    private func reject(_ frame: [String: Any], _ line: String) -> (line: String, invalidUsage: Bool) {
        invalid = true
        return (encode(frame, fallback: line), true)
    }
    private func optionalCount(_ value: Any?) -> Int? { value == nil ? 0 : count(value) }
    private func optionalCost(_ value: Any?) -> Double? {
        guard let value else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    private func add(_ a: Int, _ b: Int) -> Int {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? Int.max : sum.partialValue
    }
    private func encode(_ frame: [String: Any], fallback: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }
}
