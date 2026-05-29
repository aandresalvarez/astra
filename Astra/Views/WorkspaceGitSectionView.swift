import SwiftUI
import SwiftData

struct WorkspaceGitSectionView: View {
    @StateObject var viewModel = WorkspaceGitViewModel()
    let workspace: Workspace
    var isCompact: Bool = false
    
    @State private var isChangesDrawerExpanded = false
    @State private var showWorktreeToast = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Environment title and Settings gear
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(Stanford.ui(13, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                    Text("Environment")
                        .font(Stanford.ui(13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                
                Spacer()
                
                if viewModel.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Menu {
                        Button(action: {
                            Task { await viewModel.scanRepositories() }
                        }) {
                            Label("Refresh Status", systemImage: "arrow.clockwise")
                        }
                        
                        if viewModel.errorMessage != nil {
                            Button(action: { viewModel.errorMessage = nil }) {
                                Label("Dismiss Errors", systemImage: "xmark.circle")
                            }
                        }
                        
                        // Active Repo Selector (if > 1 repos detected)
                        if viewModel.repositories.count > 1 {
                            Divider()
                            ForEach(viewModel.repositories) { repo in
                                Button(action: { viewModel.selectedRepository = repo }) {
                                    HStack {
                                        Text(repo.name)
                                        if repo.path == viewModel.selectedRepository?.path {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 18, height: 18)
                }
            }
            .padding(.bottom, 2)
            
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
            
            // List of Rows inside Environment Card
            VStack(spacing: 1) {
                // 1. CHANGES ROW
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isChangesDrawerExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.square")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 16)
                        
                        Text("Changes")
                            .font(Stanford.body(13))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        if viewModel.additions == 0 && viewModel.deletions == 0 {
                            Text("Clean")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(Stanford.statusHealthy)
                        } else {
                            HStack(spacing: 6) {
                                if viewModel.additions > 0 {
                                    Text("+\(viewModel.additions)")
                                        .font(Stanford.caption(12).weight(.semibold))
                                        .foregroundStyle(Stanford.statusHealthy)
                                }
                                if viewModel.deletions > 0 {
                                    Text("-\(viewModel.deletions)")
                                        .font(Stanford.caption(12).weight(.semibold))
                                        .foregroundStyle(Stanford.statusError)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(isExpanded: isChangesDrawerExpanded))
                
                // CHANGES DRAWER (Staged/Unstaged files and Commit composer)
                if isChangesDrawerExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                            .padding(.horizontal, 8)
                        
                        if viewModel.statusFiles.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(.title3)
                                    .foregroundStyle(Stanford.statusHealthy)
                                Text("No uncommitted changes")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        } else {
                            let staged = viewModel.statusFiles.filter { $0.isStaged }
                            let unstaged = viewModel.statusFiles.filter { !$0.isStaged }
                            
                            VStack(alignment: .leading, spacing: 10) {
                                // Staged Changes
                                if !staged.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Staged Changes (\(staged.count))")
                                                .font(Stanford.caption(10).weight(.bold))
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
                                
                                // Changes (Unstaged)
                                if !unstaged.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Changes (\(unstaged.count))")
                                                .font(Stanford.caption(10).weight(.bold))
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
                                
                                Divider()
                                
                                // Direct commit box inside the drawer
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField("Commit message...", text: $viewModel.commitMessage)
                                        .textFieldStyle(.roundedBorder)
                                        .font(Stanford.body(12))
                                    
                                    if !unstaged.isEmpty {
                                        Toggle("Stage all and commit", isOn: $viewModel.stageAllBeforeCommit)
                                            .toggleStyle(.checkbox)
                                            .font(Stanford.caption(11))
                                    }
                                    
                                    Button(action: {
                                        viewModel.commitChanges()
                                    }) {
                                        Text("Commit Changes")
                                            .font(Stanford.ui(12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(viewModel.commitMessage.isEmpty ? Stanford.sandstone : Stanford.cardinalRed)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(viewModel.commitMessage.isEmpty)
                                }
                            }
                            .frame(maxHeight: 220)
                            .overflowScrollView()
                        }
                    }
                    .padding(.bottom, 8)
                    .background(Color.primary.opacity(0.01))
                }
                
                Divider()
                    .padding(.horizontal, 8)
                
                // 2. ENVIRONMENT SELECTOR ROW ("Local" vs "Cloud")
                Button(action: { viewModel.showEnvironmentPopover = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.selectedEnvironment == "Local" ? "laptopcomputer" : "cloud")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 16)
                        
                        Text(viewModel.selectedEnvironment)
                            .font(Stanford.body(13))
                            .foregroundStyle(.primary)
                        
                        Image(systemName: "chevron.down")
                            .font(Stanford.ui(9, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .popover(isPresented: $viewModel.showEnvironmentPopover, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Continue in")
                            .font(Stanford.ui(11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        
                        Button(action: {
                            viewModel.selectedEnvironment = "Local"
                            viewModel.showEnvironmentPopover = false
                        }) {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                    .font(Stanford.ui(12))
                                Text("Work locally")
                                    .font(Stanford.body(13))
                                Spacer()
                                if viewModel.selectedEnvironment == "Local" {
                                    Image(systemName: "checkmark")
                                        .font(Stanford.ui(11, weight: .bold))
                                        .foregroundStyle(Stanford.lagunita)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            viewModel.selectedEnvironment = "Cloud"
                            viewModel.showEnvironmentPopover = false
                        }) {
                            HStack {
                                Image(systemName: "cloud")
                                    .font(Stanford.ui(12))
                                Text("Cloud")
                                    .font(Stanford.body(13))
                                Spacer()
                                if viewModel.selectedEnvironment == "Cloud" {
                                    Image(systemName: "checkmark")
                                        .font(Stanford.ui(11, weight: .bold))
                                        .foregroundStyle(Stanford.lagunita)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        HStack {
                            Image(systemName: "speedometer")
                                .font(Stanford.ui(12))
                            Text("Usage remaining")
                                .font(Stanford.body(13))
                            Spacer()
                            Text("0%")
                                .font(Stanford.caption(12).weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(Stanford.ui(9, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        Button(action: {
                            viewModel.showEnvironmentPopover = false
                            showWorktreeToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                showWorktreeToast = false
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(Stanford.ui(12))
                                Text("Handoff to worktree")
                                    .font(Stanford.body(13))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 180)
                    .padding(.vertical, 4)
                }
                
                Divider()
                    .padding(.horizontal, 8)
                
                // 3. BRANCH SELECTOR ROW
                Button(action: { viewModel.showBranchPickerPopover = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 16)
                        
                        Text(viewModel.currentBranch.isEmpty ? "Select Branch" : viewModel.currentBranch)
                            .font(Stanford.body(13))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        Image(systemName: "chevron.down")
                            .font(Stanford.ui(9, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .popover(isPresented: $viewModel.showBranchPickerPopover, arrowEdge: .trailing) {
                    BranchPickerPopoverView(viewModel: viewModel)
                }
                
                Divider()
                    .padding(.horizontal, 8)
                
                // 4. COMMIT OR PUSH ROW
                Button(action: { viewModel.showCommitPopover = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "cloud.and.arrow.up")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 16)
                        
                        Text("Commit or push")
                            .font(Stanford.body(13))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .popover(isPresented: $viewModel.showCommitPopover, arrowEdge: .trailing) {
                    CommitOrPushPopoverView(viewModel: viewModel)
                }
                
                Divider()
                    .padding(.horizontal, 8)
                
                // 5. CREATE PULL REQUEST ROW
                Button(action: { viewModel.createPullRequest() }) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(Stanford.ui(13, weight: .medium))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 16)
                        
                        Text("Create pull request")
                            .font(Stanford.body(13))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            .background(Color.primary.opacity(0.015))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Worktree handoff toast banner
            if showWorktreeToast {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Stanford.lagunita)
                    Text("Worktree handoff successfully initiated!")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Stanford.lagunita.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(.move(edge: .top).combined(with: .opacity))
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
            
            statusBadge(for: file.status)
            
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
        .padding(.vertical, 2.5)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.02))
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

// Custom Row Button Style to give interactive highlights matching mockup
struct RowButtonStyle: ButtonStyle {
    var isExpanded: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isExpanded || configuration.isPressed
                    ? Color.primary.opacity(0.06)
                    : Color.clear
            )
    }
}

// Custom Branch Picker Popover View
struct BranchPickerPopoverView: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    @State private var searchText = ""
    @State private var showingCreateForm = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showingCreateForm {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(action: { showingCreateForm = false }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(Stanford.ui(11, weight: .bold))
                                Text("Back")
                                    .font(Stanford.caption(11))
                            }
                            .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        Text("New Branch")
                            .font(Stanford.ui(12, weight: .bold))
                    }
                    
                    TextField("Branch name...", text: $viewModel.newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(Stanford.body(12))
                        .controlSize(.small)
                    
                    Button(action: {
                        viewModel.createAndCheckoutBranch()
                        showingCreateForm = false
                    }) {
                        Text("Create & Checkout")
                            .font(Stanford.ui(12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(viewModel.newBranchName.isEmpty ? Stanford.sandstone : Stanford.lagunita)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.newBranchName.isEmpty)
                }
                .padding(12)
                .frame(width: 220)
            } else {
                VStack(spacing: 6) {
                    // Search bar
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(Stanford.ui(11))
                        TextField("Search branches", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(Stanford.ui(12))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    
                    Divider()
                        .padding(.top, 2)
                    
                    // Filtered Branches Scroll List
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            let filtered = viewModel.branches.filter {
                                searchText.isEmpty ? true : $0.localizedCaseInsensitiveContains(searchText)
                            }
                            
                            if filtered.isEmpty {
                                Text("No branches found")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(filtered, id: \.self) { branch in
                                    Button(action: {
                                        viewModel.checkout(branch: branch)
                                        viewModel.showBranchPickerPopover = false
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "arrow.triangle.branch")
                                                .font(Stanford.ui(11))
                                                .foregroundStyle(.secondary)
                                            
                                            Text(branch)
                                                .font(Stanford.body(12.5))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            
                                            Spacer()
                                            
                                            if branch == viewModel.currentBranch {
                                                Image(systemName: "checkmark")
                                                    .font(Stanford.ui(10, weight: .bold))
                                                    .foregroundStyle(Stanford.lagunita)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5.5)
                                        .background(Color.primary.opacity(branch == viewModel.currentBranch ? 0.04 : 0))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    
                    Divider()
                    
                    Button(action: { showingCreateForm = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(Stanford.ui(10, weight: .bold))
                            Text("Create and checkout branch...")
                                .font(Stanford.caption(11.5).weight(.medium))
                        }
                        .foregroundStyle(Stanford.lagunita)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 220)
            }
        }
    }
}

// Custom Commit Or Push Popover View
struct CommitOrPushPopoverView: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    @State private var stageAll = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit & Push")
                .font(Stanford.ui(12, weight: .bold))
            
            TextField("Commit message...", text: $viewModel.commitMessage)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.body(12))
            
            Toggle("Stage all changes", isOn: $stageAll)
                .toggleStyle(.checkbox)
                .font(Stanford.caption(11))
            
            HStack(spacing: 8) {
                Button("Commit Only") {
                    viewModel.stageAllBeforeCommit = stageAll
                    viewModel.commitChanges()
                    viewModel.showCommitPopover = false
                }
                .controlSize(.small)
                .disabled(viewModel.commitMessage.isEmpty)
                
                Spacer()
                
                Button("Commit & Push") {
                    viewModel.stageAllBeforeCommit = stageAll
                    viewModel.commitChanges()
                    viewModel.showCommitPopover = false
                    
                    // Run push after brief delay to let commit execute
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        viewModel.push()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .controlSize(.small)
                .disabled(viewModel.commitMessage.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 240)
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
