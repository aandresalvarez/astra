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

    static func postIfAuto(
        task: AgentTask,
        run: TaskRun,
        policyLevel: AgentPolicyLevel,
        modelContext: ModelContext,
        service: GitHubReviewPublicationService
    ) async {
        guard !ExternalActionPolicy.asksUser(for: .githubReviewPublication, level: policyLevel),
              GitHubReviewPublicationRequirement.isPending(task: task) else {
            return
        }
        // Only a review this run wrote is this run's to post. A file an earlier
        // run left — one composed under Ask and still waiting in the dock — is
        // that run's question, and switching the task to Auto must not answer
        // it. `allFileChanges` carries what the run touched in the task folder,
        // shell writes included.
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let produced = producedPaths(of: run, taskFolder: taskFolder)
        let candidates = candidateReviewFiles(taskFolder: taskFolder)
            .filter { produced.contains(resolved($0)) }
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
            // An unconfirmed or already-dispatched post has its own error line;
            // repeating it would read as a second attempt.
            if let error = error as? GitHubReviewPublicationError {
                switch error {
                case .uncertain, .alreadyDispatched, .receiptPersistenceFailed:
                    return
                case .invalid, .unusableArtifact, .staleHead:
                    break
                }
            }
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: "Auto could not post the GitHub review: \(error.localizedDescription) "
                    + "It is waiting for your review.",
                run: run
            ))
        }
    }

    static func producedPaths(of run: TaskRun, taskFolder: String) -> Set<String> {
        Set(run.allFileChanges.compactMap { change -> String? in
            guard change.kind != .removed else { return nil }
            let path = change.path.hasPrefix("/")
                ? change.path
                : (taskFolder as NSString).appendingPathComponent(change.path)
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
        var examined = 0
        while let url = enumerator.nextObject() as? URL, examined < maximumEntriesExamined {
            examined += 1
            guard GitHubReviewArtifactPolicy.isReviewFile(url.path),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            found.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        return found
            .sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
            .map(\.path)
    }
}
