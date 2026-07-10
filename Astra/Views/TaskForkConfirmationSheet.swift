import SwiftUI
import ASTRAModels

struct TaskForkConfirmationPresentation: Equatable {
    let isGitBacked: Bool
    let repositorySummary: String?
    let repositoryDetail: String?
    let isDirty: Bool
    let eligibleFileCount: Int

    init(policy: TaskForkPolicy) {
        isGitBacked = policy.isGitBacked
        isDirty = policy.repository?.isDirty == true
        eligibleFileCount = policy.eligibleFileCount
        if let repository = policy.repository {
            let name = URL(fileURLWithPath: repository.rootPath).lastPathComponent
            repositorySummary = "\(name) · \(repository.branch) · \(repository.headSHA)"
            repositoryDetail = repository.rootPath
        } else {
            repositorySummary = nil
            repositoryDetail = nil
        }
    }

    func canConfirm(mode: TaskForkMode, acknowledgedDirtyState: Bool) -> Bool {
        if isGitBacked, mode != .conversationSharedFiles { return false }
        return !isDirty || acknowledgedDirtyState
    }
}

struct TaskForkConfirmationSheet: View {
    let taskTitle: String
    let checkpointStep: Int
    let policy: TaskForkPolicy
    let onConfirm: (TaskForkMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: TaskForkMode
    @State private var acknowledgedDirtyState = false
    @State private var showsRepositoryDetails = false

    init(
        taskTitle: String,
        checkpointStep: Int,
        policy: TaskForkPolicy,
        onConfirm: @escaping (TaskForkMode) -> Void
    ) {
        self.taskTitle = taskTitle
        self.checkpointStep = checkpointStep
        self.policy = policy
        self.onConfirm = onConfirm
        _selectedMode = State(initialValue: .conversationSharedFiles)
    }

    private var presentation: TaskForkConfirmationPresentation {
        TaskForkConfirmationPresentation(policy: policy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            if presentation.isGitBacked {
                gitRepositorySection
            } else {
                nonGitModeSection
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 520, height: presentation.isGitBacked ? 390 : 410)
        .background(Stanford.panelBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fork Conversation", systemImage: "arrow.branch")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.black)
            Text("Create a new conversation from step \(checkpointStep) of \"\(taskTitle)\".")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
    }

    private var gitRepositorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repository files remain shared")
                .font(Stanford.ui(14, weight: .semibold))
            if let summary = presentation.repositorySummary {
                Label(summary, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.black)
            }
            Text("ASTRA will copy the conversation checkpoint only. It will not create, switch, commit, push, or publish a Git branch.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(showsRepositoryDetails ? "Hide repository details" : "Repository details") {
                showsRepositoryDetails.toggle()
            }
            .buttonStyle(.plain)
            .font(Stanford.caption(11))
            .foregroundStyle(Stanford.lagunita)

            if showsRepositoryDetails, let detail = presentation.repositoryDetail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if presentation.isDirty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Uncommitted changes are present", systemImage: "exclamationmark.triangle.fill")
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(Stanford.poppy)
                    Toggle("I understand that both conversations will see the same working files.", isOn: $acknowledgedDirtyState)
                        .toggleStyle(.checkbox)
                        .font(Stanford.caption(11))
                }
            }
        }
    }

    private var nonGitModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File behavior")
                .font(Stanford.ui(14, weight: .semibold))
            modeRow(
                .conversationSharedFiles,
                title: "Continue with shared files",
                detail: "Both conversations reference the same documents. Changes made by either conversation are visible to both.",
                systemImage: "link"
            )
            modeRow(
                .conversationWithFileCopies,
                title: "Create independent file copies",
                detail: policy.allowsIndependentCopies
                    ? "Copies explicit files, attachments, and checkpoint artifacts. Folders remain shared and are never copied automatically."
                    : "Available only from the latest step because files changed by later steps cannot be reconstructed safely.",
                systemImage: "doc.on.doc"
            )
            .disabled(!policy.allowsIndependentCopies)
            if presentation.eligibleFileCount > 0 {
                Text("\(presentation.eligibleFileCount) explicit file\(presentation.eligibleFileCount == 1 ? "" : "s") currently eligible for copying.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modeRow(
        _ mode: TaskForkMode,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Button {
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedMode == mode ? Stanford.lagunita : Stanford.coolGrey)
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(Stanford.coolGrey)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Stanford.ui(13, weight: .semibold))
                        .foregroundStyle(Stanford.black)
                    Text(detail)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Fork Conversation") {
                onConfirm(selectedMode)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!presentation.canConfirm(
                mode: selectedMode,
                acknowledgedDirtyState: acknowledgedDirtyState
            ))
        }
    }
}
