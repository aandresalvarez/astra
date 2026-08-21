import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

/// Turns files the broker staged into durable task events the app can act on.
///
/// This is the app's half of the seam. The broker cannot call ASTRA — it is a
/// separate process speaking MCP, and the observation ASTRA receives for a tool
/// call carries argument *keys* only, never values, so nothing in the stream
/// names the file or its digest. What ASTRA can do is read the task folder it
/// projected, and it does so exactly once per run, at the run boundary.
///
/// Once, and at the boundary, for two reasons. A scan on every dock rebuild
/// would run filesystem work inside a SwiftUI view body. And a scan that kept
/// re-reading the directory would resurrect proposals the user declined, since
/// declining does not delete a file they may still want to read.
enum ConnectorMutationDiscovery {
    /// Ceiling on proposals recorded from one scan. A staging directory is
    /// agent-writable, so its size is agent-controlled; without a cap, one
    /// runaway loop turns into an unbounded read and an unreviewable dock.
    static let maximumProposalsPerScan = 25

    @MainActor
    @discardableResult
    static func recordStagedMutations(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        fileManager: FileManager = .default
    ) -> [TaskStagedConnectorMutation] {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return [] }
        let directory = ConnectorMutationStaging.stagingDirectory(taskFolder: taskFolder)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            // A missing directory is the overwhelmingly common case: most runs
            // stage nothing. It is not worth an event.
            return []
        }

        let candidates = names.filter { $0.hasSuffix(".json") }.sorted()
        let alreadyRecorded = Set(
            ConnectorMutationRequirementResolver.recordedDigests(task: task)
        )

        var recorded: [TaskStagedConnectorMutation] = []
        var unreadable: [String] = []
        for name in candidates.prefix(maximumProposalsPerScan) {
            let path = directory.appendingPathComponent(name).path
            let staged: ConnectorMutationStaging.StagedConnectorMutation
            do {
                // Containment is enforced by the shared reader rather than
                // re-checked here, so the app and the broker cannot disagree
                // about what counts as inside the task folder.
                staged = try ConnectorMutationStaging.read(atPath: path, containedIn: taskFolder)
            } catch {
                unreadable.append(name)
                continue
            }
            guard !alreadyRecorded.contains(staged.digest) else { continue }
            let pending = TaskStagedConnectorMutation(
                runID: run.id,
                serviceType: staged.serviceType,
                operation: staged.operation,
                connectorID: staged.connectorID,
                connectorAlias: staged.connectorAlias,
                target: staged.target,
                summary: staged.summary,
                stagedPayloadPath: staged.path,
                requestDigest: staged.digest
            )
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: ConnectorMutationEventTypes.staged,
                payload: pending,
                run: run
            ))
            recorded.append(pending)
        }

        // Both of these are silences worth breaking. An agent that staged a
        // proposal and hears nothing will conclude the write failed and reach
        // for a script — which is the failure this whole seam exists to remove.
        if candidates.count > maximumProposalsPerScan {
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "This run staged \(candidates.count) connector mutations; "
                    + "ASTRA is only offering the first \(maximumProposalsPerScan) for review.",
                run: run
            ))
        }
        if !unreadable.isEmpty {
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "ASTRA could not read \(unreadable.count) staged connector "
                    + "mutation(s) and will not offer them for review: "
                    + unreadable.sorted().joined(separator: ", "),
                run: run
            ))
        }
        return recorded
    }
}
