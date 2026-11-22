import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

/// Protected job metadata is bound to the existing execution journal. It is
/// only a registration/observation store and can never authorize replacement.
@MainActor
enum RemoteWorkspaceJobRegistration {
    static func directory(taskID: UUID, executionID: UUID, context: ModelContext) -> URL {
        directory(taskID: taskID, executionID: executionID, ownersRoot: RuntimeExecutionOwner.store(in: context).root)
    }

    /// The same directory from the journal's root, for a caller that reads
    /// the journal off the main actor.
    nonisolated static func directory(taskID: UUID, executionID: UUID, ownersRoot: URL) -> URL {
        ownersRoot.deletingLastPathComponent()
            .appendingPathComponent("remote-jobs").appendingPathComponent(taskID.uuidString)
            .appendingPathComponent(executionID.uuidString)
    }

    static func prepare(task: AgentTask, runID: UUID, owner: RuntimeExecutionOwner,
                        context: ModelContext, connections: [RemoteWorkspaceJobConnection]) throws -> RemoteWorkspaceJobConfiguration {
        let receipt = owner.record
        guard receipt.taskID == task.id, receipt.taskOwnerID == (task.launchSourceTaskOwnerID ?? task.persistentModelID),
              let receiptURL = owner.receiptURL, receipt.runID == runID, owner.isActive,
              receipt.cancellationRequested != true, receipt.limits.secondsRemaining > 0,
              receipt.limits.turnsRemaining > 0, receipt.limits.tokensRemaining > 0 else {
            throw RemoteWorkspaceJobError.invalidArgument("No active execution owner is available for remote jobs.")
        }
        let root = directory(taskID: task.id, executionID: receipt.executionID, context: context)
        let binding = RemoteWorkspaceJobOwnerBinding(
            receiptPath: receiptURL.path,
            taskID: task.id.uuidString, runID: runID.uuidString,
            ownerID: receipt.ownerID.uuidString, executionID: receipt.executionID.uuidString)
        var configuration = RemoteWorkspaceJobConfiguration(recordRootPath: root.appendingPathComponent("jobs").path,
            sshExecutable: "/usr/bin/ssh", connections: connections, taskID: task.id.uuidString,
            runID: runID.uuidString, ownerBinding: binding,
            maximumJobSeconds: max(1, Int(min(receipt.limits.secondsRemaining,
                Double(RemoteWorkspaceJobManager.maximumTimeoutSeconds)))))
        configuration.observationSSHOptions = observationOptions(task: task)
        configuration.launchMonotonicDeadline = ProcessInfo.processInfo.systemUptime + Double(configuration.maximumJobSeconds ?? 0)
        configuration.launchDeadline = Date().addingTimeInterval(Double(configuration.maximumJobSeconds ?? 0))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(configuration)
        try RemoteWorkspaceJobProtectedFile.write(data, to: root.appendingPathComponent("configuration.json"))
        return configuration
    }

    static func load(task: AgentTask, context: ModelContext) throws -> RemoteWorkspaceJobConfiguration? {
        guard let owner = try RuntimeExecutionOwner.existing(task: task, context: context) else { return nil }
        return try load(task: task, owner: owner, context: context) {
            task.workspace.map { SSHConnectionManager.loadForExport(workspacePath: $0.primaryPath) } ?? []
        }
    }

    static func loadAll(task: AgentTask, context: ModelContext) throws -> [RemoteWorkspaceJobConfiguration] {
        guard let owner = try RuntimeExecutionOwner.existing(task: task, context: context) else { return [] }
        return try loadAll(task: task, owner: owner, context: context)
    }

    static func loadAll(task: AgentTask, owner: RuntimeExecutionOwnerRecord, context: ModelContext) throws -> [RemoteWorkspaceJobConfiguration] {
        let executions = [owner] + (try RuntimeExecutionOwner.store(in: context).retainedExecutions(of: owner))
        // Every execution's registration is checked against the same saved
        // connections, so the workspace's file is read once for all of them
        // and only if one has a registration to check.
        var connections: [SSHConnection]?
        return try executions.compactMap {
            try load(task: task, owner: $0, context: context) {
                if let connections { return connections }
                let current = task.workspace.map { SSHConnectionManager.loadForExport(workspacePath: $0.primaryPath) } ?? []
                connections = current
                return current
            }
        }
    }

    private static func load(task: AgentTask, owner: RuntimeExecutionOwnerRecord, context: ModelContext,
                             savedConnections: () -> [SSHConnection]) throws -> RemoteWorkspaceJobConfiguration? {
        let root = directory(taskID: task.id, executionID: owner.executionID, context: context)
        let url = root.appendingPathComponent("configuration.json")
        // An execution with no registration has no directory. A missing
        // configuration inside an existing directory can hide live job records.
        do {
            let directory = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directory.isDirectory == true, directory.isSymbolicLink != true else {
                throw RemoteWorkspaceJobError.invalidArgument("The remote job directory could not be verified.")
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 65_536 else {
            throw RemoteWorkspaceJobError.invalidArgument("The remote job registration could not be verified.")
        }
        let configuration = try JSONDecoder().decode(RemoteWorkspaceJobConfiguration.self, from: Data(contentsOf: url))
        guard configuration.taskID == task.id.uuidString, configuration.runID == owner.runID?.uuidString,
              configuration.ownerBinding?.ownerID == owner.ownerID.uuidString,
              configuration.ownerBinding?.executionID == owner.executionID.uuidString,
              configuration.recordRootPath == root.appendingPathComponent("jobs").path,
              configuration.sshExecutable == "/usr/bin/ssh",
              configuration.observationSSHOptions == observationOptions(task: task) else {
            throw RemoteWorkspaceJobError.invalidArgument("Remote jobs belong to a different execution. The reservation is preserved.")
        }
        guard matchesSavedConnections(configuration.connections, task: task, current: savedConnections) else {
            throw RemoteWorkspaceJobError.invalidArgument("The SSH connection changed. Restore the original connection to inspect its jobs safely.")
        }
        return configuration
    }
    /// Older registrations always quoted shell words, including plain aliases.
    /// Compare the destination argv and stable identity before accepting either
    /// rendering; never rewrite the saved registration or migrate SSH settings.
    private static func matchesSavedConnections(
        _ saved: [RemoteWorkspaceJobConnection], task: AgentTask, current: () -> [SSHConnection]
    ) -> Bool {
        guard task.workspace != nil else { return saved.isEmpty }
        let current = current()
        var seen = Set<String>()
        return saved.allSatisfy { item in
            let matches = current.filter { $0.id.uuidString == item.id }
            guard seen.insert(item.id).inserted, matches.count == 1, let connection = matches.first,
                  item.name == connection.displayLabel,
                  item.arguments == connection.sshDestinationArguments(expandingTilde: true) else { return false }
            let legacy = connection.sshDestinationArguments(expandingTilde: false).map {
                "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
            return item.target == RemoteWorkspaceSSHRoute.connectTarget(for: connection) || item.target == legacy
        }
    }

    static func observationOptions(task: AgentTask) -> [String] {
        let path = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder)
            .appendingPathComponent(".runtime-ssh/known_hosts").path
        return observationOptions(knownHostsPath: path)
    }

    static func observationOptions(knownHostsPath path: String) -> [String] {
        ["-o", SSHKnownHostsOption.value(path: path), "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no", "-o", "StrictHostKeyChecking=yes"]
    }

}
