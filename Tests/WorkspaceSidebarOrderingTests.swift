import Foundation
import SwiftUI
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace sidebar ordering")
struct WorkspaceSidebarOrderingTests {
    @Test("Name sort keeps starred first and alphabetizes inside each group")
    func nameSortKeepsStarredFirst() {
        let starredZulu = workspace("Zulu", starred: true)
        let regularAlpha = workspace("alpha")
        let starredBeta = workspace("beta", starred: true)
        let regularBravo = workspace("Bravo")

        let ordered = WorkspaceSidebarOrdering.ordered(
            [regularBravo, starredZulu, regularAlpha, starredBeta],
            mode: .name,
            state: WorkspaceSidebarOrderingState()
        )

        let actualIDs = ordered.map(\.id)
        let expectedIDs = [starredBeta.id, starredZulu.id, regularAlpha.id, regularBravo.id]
        #expect(actualIDs == expectedIDs)
    }

    @Test("Recent sort uses actual selection dates without crossing star groups")
    func recentSortStaysInsideStarGroups() {
        let starredOld = workspace("Starred old", starred: true)
        let starredNew = workspace("Starred new", starred: true)
        let regularNewest = workspace("Regular newest")
        let regularUnknown = workspace("Regular unknown")
        let state = WorkspaceSidebarOrderingState(
            recentUseDates: [
                starredOld.id: Date(timeIntervalSince1970: 10),
                starredNew.id: Date(timeIntervalSince1970: 20),
                regularNewest.id: Date(timeIntervalSince1970: 30)
            ]
        )

        let ordered = WorkspaceSidebarOrdering.ordered(
            [regularUnknown, starredOld, regularNewest, starredNew],
            mode: .recent,
            state: state
        )

        let actualIDs = ordered.map(\.id)
        let expectedIDs = [starredNew.id, starredOld.id, regularNewest.id, regularUnknown.id]
        #expect(actualIDs == expectedIDs)
    }

    @Test("Manual sort follows saved ranks inside each star group")
    func manualSortStaysInsideStarGroups() {
        let starredFirst = workspace("Starred first", starred: true)
        let starredSecond = workspace("Starred second", starred: true)
        let regularFirst = workspace("Regular first")
        let regularSecond = workspace("Regular second")
        let state = WorkspaceSidebarOrderingState(manualOrderIDs: [
            regularSecond.id,
            starredSecond.id,
            regularFirst.id,
            starredFirst.id
        ])

        let ordered = WorkspaceSidebarOrdering.ordered(
            [starredFirst, regularFirst, starredSecond, regularSecond],
            mode: .manual,
            state: state
        )

        let actualIDs = ordered.map(\.id)
        let expectedIDs = [starredSecond.id, starredFirst.id, regularSecond.id, regularFirst.id]
        #expect(actualIDs == expectedIDs)
    }

    @Test("Workspace groups expose the two ordering tiers with explicit labels")
    func groupingExplainsOrderingTiers() {
        let starred = workspace("Starred", starred: true)
        let regular = workspace("Regular")

        let groups = WorkspaceSidebarOrdering.groups([starred, regular])

        #expect(groups.map(\.title) == ["Starred", "Other workspaces"])
        #expect(groups.map { $0.workspaces.map(\.id) } == [[starred.id], [regular.id]])
        #expect(WorkspaceSidebarGroupingPresentation.showsLabels(groupCount: groups.count, showStarredOnly: false))
        #expect(!WorkspaceSidebarGroupingPresentation.showsLabels(groupCount: 1, showStarredOnly: false))
        #expect(WorkspaceSidebarGroupingPresentation.showsLabels(groupCount: 1, showStarredOnly: true))
    }

