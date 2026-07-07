import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeWorkspacePersistenceReviewContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Workspace Persistence Review Regressions")
struct WorkspacePersistenceReviewRegressionTests {
    @Test("linked worktree generated state is excluded through common git info exclude")
    func linkedWorktreeGeneratedStateIsExcludedThroughCommonGitInfoExclude() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra_linked_worktree_exclude_\(UUID().uuidString)", isDirectory: true)
        let commonGit = parent.appendingPathComponent("repo.git", isDirectory: true)
        let worktree = parent.appendingPathComponent("feature", isDirectory: true)
        let worktreeAdmin = commonGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: commonGit, withIntermediateDirectories: true)
        try writeLinkedWorktree(activeDirectory: worktree, adminDirectory: worktreeAdmin, commonGitDirectory: commonGit)
        defer { try? FileManager.default.removeItem(at: parent) }

        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: worktree.path)
        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: worktree.path)

        let commonExclude = commonGit
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
        let commonContents = try String(contentsOf: commonExclude, encoding: .utf8)
        #expect(commonContents.components(separatedBy: "/.astra/").count == 2)
        #expect(!FileManager.default.fileExists(
            atPath: worktreeAdmin
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude")
                .path
        ))
    }

    @Test("workspace mirror export preserves approval resume events for waiting app runs")
    @MainActor
    func workspaceMirrorExportPreservesApprovalResumeEventsForWaitingAppRuns() throws {
        let container = try makeWorkspacePersistenceReviewContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Approval App Mirror", primaryPath: "/tmp/astra_approval_app_mirror_\(UUID().uuidString)")
        context.insert(workspace)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "approval-dashboard",
            name: "Approval Dashboard",
            icon: "checkmark.circle",
            appDescription: "Tracks approval status",
            lifecycleStatus: .published,
            permissionMode: .approvalRequired,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/approval-dashboard/manifest.json",
            appDirectoryRelativePath: ".astra/apps/approval-dashboard",
            manifestDigest: "digest-current"
        )
        context.insert(app)

        let waitingRun = WorkspaceAppRun(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: "approve",
            trigger: .user,
            status: .waiting,
            startedAt: Date(timeIntervalSince1970: 0),
            inputSummary: "Approve PR data",
            outputSummary: "Awaiting approval",
            errorMessage: nil
        )
        waitingRun.pendingApprovalActionID = "human-gate"
        waitingRun.pendingActionID = "pipeline"
        waitingRun.pendingStepIndex = 3
        context.insert(waitingRun)
        context.insert(WorkspaceAppRunEvent(
            runID: waitingRun.id,
            workspaceID: workspace.id,
            appID: app.id,
            actionID: waitingRun.actionID,
            type: "workspaceApp.run.awaitingApproval",
            payload: #"{"pipelineID":"pipeline","gateID":"human-gate","stepIndex":3,"boundRowsJSON":"[{\"title\":{\"text\":\"Row 1\"}}]"}"#,
            timestamp: Date(timeIntervalSince1970: 0)
        ))

        for index in 1...9 {
            let run = WorkspaceAppRun(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                actionID: "refresh-\(index)",
                trigger: .automation,
                status: .completed,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                inputSummary: "Refresh PR data",
                outputSummary: "Done",
                errorMessage: nil
            )
            context.insert(run)
            context.insert(WorkspaceAppRunEvent(
                runID: run.id,
                workspaceID: workspace.id,
                appID: app.id,
                actionID: run.actionID,
                type: "workspace_app.run.event.\(index)",
                payload: "{}",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let newestRun = try #require((try context.fetch(FetchDescriptor<WorkspaceAppRun>()))
            .first { $0.actionID == "refresh-9" })
        for offset in 1...2 {
            context.insert(WorkspaceAppRunEvent(
                runID: newestRun.id,
                workspaceID: workspace.id,
                appID: app.id,
                actionID: newestRun.actionID,
                type: "workspace_app.run.extra.\(offset)",
                payload: "{}",
                timestamp: Date(timeIntervalSince1970: TimeInterval(9 + offset))
            ))
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let mirroredEvents = try #require(config.workspaceAppRunEvents)

        #expect(mirroredEvents.count == WorkspaceConfigManager.MirrorLimits.maxWorkspaceAppRunEvents)
        #expect(mirroredEvents.contains {
            $0.runID == waitingRun.id.uuidString && $0.type == "workspaceApp.run.awaitingApproval"
        })
    }

    @Test("workspace app mirrors are replaced instead of duplicated on import")
    @MainActor
    func workspaceAppMirrorsAreReplacedInsteadOfDuplicatedOnImport() throws {
        let container = try makeWorkspacePersistenceReviewContainer()
        let context = container.mainContext
        let workspaceID = UUID()
        let staleAppID = UUID()
        let replacementAppID = UUID()
        let staleRunID = UUID()
        let replacementRunID = UUID()

        context.insert(WorkspaceApp(
            id: staleAppID,
            workspaceID: workspaceID,
            logicalID: "stale-dashboard",
            name: "Stale Dashboard",
            icon: "xmark.circle",
            appDescription: "Old app surface",
            lifecycleStatus: .published,
            permissionMode: .readOnly,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/stale/manifest.json",
            appDirectoryRelativePath: ".astra/apps/stale",
            manifestDigest: "stale-digest"
        ))
        context.insert(WorkspaceAppRun(
            id: staleRunID,
            workspaceID: workspaceID,
            appID: staleAppID,
            appLogicalID: "stale-dashboard",
            actionID: "refresh",
            trigger: .user,
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1),
            inputSummary: "stale",
            outputSummary: "stale",
            errorMessage: nil
        ))
        context.insert(WorkspaceAppRunEvent(
            runID: staleRunID,
            workspaceID: workspaceID,
            appID: staleAppID,
            actionID: "refresh",
            type: "workspaceApp.stale",
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 2)
        ))
        context.insert(WorkspaceAppDependencyBinding(
            workspaceID: workspaceID,
            appID: staleAppID,
            appLogicalID: "stale-dashboard",
            requirementID: "stale",
            contract: "stale.read",
            operations: ["read"],
            optional: false,
            status: .mapped
        ))
        context.insert(WorkspaceAppAutomationState(
            workspaceID: workspaceID,
            appID: staleAppID,
            appLogicalID: "stale-dashboard",
            automationID: "stale-auto",
            automationType: "schedule",
            actionID: "refresh",
            isEnabled: true,
            status: .enabled
        ))
        try context.save()

        let config = WorkspaceConfigManager.WorkspaceConfig(
            id: workspaceID.uuidString,
            name: "Replacement Workspace",
            primaryPath: "/tmp/replacement-workspace",
            additionalPaths: [],
            icon: "sparkles",
            instructions: "",
            lastUsedSkillNames: nil,
            enabledGlobalSkillIDs: nil,
            enabledGlobalConnectorIDs: nil,
            enabledGlobalToolIDs: nil,
            enabledCapabilityIDs: nil,
            enabledPackIDs: nil,
            shelfVisibilityOverrides: nil,
            memories: nil,
            createdAt: nil,
            updatedAt: nil,
            skills: [],
            connectors: nil,
            localTools: nil,
            templates: nil,
            schedules: nil,
            sshConnections: [],
            tasks: nil,
            workspaceApps: [
                WorkspaceConfigManager.WorkspaceAppConfig(
                    id: replacementAppID.uuidString,
                    workspaceID: workspaceID.uuidString,
                    logicalID: "replacement-dashboard",
                    name: "Replacement Dashboard",
                    icon: "checkmark.circle",
                    description: "Current app surface",
                    lifecycleStatus: "published",
                    permissionMode: "readOnly",
                    dependencyStatus: "ready",
                    manifestRelativePath: ".astra/apps/replacement/manifest.json",
                    appDirectoryRelativePath: ".astra/apps/replacement",
                    manifestDigest: "replacement-digest",
                    publishedManifestDigest: nil,
                    lastKnownGoodManifestDigest: nil,
                    latestVersionNumber: nil,
                    sourcePackageID: nil,
                    sourcePackageVersion: nil,
                    sourcePackageDigest: nil,
                    lastOpenedAt: nil,
                    lastRefreshedAt: nil,
                    lastRunAt: nil,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            workspaceAppRuns: [
                WorkspaceConfigManager.WorkspaceAppRunConfig(
                    id: replacementRunID.uuidString,
                    workspaceID: workspaceID.uuidString,
                    appID: replacementAppID.uuidString,
                    appLogicalID: "replacement-dashboard",
                    actionID: "refresh",
                    trigger: "user",
                    status: "completed",
                    startedAt: Date(timeIntervalSince1970: 3),
                    completedAt: nil,
                    inputSummary: "replacement",
                    outputSummary: "replacement",
                    errorMessage: nil,
                    linkedTaskID: nil,
                    linkedArtifactPath: nil,
                    pendingActionID: nil,
                    pendingStepIndex: nil,
                    consumedTokens: nil,
                    awaitedTaskIDsJSON: nil,
                    pendingApprovalActionID: nil
                )
            ],
            workspaceAppRunEvents: [
                WorkspaceConfigManager.WorkspaceAppRunEventConfig(
                    id: UUID().uuidString,
                    runID: replacementRunID.uuidString,
                    workspaceID: workspaceID.uuidString,
                    appID: replacementAppID.uuidString,
                    actionID: "refresh",
                    type: "workspaceApp.replacement",
                    payload: "{}",
                    timestamp: Date(timeIntervalSince1970: 4)
                )
            ],
            workspaceAppDependencyBindings: [
                WorkspaceConfigManager.WorkspaceAppDependencyBindingConfig(
                    id: UUID().uuidString,
                    workspaceID: workspaceID.uuidString,
                    appID: replacementAppID.uuidString,
                    appLogicalID: "replacement-dashboard",
                    requirementID: "replacement",
                    contract: "replacement.read",
                    operationsSummary: "read",
                    optional: false,
                    status: "mapped",
                    implementationID: nil,
                    provider: nil,
                    transport: nil,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            workspaceAppAutomationStates: [
                WorkspaceConfigManager.WorkspaceAppAutomationStateConfig(
                    id: UUID().uuidString,
                    workspaceID: workspaceID.uuidString,
                    appID: replacementAppID.uuidString,
                    appLogicalID: "replacement-dashboard",
                    automationID: "replacement-auto",
                    automationType: "schedule",
                    actionID: "refresh",
                    isEnabled: true,
                    status: "enabled",
                    lastRunAt: nil,
                    nextRunAt: nil,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            googleOAuthAccountProfiles: nil,
            installedPlugins: nil,
            exportedAt: Date()
        )

        _ = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: context)
        try context.save()

        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>()).filter { $0.workspaceID == workspaceID }
        let runs = try context.fetch(FetchDescriptor<WorkspaceAppRun>()).filter { $0.workspaceID == workspaceID }
        let events = try context.fetch(FetchDescriptor<WorkspaceAppRunEvent>()).filter { $0.workspaceID == workspaceID }
        let bindings = try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>()).filter { $0.workspaceID == workspaceID }
        let automationStates = try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>()).filter { $0.workspaceID == workspaceID }

        #expect(apps.map(\.id) == [replacementAppID])
        #expect(runs.map(\.id) == [replacementRunID])
        #expect(events.map(\.type) == ["workspaceApp.replacement"])
        #expect(bindings.map(\.requirementID) == ["replacement"])
        #expect(automationStates.map(\.automationID) == ["replacement-auto"])
    }

    private func writeLinkedWorktree(
        activeDirectory: URL,
        adminDirectory: URL,
        commonGitDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adminDirectory, withIntermediateDirectories: true)
        try "gitdir: \(adminDirectory.path)\n".write(
            to: activeDirectory.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let relativeCommon = relativePath(from: adminDirectory, to: commonGitDirectory)
        try "\(relativeCommon)\n".write(
            to: adminDirectory.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(activeDirectory.appendingPathComponent(".git").path)\n".write(
            to: adminDirectory.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func relativePath(from directory: URL, to target: URL) -> String {
        let sourceComponents = directory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        let sharedPrefixCount = zip(sourceComponents, targetComponents)
            .prefix { $0 == $1 }
            .count
        let upwardSegments = Array(repeating: "..", count: sourceComponents.count - sharedPrefixCount)
        let downwardSegments = targetComponents.dropFirst(sharedPrefixCount)
        let relativeComponents = upwardSegments + downwardSegments
        return relativeComponents.isEmpty ? "." : relativeComponents.joined(separator: "/")
    }
}
