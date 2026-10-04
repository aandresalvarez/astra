import SwiftUI
import ASTRACore
import ASTRAModels

struct NewTaskWorktreeSelection {
    var isEnabled = false
    var repositoryPath: String?
    var repositories: [GitRepositoryInfo] = []
    var isLoading = false

    var selectedRepository: GitRepositoryInfo? {
        repositories.first { $0.path == repositoryPath }
    }

    var canSubmit: Bool {
        !isEnabled || (!isLoading && selectedRepository != nil)
    }

    mutating func updateRepositories(_ repositories: [GitRepositoryInfo], preferredPath: String?) {
        self.repositories = repositories
        isLoading = false
        guard repositoryPath == nil || !isEnabled else { return }
        repositoryPath = repositories.first {
            $0.path == preferredPath.map(WorkspacePathPresentation.standardizedPath)
        }?.path ?? repositories.first?.path
    }
}

struct NewTaskWorktreeOptionsView: View {
    let workspace: Workspace
    @Binding var selection: NewTaskWorktreeSelection

    private struct ScanRequest: Hashable {
        let workspaceID: UUID
        let primaryPath: String
        let additionalPaths: [String]
    }

    private var scanRequest: ScanRequest {
        ScanRequest(
            workspaceID: workspace.id,
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !selection.repositories.isEmpty || selection.isEnabled {
                Toggle("Start in a new worktree", isOn: $selection.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(Stanford.ui(13, weight: .medium))
                    .accessibilityIdentifier("NewTaskWorktreeToggle")

                if selection.isEnabled {
                    Text("Repository")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Picker("Repository", selection: $selection.repositoryPath) {
                            if selection.selectedRepository == nil {
                                Text("Choose a repository").tag(selection.repositoryPath)
                            }
                            ForEach(selection.repositories) { repository in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.name)
                                        .font(Stanford.ui(13, weight: .medium))
                                    Text(WorkspacePathPresentation.abbreviatePath(repository.path))
                                        .font(Stanford.caption(11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .tag(Optional(repository.path))
                                .help(repository.path)
                                .accessibilityIdentifier("NewTaskWorktreeRepository:\(repository.path)")
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)

                    if selection.isLoading {
                        ProgressView("Checking repositories...")
                            .controlSize(.small)
                    } else if selection.selectedRepository == nil {
                        Text("Choose an available repository before starting the task.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.errorRed)
                    } else {
                        Text("Choose one repository. ASTRA creates a new branch from its current commit; uncommitted changes stay in the original checkout.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scanRequest) {
            let request = scanRequest
            selection.isLoading = true
            let repositories = await GitService.shared.scanForGitRepositories(
                primaryPath: request.primaryPath,
                additionalPaths: request.additionalPaths
            )
            guard !Task.isCancelled, request == scanRequest else { return }
            selection.updateRepositories(repositories, preferredPath: workspace.activeWorkingPath)
        }
    }
}
