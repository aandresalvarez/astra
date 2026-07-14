import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Task policy precedence")
@MainActor
struct TaskPolicyPrecedenceTests {
    @Test("Task Ask selection overrides the legacy global Auto fallback")
    func taskAskOverridesLegacyGlobalAutoFallback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Publish a draft pull request")
        context.insert(task)
        TaskPolicyStore.recordSelection(level: .review, task: task, modelContext: context, source: "task_composer")
        try context.save()

        let taskResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .autonomous,
            executionPolicy: .default
        )

        #expect(taskResolution.level == .review)
        #expect(taskResolution.scope == .taskOverride)
        #expect(taskResolution.policy.level == .review)

        let escalatedResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .autonomous,
            executionPolicy: AgentRuntimeExecutionPolicy(permissionPolicyOverride: .autonomous)
        )

        #expect(escalatedResolution.level == .autonomous)
        #expect(escalatedResolution.scope == .oneRunEscalation)
    }

    @Test("Worker launch honors task Ask over the legacy skip-permissions flag")
    func workerLaunchHonorsTaskAskOverLegacySkipPermissions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Publish a draft pull request")
        context.insert(task)
        TaskPolicyStore.recordSelection(level: .review, task: task, modelContext: context, source: "task_composer")
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue

        let launchPolicy = worker.effectivePermissionPolicy(
            for: task,
            selectedRuntime: .codexCLI,
            executionPolicy: .default
        )

        #expect(launchPolicy == .restricted)
    }

    @Test("Legacy global Auto fallback remains effective without a narrower selection")
    func legacyGlobalAutoFallbackRemainsEffective() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Run autonomously")
        context.insert(task)

        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .autonomous,
            executionPolicy: .default
        )

        #expect(resolution.level == .autonomous)
        #expect(resolution.scope == .globalDefault)
        #expect(resolution.policy.level == .autonomous)

        let worker = AgentRuntimeWorker()
        worker.skipPermissions = true
        worker.permissionPolicy = .restricted
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue

        let launchPolicy = worker.effectivePermissionPolicy(
            for: task,
            selectedRuntime: .claudeCode,
            executionPolicy: .default
        )

        #expect(launchPolicy == .autonomous)
    }

    @Test("Restricted one-run authority caps legacy global Auto")
    func restrictedOneRunOverrideCapsGlobalAuto() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Inspect repository state")
        context.insert(task)

        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .autonomous,
            fallbackPermissionPolicy: .autonomous,
            executionPolicy: .approvedRuntimePermission(
                runtime: .codexCLI,
                allowedTools: ["Bash(git status --short *)"]
            )
        )

        #expect(resolution.level == .review)
        #expect(resolution.scope == .oneRunEscalation)
        #expect(resolution.policy.level == .review)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
