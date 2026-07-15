import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ASTRAModels

/// User-selectable ordering inside each workspace group. Starred workspaces
/// remain a distinct first group in every mode; changing sort never mutates
/// durable workspace state.
enum WorkspaceSidebarSortMode: String, CaseIterable, Identifiable {
    case name
    case recent
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .recent: "Recently used"
        case .manual: "Manual"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .recent: "clock"
        case .manual: "line.3.horizontal"
        }
    }
}

/// Local presentation state. This deliberately does not live on `Workspace`:
/// recency and manual sidebar position are per-install UI preferences, unlike
/// stars, which are durable and exported with the workspace.
struct WorkspaceSidebarOrderingState: Equatable {
    var manualOrderIDs: [UUID] = []
    var recentUseDates: [UUID: Date] = [:]

    mutating func recordUse(of workspaceID: UUID, at date: Date = Date()) {
        recentUseDates[workspaceID] = date
    }

    func pruned(to workspaces: [Workspace]) -> WorkspaceSidebarOrderingState {
        let validIDs = Set(workspaces.map(\.id))
        return WorkspaceSidebarOrderingState(
            manualOrderIDs: manualOrderIDs.filter(validIDs.contains),
            recentUseDates: recentUseDates.filter { validIDs.contains($0.key) }
        )
    }
}

struct WorkspaceSidebarGroup: Identifiable {
    enum Kind: String {
        case starred
        case other
    }

    let kind: Kind
    let workspaces: [Workspace]

    var id: Kind { kind }
    var title: String { kind == .starred ? "Starred" : "Other workspaces" }
}

