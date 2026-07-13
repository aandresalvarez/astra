import Testing
import Foundation
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Stress tests for UI state owners under rapid, adversarial sequences:
/// snapshot-refresh storms and task switching on `TaskThreadViewModel`,
/// sidebar settle/toggle races, accordion echo-guard fuzzing, scroll-recovery
/// watchdog floods, per-conversation canvas memory growth, scene-selection
/// churn, and App Studio stale-turn invalidation. All fixtures are headless;
/// every suite that persists uses a throwaway `UserDefaults` suite.
///
/// Opt-in: runs only with `RUN_UI_STRESS=1` (see `uiStressSuitesEnabled`).
@MainActor
@Suite(
    "UI stress: state churn",
    .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run the UI stress suites")
)
struct UIStressStateChurnTests {
    // MARK: - Helpers

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Polls a MainActor condition without blocking the actor, so debounce
    /// timers and detached workers can make progress while we wait.
    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suiteName = "ui-stress-\(name)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - TaskThreadViewModel refresh storms

    @Test("200-burst refresh storm coalesces into a handful of builds without losing the final state")
    func refreshStormCoalescesWithoutLosingFinalState() async {
        let task = makeTask(goal: "Storm target", status: .running)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)

        let viewModel = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            TaskThreadSnapshot(input: input)
        })
        viewModel.reset(for: task)

        for index in 0..<200 {
            task.events.append(makeEvent(
                task: task,
                type: "user.message",
                payload: "storm message \(index)",
                timestamp: Date(timeIntervalSince1970: Double(100 + index)),
                run: nil
            ))
            task.updatedAt = Date()
            viewModel.requestSnapshotRefresh(for: task)
        }

        let settled = await waitUntil(timeout: .seconds(8)) {
            viewModel.snapshot?.sortedEvents.contains { $0.payload == "storm message 199" } ?? false
        }
        #expect(settled, "final storm message must reach the applied snapshot (no lost trailing update)")
        // 200 requests in one burst must collapse into a small number of
        // debounced builds; the exact count varies with timing, the order of
        // magnitude must not.
        #expect(viewModel.snapshotBuildCountForTesting <= 20,
                "expected coalescing, got \(viewModel.snapshotBuildCountForTesting) builds for 200 requests")
        #expect(viewModel.appliedSnapshotTaskID == task.id)
    }

    @Test("interleaved task-switch churn lands on the last task with no stale apply")
    func taskSwitchChurnLandsOnLastTask() async {
        let taskA = makeTask(goal: "Task A goal", status: .running)
        let taskB = makeTask(goal: "Task B goal", status: .running)
        for (offset, task) in [taskA, taskB].enumerated() {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(offset + 1))
            run.status = .running
            task.runs.append(run)
            task.events = (0..<40).map { index in
                makeEvent(
                    task: task,
                    type: "agent.response",
                    payload: "history \(index)",
                    timestamp: Date(timeIntervalSince1970: Double(10 + index)),
                    run: run
                )
            }
        }

        // A deliberately slow builder widens the window in which a stale
        // build could overwrite a newer task's snapshot.
        let viewModel = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            try? await Task.sleep(for: .milliseconds(8))
            return TaskThreadSnapshot(input: input)
        })

        for cycle in 0..<40 {
            viewModel.reset(for: cycle.isMultiple(of: 2) ? taskA : taskB)
            if cycle.isMultiple(of: 5) {
                await Task.yield()
            }
        }
        viewModel.reset(for: taskB)

        let settled = await waitUntil(timeout: .seconds(8)) {
            viewModel.appliedSnapshotTaskID == taskB.id && viewModel.appliedSnapshotRevision > 0
        }
        #expect(settled, "switch churn must settle on the last task")
        guard case .userMessage(let goalText, _) = viewModel.snapshot?.conversationItems.first else {
            Issue.record("expected the goal user message as the first conversation item")
            return
        }
        #expect(goalText == "Task B goal", "a stale build from the abandoned task must never apply")
    }

    // MARK: - Sidebar presentation churn

    @Test("seeded sidebar op storm preserves mode/width invariants")
    func sidebarOpStormPreservesInvariants() {
        let model = SidebarPresentationModel(defaults: scratchDefaults())
        var rng = SplitMix64(state: 0xA57A_0003)
        var width: CGFloat = 1_500
        var hasPanel = false
        model.setResponsiveWidth(width)

        for step in 0..<3_000 {
            switch rng.next() % 7 {
            case 0:
                width = CGFloat(600 + rng.next() % 1_600)
                model.setResponsiveWidth(width)
            case 1:
                hasPanel.toggle()
                model.setHasRightSidePanel(hasPanel)
            case 2:
                model.toggle()
            case 3:
                model.noteColumnWidth(CGFloat(200 + rng.next() % 300))
            case 4:
                model.proposeCompressedCollapse()
            case 5:
                model.handleSelectionCommitted()
            default:
                model.dismissOverlay()
            }

            let canDock = PanelLayoutGeometry.canDockSidebar(width: width, hasRightSidePanel: hasPanel)
            if model.mode == .docked {
                #expect(canDock, "step \(step): docked while geometry forbids docking (width \(width), panel \(hasPanel))")
            }
            if model.mode == .overlay {
                #expect(!canDock, "step \(step): overlay while docking is possible")
            }
            #expect(model.sidebarWidth >= SidebarColumnLayout.expandedMinimumWidth)
            #expect(model.sidebarWidth <= SidebarColumnLayout.expandedMaximumWidth)
        }
    }

    @Test("a docked reveal with no readable-width probe leaves the settle guard armed")
    func dockedRevealWithoutProbeKeepsSettleArmed() async {
        // Documents the deliberate guard in SidebarPresentationModel.beginSettle:
        // the fallback timer refuses to clear `isSettling` for a docked reveal,
        // so if the AppKit probe never reports a readable width the
        // compressed-collapse proposals stay suppressed indefinitely. See the
        // stress findings report; a missed probe leaves the guard armed forever.
        let model = SidebarPresentationModel(defaults: scratchDefaults())
        model.setResponsiveWidth(1_500)
        model.toggle() // hide
        #expect(model.mode == .collapsed)
        model.toggle() // reveal -> beginSettle
        #expect(model.mode == .docked)
        #expect(model.isSettling)

        try? await Task.sleep(for: .milliseconds(650))
        #expect(model.isSettling, "fallback timeout must not clear a docked reveal")

        // Collapse proposals are suppressed the whole time.
        model.proposeCompressedCollapse()
        #expect(model.mode == .docked)

        // The AppKit probe finally reports readable width: guard releases.
        model.noteReadableSplitSubviewWidth(SidebarColumnLayout.expandedIdealWidth)
        #expect(!model.isSettling)
        model.proposeCompressedCollapse()
        #expect(model.mode == .collapsed, "after settling, compressed collapse applies again")
    }

    @Test("rapid toggle bursts leave intent, persistence, and mode coherent")
    func rapidToggleBurstsStayCoherent() async {
        let defaults = scratchDefaults()
        let model = SidebarPresentationModel(defaults: defaults)
        model.setResponsiveWidth(1_600)

        let initiallyShown = model.isSidebarShown
        for _ in 0..<50 {
            model.toggle()
        }
        // An even number of flips must return exactly to the initial intent.
        #expect(model.isSidebarShown == initiallyShown)
        #expect(model.mode == (initiallyShown ? .docked : .collapsed))
        #expect(defaults.object(forKey: "sidebarUserVisible") as? Bool == initiallyShown)

        model.toggle()
        #expect(model.isSidebarShown == !initiallyShown)
        #expect(model.mode == (initiallyShown ? .collapsed : .docked))
        model.noteReadableSplitSubviewWidth(SidebarColumnLayout.expandedIdealWidth)
        #expect(!model.isSettling)
    }

    // MARK: - Accordion echo-guard fuzz

    @Test("20k random accordion ops never leave the open drawer dismissed")
    func accordionFuzzKeepsOpenAndDismissedDisjoint() {
        let workspaceIDs = (0..<8).map { _ in UUID() }
        var rng = SplitMix64(state: 0xA57A_0004)
        var state = WorkspaceSidebarAccordion.State()

        for step in 0..<20_000 {
            let id = workspaceIDs[Int(rng.next() % 8)]
            switch rng.next() % 5 {
            case 0:
                let rendered = WorkspaceSidebarAccordion.isExpanded(
                    workspaceID: id,
                    state: state,
                    isSearchActive: rng.next() % 2 == 0,
                    matchesSearch: { rng.next() % 2 == 0 }
                )
                state = WorkspaceSidebarAccordion.toggling(id, in: state, wasExpanded: rendered)
            case 1:
                state = WorkspaceSidebarAccordion.selecting(id, in: state)
            case 2:
                state = WorkspaceSidebarAccordion.selectionChanged(id, in: state)
            case 3:
                state = WorkspaceSidebarAccordion.searchChanged(in: state)
            default:
                state = WorkspaceSidebarAccordion.selectionChanged(nil, in: state)
            }

            if let open = state.openWorkspaceID {
                #expect(!state.dismissedWorkspaceIDs.contains(open),
                        "step \(step): open drawer is simultaneously dismissed")
            }
            #expect(state.dismissedWorkspaceIDs.count <= workspaceIDs.count)
        }
    }

    @Test("the collapse-click selection echo can never reopen the drawer")
    func collapseEchoNeverReopens() {
        let id = UUID()
        var state = WorkspaceSidebarAccordion.selecting(id, in: .init())
        #expect(state.openWorkspaceID == id)

        state = WorkspaceSidebarAccordion.toggling(id, in: state, wasExpanded: true)
        #expect(state.openWorkspaceID == nil)

        // The deferred onChange echo fires with the same workspace.
        state = WorkspaceSidebarAccordion.selectionChanged(id, in: state)
        #expect(state.openWorkspaceID == nil, "echo must not undo the collapse")

        // A real, direct selection still reopens.
        state = WorkspaceSidebarAccordion.selecting(id, in: state)
        #expect(state.openWorkspaceID == id)
    }

    // MARK: - Scroll-recovery watchdog floods

    @Test("alternating parked/healthy floods never fire a recovery")
    func watchdogAlternatingFloodNeverFires() async {
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: 5_000_000)
        var recoveries = 0
        for index in 0..<300 {
            watchdog.sentinelDidUpdate(bottomMinY: index.isMultiple(of: 2) ? -60 : 240) { _ in
                recoveries += 1
            }
        }
        watchdog.sentinelDidUpdate(bottomMinY: 240) { _ in recoveries += 1 }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(recoveries == 0, "a sentinel that recovers on its own must never trigger recovery")
    }

    @Test("a genuinely stuck park fires exactly once despite 500 armed timers")
    func watchdogStuckParkFiresExactlyOnce() async {
        let watchdog = ChatScrollRecoveryWatchdog(settleNanoseconds: 5_000_000)
        var recoveries = 0
        for _ in 0..<500 {
            watchdog.sentinelDidUpdate(bottomMinY: -80) { _ in recoveries += 1 }
        }
        let fired = await waitUntil(timeout: .seconds(2)) { recoveries >= 1 }
        #expect(fired, "a stuck park must eventually recover")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(recoveries == 1, "token guard must collapse 500 armed timers into one recovery")
    }

    // MARK: - Right panel: per-conversation canvas memory growth

    @Test("2k-conversation canvas memory grows unbounded and stays functional")
    func canvasMemoryGrowsUnboundedAcrossConversations() throws {
        // Documents the missing eviction in WorkspaceCanvasItemPreference
        // storage: one JSON entry per conversation ever seen, decoded and
        // re-encoded on every canvas change. See the stress findings report.
        let model = RightPanelPresentationModel(defaults: scratchDefaults())
        let conversations = 2_000

        let elapsed = ContinuousClock().measure {
            for index in 0..<conversations {
                model.presentCanvas(.markdown, conversationID: "conversation-\(index)")
            }
        }

        let data = try #require(model.rememberedItemsRawValue.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded.count == conversations,
                "every conversation is remembered forever (no eviction policy)")
        // Full-blob decode+encode per op is quadratic in remembered
        // conversations; this bounds the whole 2k storm rather than per-op.
        #expect(elapsed < .seconds(10), "2k canvas ops took \(elapsed)")

        model.setActiveCanvasItem(nil, remember: false, conversationID: nil)
        model.dismissRail()
        let restored = model.restoreRememberedItemIfAvailable(
            conversationID: "conversation-42",
            canPresent: { _ in true }
        )
        #expect(restored == .markdown, "storm must not corrupt individual conversation memory")
    }

    // MARK: - Scene selection churn

    @Test("seeded scene-selection churn keeps surfaces mutually exclusive")
    func sceneSelectionChurnKeepsSurfacesExclusive() {
        let workspaceA = makeWorkspace(name: "Alpha")
        let workspaceB = makeWorkspace(name: "Beta")
        let tasks = [
            makeTask(title: "T1", workspace: workspaceA),
            makeTask(title: "T2", workspace: workspaceA),
            makeTask(title: "T3", workspace: workspaceB)
        ]
        let model = SceneSelectionModel()
        var rng = SplitMix64(state: 0xA57A_0005)

        for step in 0..<5_000 {
            switch rng.next() % 7 {
            case 0: model.openTask(tasks[Int(rng.next() % 3)])
            case 1: model.openWorkspace(rng.next() % 2 == 0 ? workspaceA : workspaceB)
            case 2: model.composeTask(workspace: rng.next() % 2 == 0 ? workspaceA : nil)
            case 3: model.composeApp(workspace: rng.next() % 2 == 0 ? workspaceB : nil)
            case 4: model.clear()
            case 5: model.clearWorkspaceAppSurface()
            default: model.openTask(nil)
            }

            if model.selectedTask != nil {
                #expect(!model.isComposingTask, "step \(step): task selection and task composer overlap")
                #expect(!model.isComposingWorkspaceApp, "step \(step): task selection and app composer overlap")
                #expect(model.selectedWorkspaceApp == nil, "step \(step): task and app surfaces overlap")
            }
            #expect(!(model.isComposingTask && model.isComposingWorkspaceApp),
                    "step \(step): both composers active")
            if let task = model.selectedTask, let workspace = task.workspace {
                #expect(model.selectedWorkspace === workspace,
                        "step \(step): task selection must adopt the task's workspace")
            }
        }
    }

    // MARK: - App Studio stale-turn invalidation

    private final class StudioJournalSpy: WorkspaceAppStudioJournalStoring {
        private(set) var saveCount = 0
        func load(appID: String, workspacePath: String) -> WorkspaceAppStudioJournal {
            WorkspaceAppStudioJournal()
        }
        func save(_ journal: WorkspaceAppStudioJournal, appID: String, workspacePath: String) {
            saveCount += 1
        }
    }

    private static let studioNoVerify: WorkspaceAppStudioVerify = { _, _, _, _ in
        WorkspaceAppStudioVerification(status: .notApplicable, headline: "", detail: "", autoExercise: nil, scenario: nil)
    }

    private static func studioResult(summary: String) -> WorkspaceAppStudioGenerationResult {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build a tracker app.")
        return WorkspaceAppStudioGenerationResult(
            manifest: manifest,
            validationReport: WorkspaceAppManifestValidator.validate(manifest),
            accepted: true,
            origin: .model,
            attemptCount: 1,
            providerFailure: nil,
            summary: summary
        )
    }

    private func submitStudioTurn(
        _ session: WorkspaceAppStudioSession,
        _ text: String,
        _ workspace: Workspace
    ) async {
        await session.submit(
            text,
            workspace: workspace,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model,
            availableProviders: []
        )
    }

    @Test("a reset mid-generation discards the stale turn and accepts the next one")
    func studioResetMidGenerationDiscardsStaleTurn() async {
        let workspace = makeWorkspace(name: "Studio")
        let session = WorkspaceAppStudioSession(
            generate: { intent, _, _, _, _, _, _, _ in
                if intent.contains("SLOW") {
                    try? await Task.sleep(for: .milliseconds(250))
                    return Self.studioResult(summary: "STALE-TURN-SUMMARY")
                }
                return Self.studioResult(summary: "FRESH-TURN-SUMMARY")
            },
            verify: Self.studioNoVerify,
            journalStore: StudioJournalSpy()
        )
        session.reset(for: workspace)

        let slowTurn = Task { await self.submitStudioTurn(session, "SLOW build a tracker", workspace) }
        let started = await waitUntil(timeout: .seconds(2)) { session.isGenerating }
        #expect(started, "slow turn must enter its generating window")

        session.reset(for: workspace)
        let idleAfterReset = await waitUntil(timeout: .seconds(2)) { !session.isGenerating }
        #expect(idleAfterReset, "reset mid-generation must not strand isGenerating")

        await submitStudioTurn(session, "build the fresh tracker", workspace)
        _ = await slowTurn.value

        let texts = session.messages.map(\.text)
        #expect(texts.contains { $0.contains("FRESH-TURN-SUMMARY") },
                "the post-reset turn must land")
        #expect(!texts.contains { $0.contains("STALE-TURN-SUMMARY") },
                "the abandoned turn must never write into the new conversation")
        #expect(!session.isGenerating)
    }

    @Test("30 rapid submit/reset cycles never wedge the studio session")
    func studioRapidCyclesNeverWedge() async {
        let workspace = makeWorkspace(name: "Studio churn")
        let session = WorkspaceAppStudioSession(
            generate: { _, _, _, _, _, _, _, _ in
                try? await Task.sleep(for: .milliseconds(5))
                return Self.studioResult(summary: "CYCLE-SUMMARY")
            },
            verify: Self.studioNoVerify,
            journalStore: StudioJournalSpy()
        )

        for cycle in 0..<30 {
            session.reset(for: workspace)
            let turn = Task { await self.submitStudioTurn(session, "cycle \(cycle)", workspace) }
            if cycle.isMultiple(of: 3) {
                session.cancelGeneration()
            }
            _ = await turn.value
        }

        let idle = await waitUntil(timeout: .seconds(4)) { !session.isGenerating && !session.isVerifying }
        #expect(idle, "session must always return to idle after churn")
    }
}
