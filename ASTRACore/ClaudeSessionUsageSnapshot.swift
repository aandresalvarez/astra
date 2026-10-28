import Foundation
import CoreFoundation

/// Native `modelUsage` is session cumulative, including subagents. Unlike
/// invocation `usage`, this snapshot can prove the next launch's baseline.
public struct ClaudeSessionUsageSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let input: Int
    public let output: Int
    public let costUSD: Double?

    public var isValid: Bool {
        version == 1 && !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && input >= 0 && output >= 0 && (costUSD.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    public init?(line: String) {
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              frame["type"] as? String == "result",
              let session = frame["session_id"] as? String, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let totals = Self.modelTotals(frame["modelUsage"]) else { return nil }
        version = 1; sessionID = session; input = totals.input; output = totals.output
        if let value = frame["total_cost_usd"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let cost = value as? Double, cost.isFinite, cost >= 0 else { return nil }
            costUSD = cost
        } else { costUSD = nil }
    }

    public static func modelTotals(_ value: Any?) -> (input: Int, output: Int)? {
        guard let models = value as? [String: Any], !models.isEmpty else { return nil }
        var input = 0; var output = 0
        for value in models.values {
            guard let entry = value as? [String: Any],
                  let uncached = ProviderUsageArithmetic.reportedCount(entry["inputTokens"]),
                  let generated = ProviderUsageArithmetic.reportedCount(entry["outputTokens"]) else { return nil }
            var counts = [uncached]
            for key in ["cacheReadInputTokens", "cacheCreationInputTokens"] {
                guard let value = entry[key] else { continue }
                guard let count = ProviderUsageArithmetic.reportedCount(value) else { return nil }
                counts.append(count)
            }
            input = ProviderUsageArithmetic.adding(input, ProviderUsageArithmetic.sum(counts))
            output = ProviderUsageArithmetic.adding(output, generated)
        }
        return (input, output)
    }
}
