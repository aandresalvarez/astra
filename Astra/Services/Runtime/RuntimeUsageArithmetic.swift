/// Provider counters and accumulated recovery usage must never wrap or trap.
/// Saturation exhausts a finite allowance instead of replenishing it.
enum RuntimeUsageArithmetic {
    static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return sum.overflow ? Int.max : sum.partialValue
    }
}
