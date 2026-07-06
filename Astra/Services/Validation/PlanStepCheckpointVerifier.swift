import Foundation
import SwiftData
import ASTRAModels

/// Evidence collected at a plan-step run boundary.
///
/// A step checkpoint is only as strong as what it checks: process exit alone
/// proves nothing, so the verifier resolves the step's declared outputs on
/// disk before ASTRA records the step as done. Steps that declare no
/// resolvable required outputs verify vacuously — the checkpoint tightens
/// exactly as much as the plan author specified, never more.
struct PlanStepCheckpointOutcome: Equatable {
    var verifiedPaths: [String] = []
    var missingRequiredPaths: [String] = []
    var unverifiableScopeCount: Int = 0

    var isVerified: Bool { missingRequiredPaths.isEmpty }

    /// Suffix for the step-completion summary so the event log records what
    /// the checkpoint actually proved.
    var completionEvidence: String {
        if !verifiedPaths.isEmpty {
            return " Verified outputs: \(verifiedPaths.joined(separator: ", "))."
        }
        if unverifiableScopeCount > 0 {
            return " Declared outputs are outside ASTRA's verifiable scopes."
        }
        return " No verifiable outputs declared for this step."
    }
}

enum PlanStepCheckpointVerifier {
    /// Stamped into checkpoint-imposed blocked summaries so a later run can
    /// distinguish ASTRA's own evidence blocks (liftable by evidence) from
    /// provider-reported blockers (which need an explicit completion marker).
    static let checkpointBlockSummaryPrefix = "Step checkpoint failed:"

    private struct Check {
        let path: String
        let kind: TaskPlanArtifactKind
        let roots: [String]
    }

    @MainActor
    static func verify(
        step: TaskPlanPayloadStep,
        plan: TaskPlanPayload,
        task: AgentTask,
        fileManager: FileManager = .default
    ) -> PlanStepCheckpointOutcome {
        let access = TaskWorkspaceAccess(task: task)
        return verify(
            step: step,
            plan: plan,
            taskFolder: access.taskFolder,
            // The provider executes in the pinned worktree (or resolved working
            // path), not necessarily the workspace primary path — verify where
            // the work actually happened.
            workspacePath: access.codeWorkingDirectory,
            fileManager: fileManager
        )
    }

    /// Verifies every non-skipped step of the plan; used at the full-plan run
    /// boundary where there are no intermediate checkpoints.
    @MainActor
    static func verifyAllSteps(
        plan: TaskPlanPayload,
        task: AgentTask,
        fileManager: FileManager = .default
    ) -> [(step: TaskPlanPayloadStep, missing: [String])] {
        plan.steps.compactMap { step in
            guard step.status != .skipped else { return nil }
            let outcome = verify(step: step, plan: plan, task: task, fileManager: fileManager)
            return outcome.missingRequiredPaths.isEmpty ? nil : (step, outcome.missingRequiredPaths)
        }
    }

    /// Records a checkpoint-imposed block for the step and returns the pause
    /// message for the user. The text travels in `reason` so the blocked step
    /// surfaces it as its detail in the plan UI.
    @MainActor
    static func recordCheckpointBlock(
        step: TaskPlanPayloadStep,
        missing: [String],
        plan: TaskPlanPayload,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) -> String {
        let missingList = missing.joined(separator: ", ")
        _ = TaskPlanService.recordStepProgress(
            type: TaskPlanEventTypes.stepBlocked,
            planID: plan.planID,
            stepID: step.id,
            status: .blocked,
            task: task,
            modelContext: modelContext,
            run: run,
            title: step.title,
            reason: "\(checkpointBlockSummaryPrefix) required outputs missing — \(missingList)"
        )
        return "Plan step \"\(step.title)\" finished without its required outputs (\(missingList)). Approve the step again to retry, or adjust the plan step."
    }

