import Foundation
import CoreFoundation

/// Provider counters must never trap or wrap into a replenished allowance.
public enum ProviderUsageArithmetic {
    public static func reportedCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = value as? Int, count >= 0, Double(count) == number.doubleValue else { return nil }
        return count
    }

    public static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return sum.overflow ? Int.max : sum.partialValue
    }

    public static func sum(_ values: [Int]) -> Int { values.reduce(0, adding) }
}
