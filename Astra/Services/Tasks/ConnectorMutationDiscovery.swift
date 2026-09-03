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
    ///
    /// Counted against proposals actually recorded, not files examined — see
    /// `maximumFilesExaminedPerScan` for why the distinction is load-bearing.
    static let maximumProposalsPerScan = 25

    /// Ceiling on files *opened* in one scan.
    ///
    /// Two ceilings because one cannot do both jobs. A file that fails to read
    /// is never recorded, so it never enters `recordedStagedPaths`, so it is
    /// never filtered out — it comes back on every scan, forever. When the cap
    /// above was counted against candidates rather than successes, twenty-five
    /// malformed or out-of-folder files sorting ahead of a valid proposal meant
    /// every scan selected the same twenty-five, recorded nothing, and stopped
    /// short of the real one. The proposal was staged, the agent was told it
    /// was staged, and the user was never offered it — on this run and on every
    /// run after it.
    ///
    /// Reading past the failures is what breaks that. This is what keeps
    /// reading past them bounded, and it is set well above the recording cap
    /// precisely because the permanently-unreadable files are re-examined each
    /// time: the budget has to cover them *and* leave room to reach what is
    /// behind them.
    static let maximumFilesExaminedPerScan = 200

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

        // Recorded files are excluded *before* the cap, not after. The staging
        // directory is append-only — declining leaves the file so the user can
        // still read it — so a task that accumulates more than the cap would
        // otherwise re-examine the same first 25 names on every scan, skip them
        // all as already recorded, and never reach the 26th. That is a proposal
        // the agent staged and the user is never offered.
        //
        // Filtering by name is what makes that affordable: the reader resolves
        // symlinks, so the comparison is made against the resolved directory to
        // stay in the same spelling the recorded paths are in.
        let alreadyRecorded = ConnectorMutationRequirementResolver.recordedStagedPaths(task: task)
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let candidates = names
            .filter { $0.hasSuffix(".json") }
            .map { (key: stagedOrderKey($0), name: $0) }
            .sorted { $0.key < $1.key }
            .map(\.name)
            .filter { !alreadyRecorded.contains(resolvedDirectory.appendingPathComponent($0).path) }

        var recorded: [TaskStagedConnectorMutation] = []
        var unreadable: [String] = []
        var examined = 0
        var deferred = 0
        for name in candidates {
            // The stop is checked here rather than by truncating `candidates`
            // so that a file which fails to read costs an examination and not a
            // recording slot. Everything past the stop is counted as deferred
            // and reported below, so nothing is dropped silently.
            guard recorded.count < maximumProposalsPerScan,
                  examined < maximumFilesExaminedPerScan else {
                deferred += 1
                continue
            }
            examined += 1
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
            // Backstop for the name filter above: the reader is the authority on
            // what a staged path resolves to, so a spelling it normalises
            // differently must still not record the same file twice.
            guard !alreadyRecorded.contains(staged.path) else { continue }
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
        if deferred > 0 {
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: "This task has \(candidates.count) connector mutations awaiting a first review; "
                    + "ASTRA is offering \(recorded.count) of them now and will pick up the remaining "
                    + "\(deferred) on the next run.",
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

    /// Orders staged names the way the broker wrote them.
    ///
    /// `ConnectorMutationStaging.stage` names a file
    /// `<service>-<operation>-<runID>-<n>.json`, where `n` is a per-run counter
    /// with no padding. Sorting those as plain text reads the counter as text,
    /// which puts `10` ahead of `2` — and proposals inside one run are commonly
    /// dependent, so the user is asked to approve the story before the epic it
    /// references. The cap above makes the same mistake worse: it takes the
    /// first `maximumProposalsPerScan` of a mis-ordered list, so the tenth
    /// proposal can be offered while the second is held back to the next run.
    ///
    /// Everything before the counter is still compared as text, so proposals
    /// stay grouped by service, operation, and run, and only the counter is
    /// compared as a number. A name that does not end in one — a file the user
    /// dropped in, or a spelling a future broker uses — keeps its whole
    /// basename as the group, which puts it after every numbered name it shares
    /// a prefix with and leaves it ordered by name against everything else. It
    /// is never reordered arbitrarily and never dropped.
    static func stagedOrderKey(_ name: String) -> (String, Int, String) {
        let base = name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
        guard let separator = base.lastIndex(of: "-"),
              let sequence = Int(base[base.index(after: separator)...]) else {
            return (base, .max, name)
        }
        return (String(base[..<separator]), sequence, name)
    }
}