    /// Verifies all steps at the full-plan run boundary; records blocks for
    /// every unverified step and returns the pause message, or nil when the
    /// whole plan verified.
    @MainActor
    static func recordFullPlanCheckpointBlocks(
        plan: TaskPlanPayload,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) -> String? {
        let unverified = verifyAllSteps(plan: plan, task: task)
        guard !unverified.isEmpty else { return nil }
        for entry in unverified {
            _ = recordCheckpointBlock(
                step: entry.step,
                missing: entry.missing,
                plan: plan,
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
        let titles = unverified.map { "\"\($0.step.title)\"" }.joined(separator: ", ")
        return "Plan finished, but required outputs are missing for \(titles). Approve the plan again to retry those steps, or adjust the plan."
    }

    /// Whether the most recent blocked record for this step was stamped by the
    /// checkpoint itself (as opposed to a provider-reported blocker). Matches
    /// on the decoded payload's stepID — substring matching would confuse
    /// step IDs that prefix each other ("step-1" vs "step-10").
    @MainActor
    static func latestBlockIsCheckpointImposed(task: AgentTask, stepID: String) -> Bool {
        let latestBlock = task.events
            .filter { $0.type == TaskPlanEventTypes.stepBlocked }
            .compactMap { event -> (timestamp: Date, payload: TaskPlanProgressPayload)? in
                guard let data = event.payload.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(TaskPlanProgressPayload.self, from: data),
                      payload.stepID == stepID else { return nil }
                return (event.timestamp, payload)
            }
            .max { $0.timestamp < $1.timestamp }
        guard let payload = latestBlock?.payload else { return false }
        return payload.reason?.hasPrefix(checkpointBlockSummaryPrefix) == true
            || payload.summary?.hasPrefix(checkpointBlockSummaryPrefix) == true
    }

    static func verify(
        step: TaskPlanPayloadStep,
        plan: TaskPlanPayload,
        taskFolder: String,
        workspacePath: String,
        fileManager: FileManager = .default
    ) -> PlanStepCheckpointOutcome {
        var outcome = PlanStepCheckpointOutcome()

        // Gate only on authoritative declarations: the step's own outputs and
        // step-scoped contract artifacts. Keyword-inferred legacy expectations
        // are guesses (a blocked reason mentioning a path becomes step detail
        // and would gate on text), and plan-scoped contract artifacts belong
        // to the final validation pass, not intermediate steps.
        var checks: [Check] = step.outputs.compactMap { output in
            guard output.required,
                  let path = output.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            let roots: [String]
            switch output.scope {
            case .taskOutput: roots = [taskFolder]
            case .workspace: roots = [workspacePath]
            case .remote, .chat: roots = []
            }
            return Check(path: path, kind: output.kind, roots: roots)
        }
        if let contract = plan.validationContract {
            checks += contract.assertions.compactMap { assertion in
                guard assertion.scope == .step,
                      assertion.stepID == step.id,
                      assertion.required,
                      assertion.method == .artifact,
                      let path = assertion.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else { return nil }
                // The final validation pass accepts artifacts in the task
                // folder or the working tree; mirror that here so a step can't
                // block on a path the end-of-plan check would accept.
                let kind: TaskPlanArtifactKind = artifactTypeLooksDirectory(assertion.expectedArtifactType)
                    ? .directory
                    : .file
                return Check(path: path, kind: kind, roots: [taskFolder, workspacePath])
            }
        }

        // The same path can be declared as a step output and a contract
        // artifact; verifying it twice would double it in the evidence list.
        var seenPaths = Set<String>()
        checks = checks.filter { seenPaths.insert($0.path).inserted }

        for check in checks {
            switch check.kind {
            case .file, .directory, .evidence:
                break
            case .url, .text:
                // Never on disk; mirror TaskExecutionArtifactPreparer, which
                // also treats these kinds as non-preparable.
                outcome.unverifiableScopeCount += 1
                continue
            }
            guard !check.roots.isEmpty else {
                outcome.unverifiableScopeCount += 1
                continue
            }
            let resolved = check.roots.compactMap { containedPath(check.path, under: $0) }
            guard !resolved.isEmpty else {
                // Unresolvable or escaping paths can't be honestly verified;
                // treat them as out of scope rather than failing the step on
                // a malformed plan entry.
                outcome.unverifiableScopeCount += 1
                continue
            }
            if resolved.contains(where: { evidenceExists(at: $0, kind: check.kind, roots: check.roots, fileManager: fileManager) }) {
                outcome.verifiedPaths.append(check.path)
            } else {
                outcome.missingRequiredPaths.append(check.path)
            }
        }
        return outcome
    }

    private static func evidenceExists(
        at path: String,
        kind: TaskPlanArtifactKind,
        roots: [String],
        fileManager: FileManager
    ) -> Bool {
        guard let root = containingRoot(for: path, roots: roots) else { return false }
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: URL(fileURLWithPath: root, isDirectory: true))
        let url = URL(fileURLWithPath: path, isDirectory: kind == .directory)
        var isDirectory: ObjCBool = false
        guard hostFileAccess.fileExists(at: url, isDirectory: &isDirectory, intent: accessIntent) else { return false }
        guard kind == .directory else {
            // A directory at a path declared as a file is not the declared
            // output (the preflight may have mkdir'd it).
            return !isDirectory.boolValue
        }
        // Required directories are pre-created empty by the artifact preflight,
        // so bare existence proves nothing — content does.
        guard isDirectory.boolValue else { return false }
        return ((try? hostFileAccess.contentsOfDirectory(at: url, intent: accessIntent)) ?? []).isEmpty == false
    }

    private static func containingRoot(for path: String, roots: [String]) -> String? {
        let resolvedPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return roots
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path }
            .first { root in
                resolvedPath == root || resolvedPath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
    }

    /// Mirrors TaskExecutionArtifactPreparer's directory detection for
    /// contract artifact assertions (the original helper is private there).
    private static func artifactTypeLooksDirectory(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["directory", "folder", "dir"].contains(normalized)
    }

    /// Resolves `relativePath` under `root` and rejects traversal outside it.
    private static func containedPath(_ relativePath: String, under root: String) -> String? {
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "\\", with: "/")
        guard !trimmedRoot.isEmpty,
              !trimmedPath.isEmpty,
              !trimmedPath.hasPrefix("/"),
              !trimmedPath.hasPrefix("~"),
              !trimmedPath.contains("://") else { return nil }

        let rootURL = URL(fileURLWithPath: trimmedRoot, isDirectory: true).standardizedFileURL
        let candidate = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate.path
    }
}
