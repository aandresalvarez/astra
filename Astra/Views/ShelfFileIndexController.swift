import Foundation
import ASTRAPersistence

protocol ShelfFileIndexFiltering: Sendable {
    func filter(
        _ nodesByRoot: [String: [WorkspaceFileNode]],
        searchText: String
    ) async -> [String: [WorkspaceFileNode]]
}

struct DefaultShelfFileIndexFilter: ShelfFileIndexFiltering {
    func filter(
        _ nodesByRoot: [String: [WorkspaceFileNode]],
        searchText: String
    ) async -> [String: [WorkspaceFileNode]] {
        guard !searchText.isEmpty else { return nodesByRoot }
        return await Task.detached(priority: .userInitiated) {
            nodesByRoot.mapValues { nodes in
                nodes.filter { $0.normalizedSearchText.contains(searchText) }
            }
        }.value
    }
}

enum ShelfFileIndexSnapshotSource: Equatable {
    case none
    /// A previously presented snapshot remains visible while its replacement
    /// is loading, but must not drive automatic file selection.
    case stale
    case cache
    case fresh
}

/// Presentation owner for Files shelf indexing. Filesystem snapshots remain
/// derived from `WorkspaceFileIndexService`; this controller owns only their
/// cancellable refresh, warm-cache presentation, and pre-filtered UI shape.
@MainActor
final class ShelfFileIndexController: ObservableObject {
    @Published private(set) var allRoots: [WorkspaceFileRoot] = []
    @Published private(set) var roots: [WorkspaceFileRoot] = []
    @Published private(set) var nodes: [WorkspaceFileNode] = []
    @Published private(set) var displayedNodesByRoot: [String: [WorkspaceFileNode]] = [:]
    @Published private(set) var errors: [WorkspaceFileIndexError] = []
    @Published private(set) var isTruncated = false
    @Published private(set) var isScanning = false
    @Published private(set) var revision = 0
    @Published private(set) var snapshotSource = ShelfFileIndexSnapshotSource.none

    private let store: WorkspaceFileIndexStore
    private let filtering: any ShelfFileIndexFiltering
    private var scanTask: Task<Void, Never>?
    private var normalizedSearchText = ""
    private var searchRevision = 0
    private var indexRevision = 0

    init(
        store: WorkspaceFileIndexStore = .shared,
        filtering: any ShelfFileIndexFiltering = DefaultShelfFileIndexFilter()
    ) {
        self.store = store
        self.filtering = filtering
    }

