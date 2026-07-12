import Foundation
import SwiftUI
import ASTRAModels

struct PendingTaskForkRequest: Identifiable {
    var id: UUID { run.id }
    let run: TaskRunSnapshot
    let policy: TaskForkPolicy
    let checkpointStep: Int
}

extension TaskMainView {
    var forkContextBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                cachedForkModeLabel ?? "Forked conversation from step \(task.forkedAtRunIndex + 1)",
                systemImage: "arrow.branch"
            )
            .font(Stanford.caption(12))
            if let repositorySummary = cachedForkRepositorySummary {
                Text(repositorySummary).foregroundStyle(Stanford.coolGrey)
            }
            // Only the cheap running-sibling scan runs per body evaluation
            // (reading sibling `status` here also keeps the banner reactive
            // to runs finishing); the manifest disk read behind the git-fork
            // gate is cached alongside the other fork banner fields.
            if let sharedWorktreeRoot = cachedForkSharedWorktreeRoot,
               let readOnlyReason = TaskForkPolicyService.readOnlyReason(
                for: task,
                sharedWorktreeRoot: sharedWorktreeRoot
               ) {
                Text(readOnlyReason).foregroundStyle(Stanford.poppy)
            }
            if let warning = cachedForkSourceAvailabilityWarning {
                Text(warning).foregroundStyle(Stanford.coolGrey)
            }
        }
        .font(Stanford.caption(11))
        .foregroundStyle(Stanford.plum)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Stanford.plum.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func refreshForkSourceAvailabilityWarning() {
        cachedForkSourceAvailabilityWarning = TaskForkManifestService.sourceAvailabilityWarning(for: task)
        let manifest = TaskForkManifestService.load(for: task)
        cachedForkModeLabel = manifest.map { manifest in
            if manifest.repository != nil { return "Conversation fork · Shared repository files" }
            return manifest.resolvedForkMode == .conversationWithFileCopies
                ? "Conversation fork · Independent file copies"
                : "Conversation fork · Shared workspace files"
        }
        cachedForkRepositorySummary = manifest?.repository.map { repository in
            let name = URL(fileURLWithPath: repository.rootPath).lastPathComponent
            return "\(name) · \(repository.branch) · \(repository.headSHA)"
        }
        cachedForkSharedWorktreeRoot = TaskForkPolicyService.sharedWorktreeReadOnlyRoot(
            for: task,
            manifest: manifest
        )
    }

    func presentForkConfirmation(from run: TaskRunSnapshot) {
        Task { @MainActor in
            let policy = await TaskForkPolicyService.resolveDetachingGitWork(for: task, upToRunID: run.id)
            let sortedRuns = task.runs.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            pendingForkRequest = PendingTaskForkRequest(
                run: run,
                policy: policy,
                checkpointStep: (sortedRuns.firstIndex { $0.id == run.id } ?? 0) + 1
            )
        }
    }

    func createFork(from run: TaskRunSnapshot, mode: TaskForkMode, policy: TaskForkPolicy) {
        guard let sourceRun = task.runs.first(where: { $0.id == run.id }) else {
            forkCreationError = AgentTaskForkError.targetRunMissing.localizedDescription
            return
        }
        do {
            let forked = try TaskForkCreationCoordinator.create(
                source: task,
                targetRun: sourceRun,
                mode: mode,
                policy: policy,
                modelContext: modelContext
            )
            onForkTask?(forked)
        } catch {
            forkCreationError = error.localizedDescription
        }
    }
}
