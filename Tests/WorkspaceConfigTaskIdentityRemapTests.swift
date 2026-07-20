import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// `remappingTaskIdentities` backs the duplicate-workspace path: a duplicate
/// task retaining the original's UUID would resolve the ORIGINAL's external
/// operations through every globally-taskID-keyed surface (operation controls,
/// backend locator, startup trusted-record reconciliation) and could observe
/// or cancel the original's live job.
@Suite("Workspace config task identity remap")
struct WorkspaceConfigTaskIdentityRemapTests {
    private func makeTask(
        id: String,
        chainedFromID: String? = nil,
        forkedFromID: String? = nil,
        runIDs: [String] = []
    ) -> WorkspaceConfigManager.TaskConfig {
        let now = Date(timeIntervalSince1970: 1_777_002_000)
        return WorkspaceConfigManager.TaskConfig(
            id: id,
            title: "Task \(id.prefix(8))",
            goal: "Remap fixture",
            status: TaskStatus.completed.rawValue,
            inputs: [],
            constraints: [],
            acceptanceCriteria: [],
            tokenBudget: 10_000,
            tokensUsed: 0,
            model: "default",
            costUSD: 0,
            maxTurns: 10,
            createdAt: now,
            updatedAt: now,
            chainedFromID: chainedFromID,
            forkedFromID: forkedFromID,
            runs: runIDs.map { runID in
                WorkspaceConfigManager.RunConfig(
                    id: runID,
                    status: "completed",
                    startedAt: now,
                    completedAt: now,
                    tokensUsed: 0,
                    output: "",
                    costUSD: 0,
                    stopReason: "",
                    fileChangesJSON: ""
                )
            },
            events: [],
            skillNames: []
        )
    }

    @Test("task and run ids are regenerated and cross-references follow the remap")
    func remapRegeneratesIdsAndRewritesReferences() throws {
        let originalTaskID = UUID().uuidString
        let chainedTaskID = UUID().uuidString
        let externalTaskID = UUID().uuidString
        let originalRunID = UUID().uuidString
        var config = WorkspaceConfigManager.WorkspaceConfig(
            id: UUID().uuidString,
            name: "Remap",
            primaryPath: "/tmp/astra_remap_\(UUID().uuidString)",
            additionalPaths: [],
            icon: "folder.fill",
            instructions: "",
            skills: [],
            sshConnections: [],
            exportedAt: Date(timeIntervalSince1970: 1_777_002_000)
        )
        config.tasks = [
            makeTask(id: originalTaskID, runIDs: [originalRunID]),
            // References a task defined EARLIER in the array, and one defined
            // outside this config entirely.
            makeTask(
                id: chainedTaskID,
                chainedFromID: originalTaskID,
                forkedFromID: externalTaskID
            )
        ]
        config.schedules = [
            WorkspaceConfigManager.ScheduleConfig(
                id: UUID().uuidString,
                name: "Routine",
                isEnabled: false,
                goal: "Remap fixture",
                templateVariablesJSON: "{}",
                model: "default",
                tokenBudget: 10_000,
                scheduleType: "interval",
                nextFireDate: Date(timeIntervalSince1970: 1_777_003_000),
                intervalSeconds: 3_600,
                dailyHour: 0,
                dailyMinute: 0,
                weeklyDayOfWeek: 1,
                fireCount: 0,
                sourceTaskID: originalTaskID
            )
        ]

        let remapped = WorkspaceConfigManager.remappingTaskIdentities(in: config)
        let tasks = try #require(remapped.tasks)
        #expect(tasks.count == 2)

        // Every task id is fresh.
        let newIDs = tasks.compactMap(\.id)
        #expect(!newIDs.contains(originalTaskID))
        #expect(!newIDs.contains(chainedTaskID))
        #expect(Set(newIDs).count == 2)

        // Run ids are fresh too.
        let newRunID = try #require(tasks[0].runs.first?.id)
        #expect(newRunID != originalRunID)

        // In-config cross-references follow the remap; a reference to a task
        // outside this config is left alone (it dangles either way).
        #expect(tasks[1].chainedFromID == tasks[0].id)
        #expect(tasks[1].forkedFromID == externalTaskID)
        #expect(remapped.schedules?.first?.sourceTaskID == tasks[0].id)
    }
}