enum WorkspaceSidebarOrdering {
    static func ordered(
        _ workspaces: [Workspace],
        mode: WorkspaceSidebarSortMode,
        state: WorkspaceSidebarOrderingState
    ) -> [Workspace] {
        let manualOrder = normalizedManualOrderIDs(state.manualOrderIDs, workspaces: workspaces)
        let manualRanks = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($0.element, $0.offset) })

        return workspaces.sorted { lhs, rhs in
            if lhs.isStarred != rhs.isStarred {
                return lhs.isStarred && !rhs.isStarred
            }

            switch mode {
            case .name:
                return nameOrdered(lhs, before: rhs)
            case .recent:
                let lhsDate = state.recentUseDates[lhs.id]
                let rhsDate = state.recentUseDates[rhs.id]
                if lhsDate != rhsDate {
                    if let lhsDate, let rhsDate { return lhsDate > rhsDate }
                    return lhsDate != nil
                }
                return nameOrdered(lhs, before: rhs)
            case .manual:
                let lhsRank = manualRanks[lhs.id] ?? Int.max
                let rhsRank = manualRanks[rhs.id] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return nameOrdered(lhs, before: rhs)
            }
        }
    }

    static func groups(_ workspaces: [Workspace]) -> [WorkspaceSidebarGroup] {
        let starred = workspaces.filter(\.isStarred)
        let other = workspaces.filter { !$0.isStarred }
        return [
            starred.isEmpty ? nil : WorkspaceSidebarGroup(kind: .starred, workspaces: starred),
            other.isEmpty ? nil : WorkspaceSidebarGroup(kind: .other, workspaces: other)
        ].compactMap { $0 }
    }

    static func normalizedManualOrderIDs(_ storedIDs: [UUID], workspaces: [Workspace]) -> [UUID] {
        let validIDs = Set(workspaces.map(\.id))
        var seen: Set<UUID> = []
        var normalized = storedIDs.filter { validIDs.contains($0) && seen.insert($0).inserted }
        let missing = workspaces
            .filter { !seen.contains($0.id) }
            .sorted { nameOrdered($0, before: $1) }
            .map(\.id)
        normalized.append(contentsOf: missing)
        return normalized
    }

    /// Resolves the persisted ranks to use when the user enters Manual mode.
    /// A valid saved rank represents user intent and must survive temporary
    /// visits to Name or Recently used. The visible order is used only to seed
    /// Manual mode when none of the saved ranks belongs to a current workspace.
    static func manualOrderIDsForEnteringManual(
        _ workspaces: [Workspace],
        currentMode: WorkspaceSidebarSortMode,
        state: WorkspaceSidebarOrderingState
    ) -> [UUID] {
        let validIDs = Set(workspaces.map(\.id))
        let hasRestorableOrder = state.manualOrderIDs.contains(where: validIDs.contains)
        if hasRestorableOrder {
            return normalizedManualOrderIDs(state.manualOrderIDs, workspaces: workspaces)
        }

        return ordered(workspaces, mode: currentMode, state: state).map(\.id)
    }

    /// Moves a workspace relative to another workspace in the same star group.
    /// Cross-group drops are rejected because reordering must never star or
    /// unstar a workspace as a hidden side effect.
    static func reorderedManualIDs(
        moving sourceID: UUID,
        onto targetID: UUID,
        workspaces: [Workspace],
        storedIDs: [UUID]
    ) -> [UUID]? {
        guard sourceID != targetID,
              let source = workspaces.first(where: { $0.id == sourceID }),
              let target = workspaces.first(where: { $0.id == targetID }),
              source.isStarred == target.isStarred else {
            return nil
        }

        var normalized = normalizedManualOrderIDs(storedIDs, workspaces: workspaces)
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        var groupIDs = normalized.filter { workspaceByID[$0]?.isStarred == source.isStarred }
        guard let sourceIndex = groupIDs.firstIndex(of: sourceID),
              let targetIndex = groupIDs.firstIndex(of: targetID) else {
            return nil
        }

        groupIDs.remove(at: sourceIndex)
        guard let adjustedTargetIndex = groupIDs.firstIndex(of: targetID) else { return nil }
        let insertionIndex = sourceIndex < targetIndex ? adjustedTargetIndex + 1 : adjustedTargetIndex
        groupIDs.insert(sourceID, at: min(insertionIndex, groupIDs.count))

        var nextGroupIndex = 0
        for index in normalized.indices where workspaceByID[normalized[index]]?.isStarred == source.isStarred {
            normalized[index] = groupIDs[nextGroupIndex]
            nextGroupIndex += 1
        }
        return normalized
    }

    private static func nameOrdered(_ lhs: Workspace, before rhs: Workspace) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum WorkspaceSidebarFilter {
    static func visibleWorkspaces(
        _ workspaces: [Workspace],
        showStarredOnly: Bool,
        searchText: String,
        sortMode: WorkspaceSidebarSortMode = .name,
        orderingState: WorkspaceSidebarOrderingState = WorkspaceSidebarOrderingState(),
        workspaceMatchesSearch: (Workspace) -> Bool,
        hasMatchingTasks: (Workspace) -> Bool
    ) -> [Workspace] {
        let sorted = WorkspaceSidebarOrdering.ordered(workspaces, mode: sortMode, state: orderingState)
        let filteredByStar = showStarredOnly ? sorted.filter(\.isStarred) : sorted
        guard !searchText.isEmpty else { return filteredByStar }

        return filteredByStar.filter { workspace in
            workspaceMatchesSearch(workspace) || hasMatchingTasks(workspace)
        }
    }
}

enum WorkspaceSidebarGroupingPresentation {
    static func showsLabels(groupCount: Int, showStarredOnly: Bool) -> Bool {
        groupCount > 1 || (showStarredOnly && groupCount == 1)
    }
}

enum WorkspaceSidebarFilterPresentation {
    static func helpText(isEnabled: Bool) -> String {
        isEnabled ? "Show all workspaces" : "Show starred only"
    }

    static let accessibilityHint = "Filters the workspace list without changing its order."
}

enum WorkspaceSidebarOrderingStore {
    private struct Payload: Codable {
        struct RecentUse: Codable {
            let workspaceID: UUID
            let date: Date
        }