    func refresh(
        allRoots: [WorkspaceFileRoot],
        scope: ShelfFileNavigatorScope,
        includeHidden: Bool,
        force: Bool,
        reason: String,
        taskID: UUID?,
        responsivenessScope: UUID?
    ) {
        scanTask?.cancel()
        self.allRoots = allRoots
        let selectedRoots = Self.roots(allRoots, for: scope)
        roots = selectedRoots
        markCurrentSnapshotStale()
        isScanning = true
        errors = []
        isTruncated = false

        guard !selectedRoots.isEmpty else {
            apply(
                .init(roots: [], nodes: [], errors: [], isTruncated: false),
                displayedNodesByRoot: [:],
                source: .fresh
            )
            isScanning = false
            if let responsivenessScope {
                FilesShelfResponsivenessTelemetry.firstResultsReady(
                    scope: responsivenessScope,
                    fileScope: scope.rawValue,
                    cacheState: "not_applicable",
                    rootCount: 0,
                    nodeCount: 0
                )
                FilesShelfResponsivenessTelemetry.indexReady(
                    scope: responsivenessScope,
                    fileScope: scope.rawValue,
                    cacheState: "not_applicable",
                    rootCount: 0,
                    nodeCount: 0,
                    errorCount: 0,
                    isTruncated: false
                )
            }
            return
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            var presentedCachedSnapshot = false

            if !force,
               let cached = await store.cachedSnapshot(roots: selectedRoots, includeHidden: includeHidden),
               !Task.isCancelled {
                guard let displayed = await displayedNodesForCurrentSearch(cached.nodesByRoot) else { return }
                apply(cached, displayedNodesByRoot: displayed, source: .cache)
                presentedCachedSnapshot = true
                if let responsivenessScope {
                    FilesShelfResponsivenessTelemetry.firstResultsReady(
                        scope: responsivenessScope,
                        fileScope: scope.rawValue,
                        cacheState: "hit",
                        rootCount: cached.roots.count,
                        nodeCount: cached.nodes.count
                    )
                }
            }

            let scanStart = DispatchTime.now().uptimeNanoseconds
            let fresh = await store.refreshedSnapshot(roots: selectedRoots, includeHidden: includeHidden)
            guard !Task.isCancelled else { return }
            guard let displayed = await displayedNodesForCurrentSearch(fresh.nodesByRoot) else { return }

            apply(fresh, displayedNodesByRoot: displayed, source: .fresh)
            isScanning = false
            let cacheState = presentedCachedSnapshot ? "refresh" : "miss"
            FilesShelfResponsivenessTelemetry.logIndexScan(
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: scanStart),
                fileScope: scope.rawValue,
                rootCount: fresh.roots.count,
                nodeCount: fresh.nodes.count,
                errorCount: fresh.errors.count,
                isTruncated: fresh.isTruncated,
                reason: reason,
                taskID: taskID
            )
            if let responsivenessScope {
                FilesShelfResponsivenessTelemetry.firstResultsReady(
                    scope: responsivenessScope,
                    fileScope: scope.rawValue,
                    cacheState: cacheState,
                    rootCount: fresh.roots.count,
                    nodeCount: fresh.nodes.count
                )
                FilesShelfResponsivenessTelemetry.indexReady(
                    scope: responsivenessScope,
                    fileScope: scope.rawValue,
                    cacheState: cacheState,
                    rootCount: fresh.roots.count,
                    nodeCount: fresh.nodes.count,
                    errorCount: fresh.errors.count,
                    isTruncated: fresh.isTruncated
                )
            }

            if !fresh.errors.isEmpty {
                PerformanceTelemetry.log(
                    "files_shelf_index_error",
                    level: .warning,
                    fields: [
                        "error_count": PerformanceTelemetryFields.count(fresh.errors.count),
                        "root_count": PerformanceTelemetryFields.count(fresh.roots.count),
                        "scope": scope.rawValue
                    ],
                    taskID: taskID
                )
            }
        }
    }

    func applySearchText(_ text: String) async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalizedSearchText = normalized
        searchRevision &+= 1
        let requestedRevision = searchRevision
        let requestedIndexRevision = indexRevision
        let source = Dictionary(grouping: nodes, by: \.rootID)
        let displayed = await filtering.filter(source, searchText: normalized)
        guard !Task.isCancelled,
              searchRevision == requestedRevision,
              indexRevision == requestedIndexRevision,
              normalizedSearchText == normalized else { return }
        displayedNodesByRoot = displayed
        revision &+= 1
    }

    func nodes(for root: WorkspaceFileRoot) -> [WorkspaceFileNode] {
        displayedNodesByRoot[root.id] ?? []
    }

    func cancel(responsivenessScope: UUID?, reason: String = "view_disappeared") {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        if let responsivenessScope {
            FilesShelfResponsivenessTelemetry.cancel(scope: responsivenessScope, reason: reason)
        }
    }

    static func roots(
        _ roots: [WorkspaceFileRoot],
        for scope: ShelfFileNavigatorScope
    ) -> [WorkspaceFileRoot] {
        roots.filter { root in
            switch scope {
            case .task:
                root.kind == .taskFolder || root.kind == .input
            case .workspace:
                root.kind == .primary || root.kind == .additional
            case .all:
                true
            }
        }
    }

    private func displayedNodesForCurrentSearch(
        _ nodesByRoot: [String: [WorkspaceFileNode]]
    ) async -> [String: [WorkspaceFileNode]]? {
        while !Task.isCancelled {
            let requestedRevision = searchRevision
            let requestedSearchText = normalizedSearchText
            let displayed = await filtering.filter(nodesByRoot, searchText: requestedSearchText)
            guard !Task.isCancelled else { return nil }
            if requestedRevision == searchRevision,
               requestedSearchText == normalizedSearchText {
                return displayed
            }
        }
        return nil
    }

    private func markCurrentSnapshotStale() {
        guard snapshotSource != .none else { return }
        snapshotSource = .stale
        // Any filter already running belongs to the previous snapshot. Keep
        // the rows visible while refreshing, but prevent that work from being
        // published as if it belonged to the replacement index.
        indexRevision &+= 1
    }

    private func apply(
        _ snapshot: WorkspaceFileIndexSnapshot,
        displayedNodesByRoot: [String: [WorkspaceFileNode]],
        source: ShelfFileIndexSnapshotSource
    ) {
        roots = snapshot.roots
        nodes = snapshot.nodes
        self.displayedNodesByRoot = displayedNodesByRoot
        errors = snapshot.errors
        isTruncated = snapshot.isTruncated
        snapshotSource = source
        indexRevision &+= 1
        revision &+= 1
    }
}
