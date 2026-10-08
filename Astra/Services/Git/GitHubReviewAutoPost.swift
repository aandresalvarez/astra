import Foundation
import SwiftData
import ASTRACore
import ASTRALogging
import ASTRAModels
import ASTRAPersistence

/// Posts, when an Auto run finishes, the pull-request review the user asked
/// ASTRA to post.
///
/// Auto asks nothing, so the "Review comments" sheet is skipped — not the
/// checks behind it. The review goes through `GitHubReviewPublicationService`
/// exactly as an approved one does: the file must sit in the task folder and
/// carry only fields the sheet would show, the target must be the open pull
/// request the request named, the head commit must still match, and dispatch is
/// recorded before the network call so an unconfirmed post is never resent. The
/// receipt says Auto posted it, and the chat shows it with its link.
@MainActor
enum GitHubReviewAutoPost {
    /// Bounds the folder walk. Review files sit at the top of the task folder;
    /// this only has to cover a task folder with a lot of other output.
    static let maximumEntriesExamined = 4_000

    /// Whether Auto will post a review this run wrote once validation passes,
    /// so the review gate must not hold the outcome back before that.
    static func postsAfterValidation(
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        executionPath: String? = nil
    ) -> Bool {
        !ExternalActionPolicy.asksUser(for: .githubReviewPublication, level: policyLevel)
            && GitHubReviewPublicationRequirement.isPending(task: task)
            && !runReviewFiles(task: task, run: run, executionPath: executionPath).isEmpty
    }

    /// Called from settlement once the outcome, tests, AI check, baseline
    /// check and plan review included, completed the run: the point Auto's
    /// connector writes wait for too. A review it does not post holds
    /// completion back, as the review gate would have.
    static func postAfterValidation(
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        executionPath: String? = nil,
        modelContext: ModelContext,
        service: GitHubReviewPublicationService
    ) async {
        await postIfAuto(task: task, run: run, policyLevel: policyLevel, executionPath: executionPath,
                         modelContext: modelContext, service: service)
        guard task.status == .completed, GitHubReviewPublicationRequirement.isPending(task: task) else { return }
        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(task: task, run: run)
        if decision.shouldBlockCompletion {
            TaskRuntimeOutcomeTransition.applyCompletionBlock(decision, task: task, run: run, modelContext: modelContext)
        }
    }

    /// What the chat says when Auto did not post, or nil when the failure
    /// already has its own line (an unconfirmed or already-dispatched post) or
    /// the user withdrew the request. A confirmed post whose receipt could not
    /// be saved has none — the publish path rolled its own back — so it says
    /// GitHub has it. A stale or unusable file is set aside rather than left in
    /// the dock, so it is not called "waiting for your review".
    static func notice(for error: Error) -> String? {
        let reason = error.localizedDescription
        guard let error = error as? GitHubReviewPublicationError else {
            return "Auto could not post the GitHub review: \(reason) It is waiting for your review."
        }
        switch error {
        case .uncertain, .alreadyDispatched, .requestWithdrawn:
            return nil
        case .receiptPersistenceFailed:
            return "Auto posted the GitHub review. \(reason)"
        case .staleHead, .unusableArtifact:
            return "Auto could not post the GitHub review: \(reason) This file is set aside; "
                + "a new review file is needed to post it."
        case .invalid:
            return "Auto could not post the GitHub review: \(reason) It is waiting for your review."
        }
    }

    /// Only a review this run wrote is this run's to post. A file an earlier
    /// run left — one composed under Ask and still waiting in the dock — is
    /// that run's question, and switching the task to Auto must not answer it.
    /// `allFileChanges` carries what the run touched in the task folder, shell
    /// writes included.
    private static func runReviewFiles(task: AgentTask, run: TaskRun, executionPath: String?) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        let produced = producedPaths(of: run, executionPath: executionPath ?? access.codeWorkingDirectory)
        return candidateReviewFiles(taskFolder: access.taskFolder).filter { produced.contains(resolved($0)) }
    }

    private static func postIfAuto(
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        executionPath: String?,
        modelContext: ModelContext,
        service: GitHubReviewPublicationService
    ) async {
        guard !ExternalActionPolicy.asksUser(for: .githubReviewPublication, level: policyLevel),
              GitHubReviewPublicationRequirement.isPending(task: task) else {
            return
        }
        let candidates = runReviewFiles(task: task, run: run, executionPath: executionPath)
        // No review file from this run means the agent has not written one, or
        // an earlier run did; the pending requirement already tells the user
        // what is missing and the dock still offers the earlier file.
        guard !candidates.isEmpty else { return }
        do {
            let proposal = try await service.prepareFirstAvailable(task: task, filePaths: candidates)
            _ = try await service.publish(task: task, proposal: proposal, authorization: .autoPolicy)
        } catch {
            AppLogger.audit(.connectorTested, category: "Git", taskID: task.id, fields: [
                "source": "github_review_auto_post",
                "candidate_count": String(candidates.count),
                "result": "not_posted"
            ], level: .warning)
            guard let notice = notice(for: error) else { return }
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: notice,
                run: run
            ))
        }
    }

    /// What the run touched, as absolute paths. A tool reports a path relative
    /// to the provider's working directory, the same reading
    /// `TaskFolderRunSnapshot` gives it, and that snapshot drops its own
    /// absolute record of a file the tool already reported, so resolving
    /// against anything else would miss a review this run wrote.
    static func producedPaths(of run: TaskRun, executionPath: String) -> Set<String> {
        Set(run.allFileChanges.compactMap { change -> String? in
            guard change.kind != .removed else { return nil }
            let path = change.path.hasPrefix("/") || executionPath.isEmpty
                ? change.path
                : (executionPath as NSString).appendingPathComponent(change.path)
            return resolved(path)
        })
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    /// Review files in the task folder, newest first, so the review the latest
    /// turn wrote is the one tried first.
    static func candidateReviewFiles(taskFolder: String, fileManager: FileManager = .default) -> [String] {
        guard !taskFolder.isEmpty,
              let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: taskFolder, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }
        var found: [(path: String, modified: Date)] = []
        func consider(_ url: URL) {
            guard GitHubReviewArtifactPolicy.isReviewFile(url.path),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return
            }
            found.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        // The top level first, where review files are written, so a large
        // subdirectory the walk reaches earlier cannot use up the bound.
        let topLevel = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: taskFolder, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        topLevel.forEach(consider)
        let topLevelPaths = Set(topLevel.map(\.standardizedFileURL.path))
        var examined = 0
        while let url = enumerator.nextObject() as? URL, examined < maximumEntriesExamined {
            examined += 1
            guard !topLevelPaths.contains(url.standardizedFileURL.path) else { continue }
            consider(url)
        }
        return found
            .sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
            .map(\.path)
    }
}
