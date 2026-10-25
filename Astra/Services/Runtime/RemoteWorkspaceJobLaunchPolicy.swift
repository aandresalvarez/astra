import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

@MainActor
enum RemoteWorkspaceJobLaunchPolicy {
    private static var brokers: [UUID: RemoteWorkspaceJobBroker] = [:]
    private static var preparations: [UUID: (RuntimeExecutionOwner) throws -> Void] = [:]

    static func finish(taskID: UUID) {
        preparations.removeValue(forKey: taskID)
        brokers.removeValue(forKey: taskID)
    }

    /// The final execution ID is assigned immediately before Process.run().
    /// Capture only preparation here; never bind a job to an earlier attempt.
    static func prepare(task: AgentTask, runID: UUID, owner: RuntimeExecutionOwner, context: ModelContext,
                        route: RemoteWorkspaceSSHRoute?, resourcePlan: inout TaskLaunchResourcePlan) -> RemoteWorkspaceSSHRoute? {
        finish(taskID: task.id)
        guard let route else { return nil }
        let connections = RemoteWorkspaceJobShim.offeredConnections(task: task, targets: route.targets)
        let helperPath = RemoteWorkspaceJobShim.helperPath
        let offered = route.route == .nativeShell && !connections.isEmpty
            && FileManager.default.isExecutableFile(atPath: helperPath)
        if offered {
            let receiptPath = RuntimeExecutionOwner.store(in: context).root.appendingPathComponent(task.id.uuidString + ".json").path
            resourcePlan.hostPathGrants += readableGrants(helperPath: helperPath, receiptPath: receiptPath)
            preparations[task.id] = { currentOwner in
                let configuration = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: runID,
                    owner: currentOwner, context: context, connections: connections)
                let broker = try RemoteWorkspaceJobBroker(configuration: configuration, helperPath: helperPath)
                let prepared = RemoteWorkspaceJobShim.prepare(task: task, runID: runID, route: route,
                    configuration: configuration, brokerDirectory: broker.directory, brokerToken: broker.token, helperPath: helperPath)
                guard prepared?.remoteJobs == true else {
                    throw RemoteWorkspaceJobError.invalidArgument("The remote job helper could not be prepared safely.")
                }
                brokers[task.id] = broker
            }
        } else {
            _ = RemoteWorkspaceJobShim.prepare(task: task, runID: runID, route: route)
        }
        let prepared = route.offeringRemoteJobs(offered)
        resourcePlan.remoteSSHRoute = prepared
        TaskLaunchResourceManifestStore.persist(resourcePlan, task: task)
        return prepared
    }

    static func activate(owner: RuntimeExecutionOwner) throws {
        try preparations[owner.record.taskID]?(owner)
    }

    static func readableGrants(helperPath: String, receiptPath: String) -> [RuntimePathGrant] {
        [helperPath, receiptPath].map { path in
            .init(path: path, access: .read, source: .controlPlane,
                reason: "Read the admitted SSH helper and its existing execution receipt.",
                sensitivity: .normal, lifetime: .run, exists: FileManager.default.fileExists(atPath: path))
        }
    }
}
