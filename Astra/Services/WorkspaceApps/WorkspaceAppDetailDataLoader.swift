import Foundation

struct WorkspaceAppDependencyBindingSnapshot: Equatable {
    var requirementID: String
    var contract: String
    var operations: [String]
    var optional: Bool
    var status: WorkspaceAppDependencyBindingStatus
    var implementationID: String?
    var provider: String?
    var transport: WorkspaceAppContractTransport?
}

struct WorkspaceAppAutomationStateSnapshot: Equatable {
    var automationID: String
    var automationType: String
    var actionID: String?
    var isEnabled: Bool
    var status: WorkspaceAppAutomationStateStatus
    var lastRunAt: Date?
    var nextRunAt: Date?
}

struct WorkspaceAppRunSnapshot: Equatable {
    var id: UUID
    var actionID: String
    var trigger: WorkspaceAppRunTrigger
    var status: WorkspaceAppRunStatus
    var startedAt: Date
    var completedAt: Date?
    var outputSummary: String
    var errorMessage: String?
    var linkedTaskID: UUID?
    var linkedArtifactPath: String?
}

struct WorkspaceAppStorageTableSnapshot: Equatable {
    var name: String
    var columns: [String]
    var rows: [[String: WorkspaceAppStorageValue]]
    var errorMessage: String?

    var rowCount: Int {
        rows.count
    }
}

struct WorkspaceAppDetailDataSnapshot: Equatable {
    var manifest: WorkspaceAppManifest?
    var storageTables: [WorkspaceAppStorageTableSnapshot]
    var dependencyBindings: [WorkspaceAppDependencyBindingSnapshot]
    var automationStates: [WorkspaceAppAutomationStateSnapshot]
    var runs: [WorkspaceAppRunSnapshot]
    var errorMessage: String?

    static let empty = WorkspaceAppDetailDataSnapshot(
        manifest: nil,
        storageTables: [],
        dependencyBindings: [],
        automationStates: [],
        runs: [],
        errorMessage: nil
    )
}

struct WorkspaceAppDetailDataLoader {
    var fileManager: FileManager = .default
    var storageService = WorkspaceAppStorageService()

    func load(
        app: WorkspaceApp,
        workspace: Workspace?,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        automationStates: [WorkspaceAppAutomationState] = [],
        runs: [WorkspaceAppRun] = []
    ) -> WorkspaceAppDetailDataSnapshot {
        guard let workspace, !workspace.primaryPath.isEmpty else {
            return WorkspaceAppDetailDataSnapshot(
                manifest: nil,
                storageTables: [],
                dependencyBindings: bindingSnapshots(dependencyBindings, appID: app.id),
                automationStates: automationSnapshots(automationStates, appID: app.id),
                runs: runSnapshots(runs, appID: app.id),
                errorMessage: "Workspace path is unavailable."
            )
        }

        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
            let tables = (manifest.storage?.tables ?? []).map { table in
                tableSnapshot(table, databaseURL: databaseURL)
            }
            return WorkspaceAppDetailDataSnapshot(
                manifest: manifest,
                storageTables: tables,
                dependencyBindings: bindingSnapshots(dependencyBindings, appID: app.id),
                automationStates: automationSnapshots(automationStates, appID: app.id),
                runs: runSnapshots(runs, appID: app.id),
                errorMessage: nil
            )
        } catch {
            return WorkspaceAppDetailDataSnapshot(
                manifest: nil,
                storageTables: [],
                dependencyBindings: bindingSnapshots(dependencyBindings, appID: app.id),
                automationStates: automationSnapshots(automationStates, appID: app.id),
                runs: runSnapshots(runs, appID: app.id),
                errorMessage: "Could not load app manifest."
            )
        }
    }

    private func bindingSnapshots(
        _ bindings: [WorkspaceAppDependencyBinding],
        appID: UUID
    ) -> [WorkspaceAppDependencyBindingSnapshot] {
        bindings
            .filter { $0.appID == appID }
            .sorted { $0.requirementID < $1.requirementID }
            .map { binding in
                WorkspaceAppDependencyBindingSnapshot(
                    requirementID: binding.requirementID,
                    contract: binding.contract,
                    operations: binding.operations,
                    optional: binding.optional,
                    status: binding.status,
                    implementationID: binding.implementationID,
                    provider: binding.provider,
                    transport: binding.transport
                )
            }
    }

    private func automationSnapshots(
        _ automations: [WorkspaceAppAutomationState],
        appID: UUID
    ) -> [WorkspaceAppAutomationStateSnapshot] {
        automations
            .filter { $0.appID == appID }
            .sorted { $0.automationID < $1.automationID }
            .map { automation in
                WorkspaceAppAutomationStateSnapshot(
                    automationID: automation.automationID,
                    automationType: automation.automationType,
                    actionID: automation.actionID,
                    isEnabled: automation.isEnabled,
                    status: automation.status,
                    lastRunAt: automation.lastRunAt,
                    nextRunAt: automation.nextRunAt
                )
            }
    }

    private func runSnapshots(
        _ runs: [WorkspaceAppRun],
        appID: UUID
    ) -> [WorkspaceAppRunSnapshot] {
        runs
            .filter { $0.appID == appID }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt > rhs.startedAt
                }
                return lhs.actionID < rhs.actionID
            }
            .prefix(8)
            .map { run in
                WorkspaceAppRunSnapshot(
                    id: run.id,
                    actionID: run.actionID,
                    trigger: run.trigger,
                    status: run.status,
                    startedAt: run.startedAt,
                    completedAt: run.completedAt,
                    outputSummary: run.outputSummary,
                    errorMessage: run.errorMessage,
                    linkedTaskID: run.linkedTaskID,
                    linkedArtifactPath: run.linkedArtifactPath
                )
            }
    }

    private func tableSnapshot(
        _ table: WorkspaceAppStorageTable,
        databaseURL: URL
    ) -> WorkspaceAppStorageTableSnapshot {
        do {
            let rows = fileManager.fileExists(atPath: databaseURL.path)
                ? try storageService.records(in: table.name, databaseURL: databaseURL)
                : []
            return WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: rows,
                errorMessage: nil
            )
        } catch {
            return WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: [],
                errorMessage: "Could not read table records."
            )
        }
    }
}
