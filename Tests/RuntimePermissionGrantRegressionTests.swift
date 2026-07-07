import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeRuntimePermissionGrantContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Runtime Permission Grant Regressions")
@MainActor
struct RuntimePermissionGrantRegressionTests {
    @Test("Task-scoped grant replay merges legacy events with typed storage")
    func taskScopedGrantReplayMergesLegacyEventsWithTypedStorage() throws {
        let container = try makeRuntimePermissionGrantContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Merged Grant Storage", primaryPath: "/tmp/merged-grant-workspace")
        let task = AgentTask(title: "Merged Grant Storage", goal: "Review open PRs", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let legacyGrant = PermissionGrant.shellCommand(executable: "gh", pattern: "pr view *")
        let typedGrant = PermissionGrant.shellCommand(executable: "gh", pattern: "pr checks *")
        let legacyPayload = TaskRuntimePermissionGrants.Payload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            grants: [legacyGrant],
            approvedAt: Date(timeIntervalSince1970: 1),
            source: "legacy-test"
        )
        let legacyEncoded = try #require(String(data: JSONEncoder().encode(legacyPayload), encoding: .utf8))
        context.insert(TaskEvent(task: task, type: TaskRuntimePermissionGrants.eventType, payload: legacyEncoded))
        try context.save()

        _ = TaskRuntimePermissionGrants.record(
            grants: [typedGrant],
            providerID: .claudeCode,
            task: task,
            modelContext: context,
            source: "typed-test"
        )
        try context.save()

        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .claudeCode) == [
            typedGrant,
            legacyGrant
        ].sorted { $0.displayName < $1.displayName })
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .openCodeCLI).isEmpty)
    }
}
