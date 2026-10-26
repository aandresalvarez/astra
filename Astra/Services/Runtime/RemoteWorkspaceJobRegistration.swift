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
        RuntimeExecutionOwner.store(in: context).root.deletingLastPathComponent()
            .appendingPathComponent("remote-jobs").appendingPathComponent(taskID.uuidString)
            .appendingPathComponent(executionID.uuidString)
    }

    static func prepare(task: AgentTask, runID: UUID, owner: RuntimeExecutionOwner,
                        context: ModelContext, connections: [RemoteWorkspaceJobConnection]) throws -> RemoteWorkspaceJobConfiguration {
        let receipt = owner.record
        guard receipt.taskID == task.id, receipt.taskOwnerID == task.persistentModelID,
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
        let root = directory(taskID: task.id, executionID: owner.executionID, context: context)
        let url = root.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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
        let current = RemoteWorkspaceJobShim.offeredConnections(task: task, targets: configuration.connections.map(\.target))
        guard current == configuration.connections else {
            throw RemoteWorkspaceJobError.invalidArgument("The SSH connection changed. Restore the original connection to inspect its jobs safely.")
        }
        return configuration
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
