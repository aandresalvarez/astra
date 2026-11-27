import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A launch reads the requested runtime's verdict and nothing else unless that
/// verdict blocks it, so it must not score the other runtimes for an eligible
/// one: in production that was five extra capability and resource resolutions
/// on the main actor, about a second of every send.
@Suite("Launch runtime admission scoring")
@MainActor
struct LaunchRuntimeAdmissionScoringTests {
    private static let allRuntimes: [AgentRuntimeID] = [.claudeCode, .codexCLI, .cursorCLI, .openCodeCLI, .antigravityCLI]

    private func makeTask() throws -> (container: ModelContainer, task: AgentTask) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Launch scoring", primaryPath: "/tmp/astra-launch-scoring")
        let task = AgentTask(title: "Summarize", goal: "Summarize the notes", workspace: workspace, runtime: .claudeCode)
        context.insert(workspace)
        context.insert(task)
        try context.save()
        return (container, task)
    }

    private func evaluate(
        _ task: AgentTask,
        requestedRuntime: AgentRuntimeID,
        usable: Set<AgentRuntimeID>,
        scoring: TaskLaunchAdmissionService.CandidateScoring
    ) -> TaskRuntimeEligibilitySnapshot {
        let intent = TaskTurnIntentSnapshot(taskID: task.id, sourceEventID: nil, acceptedTurn: task.goal)
        let paths = Dictionary(uniqueKeysWithValues: Self.allRuntimes.map { ($0, "/usr/bin/true") })
        return TaskLaunchAdmissionService.evaluate(
            task: task,
            intent: intent,
            requestedRuntime: requestedRuntime,
            runtimeConfiguration: AgentRuntimeConfiguration(
                providerSettings: AgentRuntimeProviderSettings(executablePaths: paths),
                defaultRuntimeID: .claudeCode
            ),
            executionPolicy: .default.withTurnIntentSnapshot(intent),
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: Self.allRuntimes,
            isRuntimeUsable: { runtime, _ in usable.contains(runtime) },
            isHostControlBrokerAvailable: { true },
            scoring: scoring
        )
    }

    @Test("An eligible requested runtime is the only one a launch scores, with the same verdict")
    func eligibleRequestedRuntimeScoresAlone() throws {
        let fixture = try makeTask()
        let everyRuntime = evaluate(fixture.task, requestedRuntime: .codexCLI, usable: Set(Self.allRuntimes), scoring: .everyRuntime)
        let launch = evaluate(fixture.task, requestedRuntime: .codexCLI, usable: Set(Self.allRuntimes),
                              scoring: .othersOnlyWhenRequestedIsBlocked)

        #expect(everyRuntime.candidates.count == Self.allRuntimes.count)
        #expect(Array(launch.candidates.keys) == [.codexCLI])
        #expect(launch.launchBlock == nil && everyRuntime.launchBlock == nil)
        #expect(launch.selectedRuntime == everyRuntime.selectedRuntime)
        #expect(launch.selectedCandidate.contractDigest == everyRuntime.selectedCandidate.contractDigest)
        #expect(launch.selectedCandidate.requirements == everyRuntime.selectedCandidate.requirements)
        #expect(
            LaunchResourceContract(plan: launch.selectedCandidate.launchResourcePlan).resources
                == LaunchResourceContract(plan: everyRuntime.selectedCandidate.launchResourcePlan).resources
        )
    }

    @Test("A blocked requested runtime still scores the rest and suggests the same switch")
    func blockedRequestedRuntimeScoresEveryRuntime() throws {
        let fixture = try makeTask()
        let usable: Set<AgentRuntimeID> = [.antigravityCLI]
        let everyRuntime = evaluate(fixture.task, requestedRuntime: .cursorCLI, usable: usable, scoring: .everyRuntime)
        let launch = evaluate(fixture.task, requestedRuntime: .cursorCLI, usable: usable,
                              scoring: .othersOnlyWhenRequestedIsBlocked)

        #expect(Set(launch.candidates.keys) == Set(Self.allRuntimes))
        let block = try #require(launch.launchBlock)
        #expect(block.suggestedRuntime == .antigravityCLI)
        #expect(block == everyRuntime.launchBlock)
    }

    @Test("The launch resolver scores only an eligible requested runtime")
    func launchResolverScoresOnlyAnEligibleRequestedRuntime() throws {
        let fixture = try makeTask()
        let paths = Dictionary(uniqueKeysWithValues: Self.allRuntimes.map { ($0, "/usr/bin/true") })
        let configuration = AgentRuntimeConfiguration(
            providerSettings: AgentRuntimeProviderSettings(executablePaths: paths),
            defaultRuntimeID: .claudeCode
        )
        // The default is what the worker's launch gets.
        let launch = AgentRuntimeLaunchRuntimeResolver.resolve(
            task: fixture.task, requestedRuntime: .codexCLI, runtimeConfiguration: configuration,
            promptOverride: nil, startEventPayload: nil, sessionMessage: nil, phase: .run,
            executionPolicy: .default, isHostControlBrokerAvailable: { true })
        let everyRuntime = AgentRuntimeLaunchRuntimeResolver.resolve(
            task: fixture.task, requestedRuntime: .codexCLI, runtimeConfiguration: configuration,
            promptOverride: nil, startEventPayload: nil, sessionMessage: nil, phase: .run,
            executionPolicy: .default, isHostControlBrokerAvailable: { true }, scoring: .everyRuntime)
        #expect(launch.launchBlock == nil)
        #expect(Array(launch.incompatibilities.keys) == [.codexCLI])
        #expect(everyRuntime.incompatibilities.count > 1)
        #expect(launch.runtime == everyRuntime.runtime && launch.requirements == everyRuntime.requirements)
        #expect(launch.contractDigest == everyRuntime.contractDigest)
    }
}