        let manualOrderIDs: [UUID]
        let recentUses: [RecentUse]
    }

    static func load(defaults: UserDefaults = .standard) -> WorkspaceSidebarOrderingState {
        guard let data = defaults.data(forKey: AppStorageKeys.workspaceSidebarOrderingState),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return WorkspaceSidebarOrderingState()
        }
        return WorkspaceSidebarOrderingState(
            manualOrderIDs: payload.manualOrderIDs,
            recentUseDates: Dictionary(
                payload.recentUses.map { ($0.workspaceID, $0.date) },
                uniquingKeysWith: max
            )
        )
    }

    static func save(
        _ state: WorkspaceSidebarOrderingState,
        defaults: UserDefaults = .standard
    ) {
        let payload = Payload(
            manualOrderIDs: state.manualOrderIDs,
            recentUses: state.recentUseDates
                .map { Payload.RecentUse(workspaceID: $0.key, date: $0.value) }
                .sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: AppStorageKeys.workspaceSidebarOrderingState)
    }
}

enum WorkspaceSidebarScrollAnchor {
    static let coordinateSpaceName = "workspaceSidebarScroll"

    /// `ScrollViewProxy.scrollTo` uses the same unit point in the row and the
    /// viewport. Solving `a * viewport - a * rowHeight = priorMinY` preserves
    /// the selected row's top edge when a sort, rename, or star change moves it.
    static func unitPoint(rowFrame: CGRect, viewportHeight: CGFloat) -> UnitPoint {
        guard viewportHeight > rowFrame.height, viewportHeight > 0 else { return .top }
        let availableTravel = viewportHeight - rowFrame.height
        let y = min(1, max(0, rowFrame.minY / availableTravel))
        return UnitPoint(x: 0.5, y: y)
    }
}

enum WorkspaceSidebarDragPayload {
    /// Use the same system-declared text-object bridge as ASTRA's working task
    /// and Kanban drags. A private type registered only as raw data started a
    /// drag session but AppKit never negotiated it with the SwiftUI destination.
    /// The prefix keeps the payload unambiguous from task IDs and other text.
    static let type = UTType.utf8PlainText
    private static let prefix = "astra-workspace-sidebar-drag:"

    static func provider(for workspaceID: UUID) -> NSItemProvider {
        NSItemProvider(object: "\(prefix)\(workspaceID.uuidString)" as NSString)
    }

    static func loadWorkspaceID(
        from providers: [NSItemProvider],
        completion: @escaping (UUID?) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let rawValue = (object as? NSString).map(String.init)
            let workspaceID = rawValue.flatMap { value -> UUID? in
                guard value.hasPrefix(prefix) else { return nil }
                return UUID(uuidString: String(value.dropFirst(prefix.count)))
            }
            DispatchQueue.main.async { completion(workspaceID) }
        }
        return true
    }
}

struct WorkspaceSidebarSelectedRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

struct WorkspaceSidebarViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct WorkspaceSidebarGroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarLeanPresentation.workspaceSectionHorizontalInset
                + SidebarLeanPresentation.workspaceRowContentLeadingPadding)
            .padding(.top, 7)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SidebarWorkspaceSortIcon: View {
    let mode: WorkspaceSidebarSortMode
    var isHovered = false

    var body: some View {
        Image(systemName: mode.systemImage)
            .font(Stanford.ui(12, weight: .medium))
            .foregroundStyle(mode == .name ? Color.secondary : Stanford.lagunita)
            .frame(
                width: SidebarWorkspaceStarPresentation.frameSize,
                height: SidebarWorkspaceStarPresentation.frameSize
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarWorkspaceStarPresentation.cornerRadius)
                    .fill(Stanford.lagunita.opacity(isHovered || mode != .name ? 0.10 : 0))
            )
            .contentShape(Rectangle())
    }
}
