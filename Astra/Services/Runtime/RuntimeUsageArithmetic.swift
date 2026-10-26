import ASTRACore

/// Shared saturating arithmetic for persisted execution allowances.
enum RuntimeUsageArithmetic {
    static func adding(_ lhs: Int, _ rhs: Int) -> Int { ProviderUsageArithmetic.adding(lhs, rhs) }
}
