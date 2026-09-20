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

    private func request(for task: AgentTask) -> RuntimeEligibilityPreviewRequest {
        let readiness = Dictionary(
            uniqueKeysWithValues: AgentRuntimeAdapterRegistry.runtimeIDs.map { ($0, RuntimeReadinessState.ready) }
        )
        return .existingTask(
            task: task,
            acceptedTurn: "Summarize what you found",
            selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            skipPermissions: false,
            providerSettings: .headlessScenario,
            readinessStates: readiness,
            eventRevision: 0
        )
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
}
