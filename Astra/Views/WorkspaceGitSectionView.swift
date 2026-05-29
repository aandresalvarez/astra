import SwiftUI
import SwiftData

struct WorkspaceGitSectionView: View {
    @StateObject var viewModel = WorkspaceGitViewModel()
    let workspace: Workspace
    var isCompact: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title and Sync buttons
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                    Text("Git Repository")
                        .font(Stanford.ui(14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                
                Spacer()
                
                if viewModel.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                } else {
                    HStack(spacing: 12) {
                        Button(action: { viewModel.pull() }) {
                            Label("Pull", systemImage: "arrow.down.circle")
                                .font(Stanford.caption(11).weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.lagunita)
                        .help("Pull from remote repository")
                        
                        Button(action: { viewModel.push() }) {
                            Label("Push", systemImage: "arrow.up.circle")
                                .font(Stanford.caption(11).weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.lagunita)
                        .help("Push to remote repository")
                    }
                }
            }
            
            // Multiple Repos Picker (if > 1)
            if viewModel.repositories.count > 1 {
                Picker("Active Repo", selection: $viewModel.selectedRepository) {
                    ForEach(viewModel.repositories) { repo in
                        Text(repo.name).tag(repo as GitRepositoryInfo?)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }
            
            // Branch Picker & Add Branch Button
            HStack(spacing: 8) {
                Menu {
                    ForEach(viewModel.branches, id: \.self) { branch in
                        Button(action: { viewModel.checkout(branch: branch) }) {
                            HStack {
                                Text(branch)
                                if branch == viewModel.currentBranch {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .font(Stanford.ui(12))
                        Text(viewModel.currentBranch.isEmpty ? "Select Branch" : viewModel.currentBranch)
                            .font(Stanford.body(13))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                
                Button(action: { viewModel.showNewBranchPopover = true }) {
                    Image(systemName: "plus")
                        .font(Stanford.ui(10, weight: .bold))
                        .padding(6)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Create a new branch")
                .popover(isPresented: $viewModel.showNewBranchPopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Create New Branch")
                            .font(Stanford.ui(13, weight: .semibold))
                        
                        TextField("Branch Name", text: $viewModel.newBranchName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 200)
                        
                        HStack {
                            Button("Cancel") { viewModel.showNewBranchPopover = false }
                                .controlSize(.small)
                            Spacer()
                            Button("Create") { viewModel.createAndCheckoutBranch() }
                                .buttonStyle(.borderedProminent)
                                .tint(Stanford.lagunita)
                                .controlSize(.small)
                                .disabled(viewModel.newBranchName.isEmpty)
                        }
                    }
                    .padding()
                }
            }
            
            // Error Message Banner (if any)
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Stanford.errorRed)
                        .font(Stanford.ui(12))
                    Text(error)
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.errorRed)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Stanford.errorRed.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            // File Changes Lists
            if viewModel.statusFiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Stanford.paloAltoGreen)
                    Text("No uncommitted changes")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                let staged = viewModel.statusFiles.filter { $0.isStaged }
                let unstaged = viewModel.statusFiles.filter { !$0.isStaged }
                
                VStack(alignment: .leading, spacing: 12) {
                    // Staged list
                    if !staged.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Staged Changes (\(staged.count))")
                                    .font(Stanford.caption(10).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Unstage All") { viewModel.unstageAll() }
                                    .buttonStyle(.plain)
                                    .font(Stanford.caption(9))
                                    .foregroundStyle(Stanford.lagunita)
                            }
                            
                            ForEach(staged) { file in
                                fileRow(file: file, action: { viewModel.unstage(file: file) }, icon: "minus")
                            }
                        }
                    }
                    
                    // Unstaged list
                    if !unstaged.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Changes (\(unstaged.count))")
                                    .font(Stanford.caption(10).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Stage All") { viewModel.stageAll() }
                                    .buttonStyle(.plain)
                                    .font(Stanford.caption(9))
                                    .foregroundStyle(Stanford.lagunita)
                            }
                            
                            ForEach(unstaged) { file in
                                fileRow(file: file, action: { viewModel.stage(file: file) }, icon: "plus")
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .overflowScrollView()
            }
            
            // Commit composer (only if changes exist)
            if !viewModel.statusFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Commit message...", text: $viewModel.commitMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.body(12))
                    
                    if !viewModel.statusFiles.filter({ !$0.isStaged }).isEmpty {
                        Toggle("Stage all and commit", isOn: $viewModel.stageAllBeforeCommit)
                            .toggleStyle(.checkbox)
                            .font(Stanford.caption(11))
                    }
                    
                    Button(action: { viewModel.commitChanges() }) {
                        Text("Commit Changes")
                            .font(Stanford.ui(12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(viewModel.commitMessage.isEmpty ? Stanford.sandstone : Stanford.cardinalRed)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.commitMessage.isEmpty)
                }
            }
        }
        .onAppear {
            viewModel.setup(for: workspace)
        }
    }
    
    @ViewBuilder
    private func fileRow(file: GitStatusFile, action: @escaping () -> Void, icon: String) -> some View {
        HStack(spacing: 6) {
            Text(file.relativePath)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
            
            Spacer()
            
            // Status Indicator Badge
            statusBadge(for: file.status)
            
            // Action button (Plus/Minus)
            Button(action: action) {
                Image(systemName: icon)
                    .font(Stanford.ui(9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    @ViewBuilder
    private func statusBadge(for status: String) -> some View {
        let displayColor = badgeColor(for: status)
        Text(status)
            .font(Stanford.caption(9).weight(.bold))
            .foregroundStyle(displayColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(displayColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    
    private func badgeColor(for status: String) -> Color {
        switch status {
        case "A", "?": return Stanford.statusHealthy
        case "M": return Stanford.statusWarn
        case "D": return Stanford.statusError
        default: return Stanford.statusInfo
        }
    }
}

// Simple Helper to enable internal scroll if height exceeds bounds
struct OverflowScrollViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
        }
    }
}

extension View {
    fileprivate func overflowScrollView() -> some View {
        self.modifier(OverflowScrollViewModifier())
    }
}