    @Test("Manual drag reorders within a group and rejects cross-group drops")
    func manualDragHonorsStarBoundary() throws {
        let first = workspace("First", starred: true)
        let second = workspace("Second", starred: true)
        let third = workspace("Third", starred: true)
        let regular = workspace("Regular")
        let workspaces = [first, second, third, regular]
        let stored = workspaces.map(\.id)

        let reordered = try #require(WorkspaceSidebarOrdering.reorderedManualIDs(
            moving: first.id,
            onto: third.id,
            workspaces: workspaces,
            storedIDs: stored
        ))

        #expect(reordered == [second.id, third.id, first.id, regular.id])
        #expect(WorkspaceSidebarOrdering.reorderedManualIDs(
            moving: first.id,
            onto: regular.id,
            workspaces: workspaces,
            storedIDs: stored
        ) == nil)
    }

    @Test("Manual order repairs duplicates, deleted IDs, and new workspaces deterministically")
    func manualOrderNormalizesPersistedIDs() {
        let alpha = workspace("Alpha")
        let beta = workspace("Beta")
        let deletedID = UUID()

        let normalized = WorkspaceSidebarOrdering.normalizedManualOrderIDs(
            [beta.id, deletedID, beta.id],
            workspaces: [alpha, beta]
        )

        #expect(normalized == [beta.id, alpha.id])
    }

    @Test("Returning to Manual restores the saved order instead of the temporary sort")
    func manualModeEntryRestoresSavedOrder() {
        let alpha = workspace("Alpha")
        let beta = workspace("Beta")
        let charlie = workspace("Charlie")
        let savedOrder = [charlie.id, alpha.id, beta.id]
        let state = WorkspaceSidebarOrderingState(manualOrderIDs: savedOrder)

        let restored = WorkspaceSidebarOrdering.manualOrderIDsForEnteringManual(
            [alpha, beta, charlie],
            currentMode: .name,
            state: state
        )

        #expect(restored == savedOrder)
    }

    @Test("Entering Manual seeds the visible order only without restorable ranks")
    func firstManualModeEntrySeedsVisibleOrder() {
        let alpha = workspace("Alpha")
        let beta = workspace("Beta")
        let deletedID = UUID()
        let state = WorkspaceSidebarOrderingState(
            manualOrderIDs: [deletedID],
            recentUseDates: [beta.id: Date(timeIntervalSince1970: 10)]
        )

        let seeded = WorkspaceSidebarOrdering.manualOrderIDsForEnteringManual(
            [alpha, beta],
            currentMode: .recent,
            state: state
        )

        #expect(seeded == [beta.id, alpha.id])
    }

    @Test("Ordering state persists manual ranks and recent-use dates")
    func orderingStateRoundTrips() throws {
        let suiteName = "WorkspaceSidebarOrderingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstID = UUID()
        let secondID = UUID()
        let state = WorkspaceSidebarOrderingState(
            manualOrderIDs: [secondID, firstID],
            recentUseDates: [firstID: Date(timeIntervalSince1970: 123)]
        )

        WorkspaceSidebarOrderingStore.save(state, defaults: defaults)

        #expect(WorkspaceSidebarOrderingStore.load(defaults: defaults) == state)
        defaults.set(Data("not-json".utf8), forKey: AppStorageKeys.workspaceSidebarOrderingState)
        #expect(WorkspaceSidebarOrderingStore.load(defaults: defaults) == WorkspaceSidebarOrderingState())
    }

    @Test("Recent-use state is selection-driven and prunes removed workspaces")
    func recentUseRecordsSelectionsAndPrunesDeletedWorkspaces() {
        let kept = workspace("Kept")
        let deleted = workspace("Deleted")
        let date = Date(timeIntervalSince1970: 456)
        var state = WorkspaceSidebarOrderingState(manualOrderIDs: [deleted.id, kept.id])
        state.recordUse(of: kept.id, at: date)
        state.recordUse(of: deleted.id, at: Date(timeIntervalSince1970: 123))

        let pruned = state.pruned(to: [kept])

        #expect(pruned.manualOrderIDs == [kept.id])
        #expect(pruned.recentUseDates == [kept.id: date])
    }

    @Test("Filter help names the action in both states")
    func filterHelpIsExplicit() {
        #expect(WorkspaceSidebarFilterPresentation.helpText(isEnabled: false) == "Show starred only")
        #expect(WorkspaceSidebarFilterPresentation.helpText(isEnabled: true) == "Show all workspaces")
        #expect(WorkspaceSidebarFilterPresentation.accessibilityHint.contains("without changing its order"))
    }

    @Test("Sort menu exposes all requested modes")
    func sortMenuModesAreComplete() {
        #expect(WorkspaceSidebarSortMode.allCases.map(\.title) == ["Name", "Recently used", "Manual"])
        #expect(Set(WorkspaceSidebarSortMode.allCases.map(\.systemImage)).count == 3)
    }

    @Test("Selected row anchor preserves its viewport offset")
    func selectedRowAnchorPreservesOffset() {
        let anchor = WorkspaceSidebarScrollAnchor.unitPoint(
            rowFrame: CGRect(x: 0, y: 90, width: 200, height: 40),
            viewportHeight: 400
        )

        #expect(abs(anchor.y - 0.25) < 0.000_001)
        #expect(WorkspaceSidebarScrollAnchor.unitPoint(
            rowFrame: CGRect(x: 0, y: 0, width: 200, height: 500),
            viewportHeight: 400
        ) == .top)
    }

    @Test("Workspace drag payload round-trips only the workspace identity")
    func dragPayloadRoundTrips() async {
        let workspaceID = UUID()
        let provider = WorkspaceSidebarDragPayload.provider(for: workspaceID)

        #expect(WorkspaceSidebarDragPayload.type.isDeclared)
        #expect(WorkspaceSidebarDragPayload.type.conforms(to: .data))
        #expect(provider.hasItemConformingToTypeIdentifier(WorkspaceSidebarDragPayload.type.identifier))
        #expect(provider.canLoadObject(ofClass: NSString.self))

        let loadedID: UUID? = await withCheckedContinuation { continuation in
            let accepted = WorkspaceSidebarDragPayload.loadWorkspaceID(from: [provider]) {
                continuation.resume(returning: $0)
            }
            #expect(accepted)
        }

        #expect(loadedID == workspaceID)
    }

    @Test("Workspace drop payload rejects ordinary task text")
    func dragPayloadRejectsTaskIDs() async {
        let taskProvider = NSItemProvider(object: UUID().uuidString as NSString)

        let loadedID: UUID? = await withCheckedContinuation { continuation in
            let accepted = WorkspaceSidebarDragPayload.loadWorkspaceID(from: [taskProvider]) {
                continuation.resume(returning: $0)
            }
            #expect(accepted)
        }

        #expect(loadedID == nil)
    }

    @Test("Workspace ordering preference keys remain versioned")
    func orderingPreferenceKeysAreVersioned() {
        #expect(AppStorageKeys.workspaceSidebarSortMode == "astra.sidebar.workspaceSortMode.v1")
        #expect(AppStorageKeys.workspaceSidebarOrderingState == "astra.sidebar.workspaceOrderingState.v1")
    }

    private func workspace(_ name: String, starred: Bool = false) -> Workspace {
        let workspace = Workspace(name: name, primaryPath: "/tmp/\(UUID().uuidString)")
        workspace.isStarred = starred
        return workspace
    }
}
