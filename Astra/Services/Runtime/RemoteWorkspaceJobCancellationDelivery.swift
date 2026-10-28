import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

/// A cancellation delivery receipt outlives the SwiftData task. This is an
/// outbox for an already authorized stop, never another execution owner.
@MainActor
enum RemoteWorkspaceJobCancellationDelivery {
    private struct Receipt: Codable {
        var configuration: RemoteWorkspaceJobConfiguration
        var cancelExecution: Bool
    }

    static func persist(configuration: RemoteWorkspaceJobConfiguration, task: AgentTask, cancelExecution: Bool) throws -> RemoteWorkspaceJobConfiguration {
        let root = URL(fileURLWithPath: configuration.recordRootPath).deletingLastPathComponent()
        let knownHosts = root.appendingPathComponent("cancel-known_hosts")
        let source = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder).appendingPathComponent(".runtime-ssh/known_hosts")
        var delivery = configuration
        delivery.observationSSHOptions = RemoteWorkspaceJobRegistration.observationOptions(knownHostsPath: knownHosts.path)
        let receipt = root.appendingPathComponent("cancellation.json")
        if FileManager.default.fileExists(atPath: receipt.path) {
            var saved = try JSONDecoder().decode(Receipt.self, from: RemoteWorkspaceJobProtectedFile.read(receipt))
            guard saved.configuration == delivery else { throw RemoteWorkspaceJobError.invalidArgument("The original cancellation configuration changed.") }
            if cancelExecution && !saved.cancelExecution {
                saved.cancelExecution = true
                try RemoteWorkspaceJobProtectedFile.write(JSONEncoder().encode(saved), to: receipt)
            }
            return saved.configuration
        }
        // Pin the original trust file before task/workspace deletion can
        // remove it. Never invoke the task's mutable executable wrapper.
        try RemoteWorkspaceJobProtectedFile.write(RemoteWorkspaceJobProtectedFile.read(source), to: knownHosts)
        try RemoteWorkspaceJobProtectedFile.write(JSONEncoder().encode(Receipt(configuration: delivery, cancelExecution: cancelExecution)), to: receipt)
        return delivery
    }

    static func pending(context: ModelContext) throws -> [RemoteWorkspaceJobConfiguration] {
        var result: [RemoteWorkspaceJobConfiguration] = []
        let authority = RuntimeExecutionOwner.store(in: context)
        let executions = try authority.records().flatMap { [$0] + (try authority.retainedExecutions(of: $0)) }
        for owner in executions {
            let root = RemoteWorkspaceJobRegistration.directory(taskID: owner.taskID, executionID: owner.executionID, context: context)
            let url = root.appendingPathComponent("cancellation.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let receipt = try JSONDecoder().decode(Receipt.self,
                from: RemoteWorkspaceJobProtectedFile.read(url, maximumBytes: 65_536))
            let configuration = receipt.configuration
            guard configuration.taskID == owner.taskID.uuidString, configuration.runID == owner.runID?.uuidString,
                  configuration.ownerBinding?.ownerID == owner.ownerID.uuidString,
                  configuration.ownerBinding?.executionID == owner.executionID.uuidString,
                  configuration.recordRootPath == root.appendingPathComponent("jobs").path,
                  configuration.sshExecutable == "/usr/bin/ssh",
                  configuration.observationSSHOptions == RemoteWorkspaceJobRegistration.observationOptions(knownHostsPath: root.appendingPathComponent("cancel-known_hosts").path) else {
                throw RemoteWorkspaceJobError.invalidArgument("The saved remote cancellation identity could not be verified.")
            }
            let jobs = try RemoteWorkspaceJobStore(rootPath: configuration.recordRootPath).records()
            // Keep whole-execution intent even with an empty journal: a
            // registration already in flight can become visible after delete.
            if receipt.cancelExecution || jobs.contains(where: { $0.cancellationRequestedAt != nil && (!$0.status.isTerminal || $0.lastObservation?.outcome != .reachable) }) {
                result.append(configuration)
            }
        }
        return result
    }

    nonisolated static func preparePendingCancellation(_ configuration: RemoteWorkspaceJobConfiguration) throws -> [RemoteWorkspaceJobRecord] {
        let receiptURL = URL(fileURLWithPath: configuration.recordRootPath).deletingLastPathComponent().appendingPathComponent("cancellation.json")
        let receipt = try JSONDecoder().decode(Receipt.self, from: RemoteWorkspaceJobProtectedFile.read(receiptURL))
        guard receipt.configuration == configuration else { throw RemoteWorkspaceJobError.invalidArgument("Cancellation configuration changed.") }
        let store = RemoteWorkspaceJobStore(rootPath: configuration.recordRootPath)
        for job in try store.records() where receipt.cancelExecution && !job.status.isTerminal && job.cancellationRequestedAt == nil {
            try store.update(jobID: job.jobID) { $0.cancellationRequestedAt = Date() }
        }
        return try store.records().filter { $0.cancellationRequestedAt != nil }
    }

    nonisolated static func deliver(_ configuration: RemoteWorkspaceJobConfiguration) async {
        let failure = await BlockingWork.run(qos: .utility) { () -> String? in
            let manager = RemoteWorkspaceJobManager(configuration: configuration)
            do {
                for job in try preparePendingCancellation(configuration) {
                    _ = manager.status(jobID: job.jobID) // cancel marker + probe, never start
                }
                return nil
            } catch { return error.localizedDescription }
        }
        if let failure {
            AppLogger.audit(.workerBlocked, category: "RemoteJobs", taskID: configuration.taskID.flatMap(UUID.init(uuidString:)),
                fields: ["reason": "cancellation_delivery_failed", "error": failure], level: .warning)
        }
    }
}
