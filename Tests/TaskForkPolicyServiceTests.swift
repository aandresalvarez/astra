import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Conversation fork policy")
@MainActor
struct TaskForkPolicyServiceTests {
    @Test("Git repository only permits conversation-only forks")
    func gitRepositoryOnlyPermitsConversationForks() {
        let workspace = Workspace(name: "Repo", primaryPath: "/tmp/project")
        let task = AgentTask(title: "Task", goal: "Work", workspace: workspace)
        let policy = TaskForkPolicyService.resolve(for: task) { _, arguments in
            switch arguments {
            case ["rev-parse", "--show-toplevel"]:
                return .init(output: "/tmp/project\n", exitCode: 0)
            case ["rev-parse", "--abbrev-ref", "HEAD"]:
                return .init(output: "feature/report\n", exitCode: 0)
            case ["rev-parse", "--short=8", "HEAD"]:
                return .init(output: "abcdef12\n", exitCode: 0)
            case ["--no-optional-locks", "status", "--porcelain=v1"]:
                return .init(output: " M report.md\n", exitCode: 0)
            default:
                return .init(output: "", exitCode: 1)
            }
        }

        #expect(policy.allowedModes == [.conversationSharedFiles])
        #expect(policy.repository?.branch == "feature/report")
        #expect(policy.repository?.headSHA == "abcdef12")
        #expect(policy.repository?.isDirty == true)
    }

    @Test("dirty Git repository requires explicit acknowledgement")
    func dirtyGitRepositoryRequiresAcknowledgement() {
        let policy = TaskForkPolicy(
            repository: TaskForkRepositorySnapshot(
                rootPath: "/tmp/project",
                branch: "main",
                headSHA: "abcdef12",
                isDirty: true
            ),
            eligibleFileCount: 2
        )
        let presentation = TaskForkConfirmationPresentation(policy: policy)

        #expect(presentation.repositorySummary == "project · main · abcdef12")
        #expect(!presentation.canConfirm(mode: .conversationSharedFiles, acknowledgedDirtyState: false))
        #expect(presentation.canConfirm(mode: .conversationSharedFiles, acknowledgedDirtyState: true))
        #expect(!presentation.canConfirm(mode: .conversationWithFileCopies, acknowledgedDirtyState: true))
    }

    @Test("non-Git workspace offers shared and independent file modes")
    func nonGitWorkspaceOffersBothModes() {
        let workspace = Workspace(name: "Documents", primaryPath: "/tmp/documents")
        let task = AgentTask(title: "Task", goal: "Write", workspace: workspace)
        let policy = TaskForkPolicyService.resolve(for: task) { _, _ in
            .init(output: "", exitCode: 128)
        }

        #expect(policy.repository == nil)
        #expect(policy.allowedModes == [.conversationSharedFiles, .conversationWithFileCopies])
    }

    @Test("workspace-less task offers shared files only")
    func workspaceLessTaskOffersSharedFilesOnly() {
        let task = AgentTask(title: "Standalone", goal: "Discuss an idea")
        let policy = TaskForkPolicyService.resolve(for: task) { _, _ in
            .init(output: "", exitCode: 128)
        }

        #expect(policy.repository == nil)
        #expect(!policy.allowsIndependentCopies)
        #expect(policy.allowedModes == [.conversationSharedFiles])
        #expect(policy.independentCopiesUnavailableDetail?.contains("no workspace folder") == true)
    }

    @Test("historical checkpoint offers shared files only")
    func historicalCheckpointOffersSharedFilesOnly() {
        let workspace = Workspace(name: "Documents", primaryPath: "/tmp/documents")
        let task = AgentTask(title: "Task", goal: "Write", workspace: workspace)
        let checkpoint = TaskRun(task: task)
        checkpoint.startedAt = Date(timeIntervalSince1970: 100)
        let latest = TaskRun(task: task)
        latest.startedAt = Date(timeIntervalSince1970: 200)

        let policy = TaskForkPolicyService.resolve(for: task, upToRunID: checkpoint.id) { _, _ in
            .init(output: "", exitCode: 128)
        }

        #expect(!policy.allowsIndependentCopies)
        #expect(policy.allowedModes == [.conversationSharedFiles])
    }
}
