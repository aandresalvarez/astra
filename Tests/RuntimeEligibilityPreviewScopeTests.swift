import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The composer scores runtime eligibility after every typing pause, and
/// admission costs roughly the same for each runtime it scores. Scoring all six
/// registered runtimes made the pause cost six times what Send actually needs,
/// so the typing path now scores the selected runtime alone. These pin the two
/// properties that make the narrowing safe: the narrow pass really is narrow,
/// and the surfaces that need every runtime still get every runtime.
@Suite("Runtime eligibility preview scope")
@MainActor
struct RuntimeEligibilityPreviewScopeTests {
    /// The container is returned, not just its context: letting it deallocate
    /// tears the model instances out from under the test
    /// ("destroyed by calling ModelContext.reset").
    private func makeEnvironment() throws -> (
        task: AgentTask,
        container: ModelContainer,
        root: URL
    ) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-elig-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Scope", primaryPath: root.path)
        context.insert(workspace)
        let task = AgentTask(
            title: "Scope task",
            goal: "Summarize the ticket",
            workspace: workspace,
            runtime: .claudeCode
        )
        context.insert(task)
        try context.save()
        return (task, container, root)
    }

    private func request(
        for task: AgentTask,
        selectedReadiness: RuntimeReadinessState = .ready
    ) -> RuntimeEligibilityPreviewRequest {
        var readiness = Dictionary(
            uniqueKeysWithValues: AgentRuntimeAdapterRegistry.runtimeIDs.map { ($0, RuntimeReadinessState.ready) }
        )
        readiness[task.resolvedRuntimeID] = selectedReadiness
        return .existingTask(
            task: task,
            messageText: "Summarize what you found",
            attachedFiles: [],
            selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            skipPermissions: false,
            providerSettings: .headlessScenario,
            readinessStates: readiness,
            eventRevision: 0
        )
    }

    @Test("An inconclusive provider check does not disable the selected composer")
    func warningReadinessCanSubmitWhenAdmissionPasses() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let warningRequest = request(for: environment.task, selectedReadiness: .warning)
        let warningSnapshot = try #require(
            await warningRequest.evaluate(candidateRuntimes: [warningRequest.selectedRuntime])
        )
        #expect(warningSnapshot.selectedCandidate.isEligible)
        let warningState = RuntimeEligibilityPreviewState.evaluated(
            signature: warningRequest.signature,
            snapshot: warningSnapshot
        )
        #expect(RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: true,
            runtime: warningRequest.selectedRuntime,
            readinessStates: [.claudeCode: .warning],
            previewState: warningState,
            signature: warningRequest.signature
        ))

        let blockedRequest = request(for: environment.task, selectedReadiness: .blocked)
        let blockedSnapshot = try #require(
            await blockedRequest.evaluate(candidateRuntimes: [blockedRequest.selectedRuntime])
        )
        #expect(!blockedSnapshot.selectedCandidate.isEligible)

        let workspace = try #require(environment.task.workspace)
        let newTaskRequest = RuntimeEligibilityPreviewRequest.newTask(
            draftTask: nil,
            workspace: workspace,
            selectedSkills: [],
            attachedFiles: [],
            acceptedTurn: "Summarize this folder",
            requestedRuntime: .claudeCode,
            runtimeExplicitlySelected: false,
            selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            skipPermissions: false,
            defaultModel: "test-model",
            defaultBudget: 1_000,
            providerSettings: .headlessScenario,
            readinessStates: [.claudeCode: .warning]
        )
        let newTaskSnapshot = try #require(
            await newTaskRequest.evaluate(candidateRuntimes: [.claudeCode])
        )
        #expect(newTaskSnapshot.selectedCandidate.isEligible)
    }

    @Test("The typing pass scores only the runtime the composer would launch")
    func typingPassScoresOnlySelectedRuntime() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let request = request(for: environment.task)
        let snapshot = try #require(
            await request.evaluate(candidateRuntimes: [request.selectedRuntime])
        )

        #expect(snapshot.candidates.count == 1)
        #expect(snapshot.candidates[request.selectedRuntime] != nil)
        #expect(snapshot.selectedRuntime == request.selectedRuntime)
    }

    /// The saving only holds if the unscoped pass still covers everything —
    /// otherwise the dropdown and the fallback suggestion quietly lose runtimes.
    @Test("The unscoped pass still scores every registered runtime")
    func unscopedPassScoresEveryRuntime() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let snapshot = try #require(await request(for: environment.task).evaluate())

        #expect(snapshot.candidates.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            #expect(snapshot.candidates[runtime] != nil, "\(runtime) went unscored")
        }
    }

    /// The provider dropdown lists every runtime. A narrow pass must not empty
    /// it, so verdicts the pass did not refresh are carried forward.
    @Test("Carrying forward keeps unscored runtimes and lets fresh verdicts win")
    func carryForwardKeepsUnscoredRuntimesAndPrefersFreshVerdicts() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let request = request(for: environment.task)
        let full = try #require(await request.evaluate())
        let narrow = try #require(
            await request.evaluate(candidateRuntimes: [request.selectedRuntime])
        )

        let merged = narrow.carryingForwardUnscoredCandidates(from: full)

        #expect(merged.candidates.count == full.candidates.count)
        // The runtime the narrow pass scored comes from the narrow pass.
        #expect(
            merged.candidates[request.selectedRuntime]?.isEligible
                == narrow.candidates[request.selectedRuntime]?.isEligible
        )
        #expect(merged.launchBlock?.suggestedRuntime == narrow.launchBlock?.suggestedRuntime)
    }

    /// The new-task composer builds its preview task inside the evaluation
    /// closure, so every edit used to mint a fresh UUID — no two previews
    /// agreed on an identity, carry-forward was refused, and the provider menu
    /// dropped every runtime the narrow pass had not scored. This is that path,
    /// which the persisted-task cases above cannot reach.
    @Test("A new-task composer keeps one identity across edits so verdicts carry forward")
    func newTaskComposerCarriesForwardAcrossEdits() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let workspace = try #require(environment.task.workspace)
        let readiness = Dictionary(
            uniqueKeysWithValues: AgentRuntimeAdapterRegistry.runtimeIDs.map { ($0, RuntimeReadinessState.ready) }
        )
        func composerRequest(acceptedTurn: String) -> RuntimeEligibilityPreviewRequest {
            .newTask(
                draftTask: nil,
                workspace: workspace,
                selectedSkills: [],
                attachedFiles: [],
                acceptedTurn: acceptedTurn,
                requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: false,
                selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                skipPermissions: false,
                defaultModel: "test-model",
                defaultBudget: 1_000,
                providerSettings: .headlessScenario,
                readinessStates: readiness
            )
        }

        // The full pass for one draft of the text, then a narrow pass after an edit.
        let full = try #require(await composerRequest(acceptedTurn: "Build a thing").evaluate())
        let edited = composerRequest(acceptedTurn: "Build a thing now")
        let narrow = try #require(
            await edited.evaluate(candidateRuntimes: [edited.selectedRuntime])
        )

        #expect(narrow.taskID == full.taskID, "the composer changed identity between edits")
        let merged = narrow.carryingForwardUnscoredCandidates(from: full)
        #expect(merged.candidates.count == full.candidates.count)
    }

    /// Carrying a verdict across tasks would show one task's provider
    /// availability in another's composer.
    @Test("Carrying forward ignores a snapshot from a different task")
    func carryForwardIgnoresForeignSnapshot() async throws {
        let first = try makeEnvironment()
        let second = try makeEnvironment()
        defer {
            _ = (first.container, second.container)
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }

        let foreignFull = try #require(await request(for: second.task).evaluate())
        let narrow = try #require(
            await request(for: first.task)
                .evaluate(candidateRuntimes: [first.task.resolvedRuntimeID])
        )

        let merged = narrow.carryingForwardUnscoredCandidates(from: foreignFull)

        #expect(merged.candidates.count == 1)
        #expect(merged.taskID == first.task.id)
    }

    /// The full pass now scores one runtime at a time and gives the main run
    /// loop a turn in between, because scoring all six back to back held the
    /// main actor for 0.5–0.9 s while the user typed. Splitting it must not
    /// change a single verdict, including the launch block's fallback
    /// suggestion, which is computed from every candidate.
    @Test(
        "Scoring runtimes one at a time reaches the same verdicts",
        arguments: [RuntimeReadinessState.ready, .blocked]
    )
    func incrementalPassMatchesBackToBackPass(selectedReadiness: RuntimeReadinessState) async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let request = request(for: environment.task, selectedReadiness: selectedReadiness)

        let backToBack = try #require(await request.evaluate())
        var yields = 0
        let incremental = try #require(await request.evaluate(betweenRuntimes: {
            yields += 1
            return await RuntimeEligibilityPreviewRequest.yieldToMainRunLoop()
        }))

        #expect(yields == AgentRuntimeAdapterRegistry.runtimeIDs.count - 1)
        #expect(Set(incremental.candidates.keys) == Set(backToBack.candidates.keys))
        for (runtime, candidate) in backToBack.candidates {
            #expect(incremental.candidates[runtime]?.isEligible == candidate.isEligible, "\(runtime) verdict changed")
            #expect(incremental.candidates[runtime]?.contractDigest == candidate.contractDigest, "\(runtime) contract changed")
        }
        #expect(incremental.launchBlock == backToBack.launchBlock)
    }

    /// A keystroke supersedes the preview. The pass must stop at the next
    /// runtime boundary instead of scoring the rest for text nobody will send.
    @Test("A superseded incremental pass stops at the next runtime")
    func supersededIncrementalPassStops() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let request = request(for: environment.task)

        var yields = 0
        let snapshot = await request.evaluate(betweenRuntimes: {
            yields += 1
            return yields < 2
        })

        #expect(snapshot == nil)
        #expect(yields == 2, "the pass kept scoring after it was told to stop")
    }

    @Test("Yielding to the run loop reports a cancelled preview")
    func yieldReportsCancellation() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await RuntimeEligibilityPreviewRequest.yieldToMainRunLoop()
        }
        #expect(await task.value == false)
        #expect(await RuntimeEligibilityPreviewRequest.yieldToMainRunLoop())
    }

    /// A yield lets other main-actor work run, including an edit to state the
    /// pass reads. Verdicts scored before the edit must not be mixed with
    /// ones scored after it, so the pass starts again and agrees with a
    /// fresh evaluation of the edited state.
    @Test("An edit during a yield restarts the pass against the new state")
    func editDuringYieldRestartsPass() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let workspace = try #require(environment.task.workspace)
        let request = request(for: environment.task)

        var yields = 0
        let snapshot = try #require(await request.evaluate(betweenRuntimes: {
            yields += 1
            if yields == 1 {
                workspace.enabledCapabilityIDs.append(PluginCatalog.builtInPackages[0].id)
            }
            return true
        }))
        let fresh = try #require(await request.evaluate())

        #expect(yields > AgentRuntimeAdapterRegistry.runtimeIDs.count - 1, "the edit did not restart the pass")
        #expect(snapshot.candidates.count == fresh.candidates.count)
        for (runtime, candidate) in fresh.candidates {
            #expect(snapshot.candidates[runtime]?.contractDigest == candidate.contractDigest, "\(runtime) scored against stale state")
        }
        #expect(snapshot.launchBlock == fresh.launchBlock)
    }

    @Test("State that keeps changing still yields a complete verdict, in one stretch")
    func continuousEditsFallBackToOneStretch() async throws {
        let environment = try makeEnvironment()
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }
        let workspace = try #require(environment.task.workspace)
        let request = request(for: environment.task)

        var yields = 0
        let snapshot = try #require(await request.evaluate(betweenRuntimes: {
            yields += 1
            workspace.enabledCapabilityIDs.append("astra-edit-\(yields)")
            return true
        }))

        // Each attempt is cut short at its first yield; after three, the rest
        // is scored without yielding.
        #expect(yields == 3)
        #expect(snapshot.candidates.count == AgentRuntimeAdapterRegistry.runtimeIDs.count)
    }
}
