/// Presentation-only page limits shared by storage and in-memory history.
/// The transcript uses an eager stack; older history remains cursor-accessible.
/// These values never restrict persisted history or provider context.
enum TaskThreadHistoryPagePolicy {
    static let runCount = 12
    static let eventCount = 300
}
