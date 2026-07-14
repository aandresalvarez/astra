import Foundation

/// Bounded, derived cache for Files shelf snapshots. Callers always start a
/// fresh scan after presenting a cached value, so this cache improves warm
/// responsiveness without becoming a second source of truth for filesystem
/// state.
public actor WorkspaceFileIndexStore {
    public static let shared = WorkspaceFileIndexStore()

    private struct Key: Hashable {
        let roots: [WorkspaceFileRoot]
        let maxDepth: Int
        let maxNodes: Int
        let includeHidden: Bool
    }

    private let capacity: Int
    private var snapshots: [Key: WorkspaceFileIndexSnapshot] = [:]
    private var recency: [Key] = []

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    public func cachedSnapshot(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false
    ) -> WorkspaceFileIndexSnapshot? {
        let key = Key(roots: roots, maxDepth: maxDepth, maxNodes: maxNodes, includeHidden: includeHidden)
        guard let snapshot = snapshots[key] else { return nil }
        touch(key)
        return snapshot
    }

    public func refreshedSnapshot(
        roots: [WorkspaceFileRoot],
        maxDepth: Int = 8,
        maxNodes: Int = 5_000,
        includeHidden: Bool = false,
        fileManager: FileManager = .default,
        privacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> WorkspaceFileIndexSnapshot {
        let snapshot = await WorkspaceFileIndexService.scan(
            roots: roots,
            maxDepth: maxDepth,
            maxNodes: maxNodes,
            includeHidden: includeHidden,
            fileManager: fileManager,
            privacyHomeDirectory: privacyHomeDirectory
        )
        guard !Task.isCancelled else { return snapshot }

        let key = Key(roots: roots, maxDepth: maxDepth, maxNodes: maxNodes, includeHidden: includeHidden)
        snapshots[key] = snapshot
        touch(key)
        evictIfNeeded()
        return snapshot
    }

    public func removeAll() {
        snapshots.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    public func cachedEntryCountForTesting() -> Int {
        snapshots.count
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while snapshots.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            snapshots[oldest] = nil
        }
    }
}
