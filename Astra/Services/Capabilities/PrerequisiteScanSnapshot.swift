import ASTRACore

/// A refresh invalidates the previous result immediately. Only the latest
/// completed scan may publish; its predecessor cannot make an old context ready.
struct PrerequisiteScanSnapshot {
    private(set) var statuses: [String: HealthStatus] = [:]
    private var generation = 0

    mutating func begin() -> Int {
        generation += 1
        statuses.removeAll(keepingCapacity: true)
        return generation
    }

    mutating func complete(_ next: [String: HealthStatus], generation completed: Int) {
        guard completed == generation else { return }
        statuses = next
    }
}
