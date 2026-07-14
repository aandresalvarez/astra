import Foundation
import ASTRAPersistence

/// Presentation owner for Files shelf indexing. Filesystem snapshots remain
/// derived from `WorkspaceFileIndexService`; this controller owns only their
/// cancellable refresh, warm-cache presentation, and pre-filtered UI shape.
@MainActor
final class ShelfFileIndexController: ObservableObject {
    @Published private(set) var roots: [WorkspaceFileRoot] = []
    @Published private(set) var nodes: [WorkspaceFileNode] = []
    @Published private(set) var displayedNodesByRoot: [String: [WorkspaceFileNode]] = [:]
    @Published private(set) var errors: [WorkspaceFileIndexError] = []
    @Published private(set) var isTruncated = false
    @Published private(set) var isScanning = false
    @Published private(set) var revision = 0

    private let store: WorkspaceFileIndexStore
    private var scanTask: Task<Void, Never>?
    private var normalizedSearchText = ""

    init(store: WorkspaceFileIndexStore = .shared) {
        self.store = store
    }

    func refresh(
        allRoots: [WorkspaceFileRoot],
        scope: ShelfFileNavigatorScope,
        includeHidden: Bool,
        force: Bool,
        reason: String,
        taskID: UUID?,
        workspaceID: UUID?,
        responsivenessScope: UUID?
    ) {
        scanTask?.cancel()
        let selectedRoots = Self.roots(allRoots, for: scope)
        roots = selectedRoots
        isScanning = true
        errors = []
        isTruncated = false
        if let responsivenessScope {
            FilesShelfResponsivenessTelemetry.ensureStarted(
                taskID: taskID,
                workspaceID: workspaceID,
                scope: responsivenessScope
            )
        }

        guard !selectedRoots.isEmpty else {
            apply(.init(roots: [], nodes: [], errors: [], isTruncated: false), displayedNodesByRoot: [:])
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

        let searchText = normalizedSearchText
        scanTask = Task { [weak self] in
            guard let self else { return }
            var presentedCachedSnapshot = false

            if !force,
               let cached = await store.cachedSnapshot(roots: selectedRoots, includeHidden: includeHidden),
               !Task.isCancelled {
                let displayed = await Self.filteredNodes(cached.nodesByRoot, searchText: searchText)
                guard !Task.isCancelled else { return }
                apply(cached, displayedNodesByRoot: displayed)
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
            let displayed = await Self.filteredNodes(fresh.nodesByRoot, searchText: normalizedSearchText)
            guard !Task.isCancelled else { return }

            apply(fresh, displayedNodesByRoot: displayed)
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
        let source = Dictionary(grouping: nodes, by: \.rootID)
        let displayed = await Self.filteredNodes(source, searchText: normalized)
        guard !Task.isCancelled, normalizedSearchText == normalized else { return }
        displayedNodesByRoot = displayed
        revision &+= 1
    }

    func nodes(for root: WorkspaceFileRoot) -> [WorkspaceFileNode] {
        displayedNodesByRoot[root.id] ?? []
    }

    func cancel(responsivenessScope: UUID?) {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        if let responsivenessScope {
            FilesShelfResponsivenessTelemetry.cancel(scope: responsivenessScope, reason: "view_disappeared")
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

    nonisolated private static func filteredNodes(
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

    private func apply(
        _ snapshot: WorkspaceFileIndexSnapshot,
        displayedNodesByRoot: [String: [WorkspaceFileNode]]
    ) {
        roots = snapshot.roots
        nodes = snapshot.nodes
        self.displayedNodesByRoot = displayedNodesByRoot
        errors = snapshot.errors
        isTruncated = snapshot.isTruncated
        revision &+= 1
    }
}
