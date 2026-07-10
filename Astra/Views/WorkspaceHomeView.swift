import AppKit
import SwiftData
import SwiftUI
import ASTRACore
import ASTRAModels
import ASTRAPersistence

private enum WorkspaceHomeLayout {
    static let boardMaxWidth: CGFloat = 1_520
    static let minimumPageRailWidth: CGFloat = 920
    static let pagePadding: CGFloat = 24
}

/// The workspace page's top-level sections, one tab each. `allCases` order is
/// the tab order.
enum WorkspaceHomeSection: String, CaseIterable, Identifiable {
    case instructions
    case capabilities
    case access
    case memory
    case board
    case apps
    case routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instructions: return "Instructions"
        case .capabilities: return "Capabilities"
        case .access: return "Access"
        case .memory: return "Memory"
        case .board: return "Task board"
        case .apps: return "Apps"
        case .routines: return "Routines"
        }
    }
}

enum WorkspaceHomePresentation {
    static let usesSectionTabs = true
    // Instructions open readable by default: the default tab IS the full
    // rendered document, never a collapsed preview behind a "Read" toggle.
    static let defaultSection: WorkspaceHomeSection = .instructions
    static let sectionSelectionPersistsPerWorkspace = true
    static let usesKanbanMeasuredPageRail = true
    static let headerShowsWorkspaceStatus = false
    static let headerUsesOverviewMetrics = false
    static let headerUsesCompactOverviewMetrics = false
    static let statusCountsStayOnBoard = true
    static let emptyInstructionsUseSinglePrompt = true
    static let instructionBlockUsesPrimaryCTAWhenEmpty = true
    static let usesMinimumWelcomeRailWidth = true
    static let headerShowsPrimaryNewTaskAction = false
    static let routinesUseSummaryRows = true
    static let instructionEditorStaysInline = true
    static let rowIconFrame: CGFloat = 40
    static let rowMinHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
    static let minimumWelcomeRailWidth = WorkspaceHomeLayout.minimumPageRailWidth
}

enum WorkspaceInstructionPresentation {
    static let emptyPromptTitle = "Tell the agent how you work"
    static let emptyPromptBody = "Add conventions, tone, and what to avoid. They apply to every task in this workspace."
    static let emptyActionTitle = "Write instructions"
    static let rendersCommonMark = true
    static let preservesAuthoredLineBreaks = true
    static let editorHasFormattingToolbar = true
}

struct WorkspaceHomeContainerView: View {
    let workspace: Workspace
    let taskQueue: TaskQueue
    let onCreateTask: () -> Void
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    var onSetDoneState: ((AgentTask, Bool) -> Void)?
    let onRunQueue: () -> Void
    let onConfigure: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
    var onAddSSHConnection: (() -> Void)?
    var sshReloadTrigger: Int = 0

    @Query private var tasks: [AgentTask]
    @Query private var workspaceApps: [WorkspaceApp]
    @State private var isImportingApp = false
    @State private var isBrowsingLibrary = false

    init(
        workspace: Workspace,
        taskQueue: TaskQueue,
        onCreateTask: @escaping () -> Void,
        onOpenTask: @escaping (AgentTask) -> Void,
        onDeleteTask: @escaping (AgentTask) -> Void,
        onSetDoneState: ((AgentTask, Bool) -> Void)? = nil,
        onRunQueue: @escaping () -> Void,
        onConfigure: @escaping () -> Void,
        onNewSchedule: (() -> Void)? = nil,
        onEditSchedule: ((TaskSchedule) -> Void)? = nil,
        onManageCapabilities: (() -> Void)? = nil,
        onOpenWorkspaceApp: ((WorkspaceApp) -> Void)? = nil,
        onAddSSHConnection: (() -> Void)? = nil,
        sshReloadTrigger: Int = 0
    ) {
        self.workspace = workspace
        self.taskQueue = taskQueue
        self.onCreateTask = onCreateTask
        self.onOpenTask = onOpenTask
        self.onDeleteTask = onDeleteTask
        self.onSetDoneState = onSetDoneState
        self.onRunQueue = onRunQueue
        self.onConfigure = onConfigure
        self.onNewSchedule = onNewSchedule
        self.onEditSchedule = onEditSchedule
        self.onManageCapabilities = onManageCapabilities
        self.onOpenWorkspaceApp = onOpenWorkspaceApp
        self.onAddSSHConnection = onAddSSHConnection
        self.sshReloadTrigger = sshReloadTrigger

        let workspaceID = workspace.id
        _tasks = Query(
            filter: #Predicate<AgentTask> { task in
                task.workspace?.id == workspaceID
            },
            sort: \AgentTask.queuePosition
        )
        _workspaceApps = Query(
            filter: #Predicate<WorkspaceApp> { app in
                app.workspaceID == workspaceID
            },
            sort: \WorkspaceApp.name
        )
    }

    var body: some View {
        WorkspaceHomeView(
            workspace: workspace,
            // Enforce the board invariant at the view layer: a card is delegated
            // work, so drafts (in-composition chats) are never surfaced. A task
            // appears here the moment it's queued/run.
            tasks: tasks.filter { !TaskHygiene.isHiddenFromBoard($0) },
            workspaceApps: workspaceApps,
            onCreateTask: onCreateTask,
            onOpenTask: onOpenTask,
            onDeleteTask: onDeleteTask,
            onSetDoneState: onSetDoneState,
            onConfigure: onConfigure,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            onManageCapabilities: onManageCapabilities,
            onOpenWorkspaceApp: onOpenWorkspaceApp,
            onImportWorkspaceApp: { isImportingApp = true },
            onBrowseLibrary: { isBrowsingLibrary = true },
            onAddSSHConnection: onAddSSHConnection,
            sshReloadTrigger: sshReloadTrigger
        )
        .sheet(isPresented: $isImportingApp) {
            WorkspaceAppImportReviewView(
                workspace: workspace,
                onInstalled: { app in
                    isImportingApp = false
                    onOpenWorkspaceApp?(app)
                },
                onCancel: { isImportingApp = false }
            )
        }
        .sheet(isPresented: $isBrowsingLibrary) {
            WorkspaceAppPackageLibraryView(
                workspace: workspace,
                onInstalled: { app in
                    isBrowsingLibrary = false
                    onOpenWorkspaceApp?(app)
                },
                onCancel: { isBrowsingLibrary = false }
            )
        }
    }
}

struct WorkspaceHomeView: View {
    let workspace: Workspace
    let tasks: [AgentTask]
    var workspaceApps: [WorkspaceApp] = []
    let onCreateTask: () -> Void
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    var onSetDoneState: ((AgentTask, Bool) -> Void)?
    let onConfigure: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
    var onImportWorkspaceApp: (() -> Void)?
    var onBrowseLibrary: (() -> Void)?
    var onAddSSHConnection: (() -> Void)?
    var sshReloadTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingInstructions = false
    @State private var editedInstructions = ""
    @State private var instructionEditorController = WorkspaceInstructionEditorController()
    @State private var selectedSection = WorkspaceHomePresentation.defaultSection
    @State private var initializedPresentationWorkspaceID: UUID?
    @State private var sshConnections: [SSHConnection] = []
    @State private var newMemoryText = ""
    @State private var isMemoryComposerVisible = false
    @State private var pendingSetupDeletion: PendingWorkspaceSetupDeletion?
    @AppStorage("kanbanBoardDensity") private var densityRaw = KanbanBoardDensity.spacious.rawValue

    // The skill/connector/tool aggregators previously rendered by the
    // center-panel Plugins summary were deleted when that section moved
    // entirely to the right rail. If you need them again, the right rail
    // (WorkspaceRightRailView) already computes the same aggregates.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 16)

                    sectionTabBar
                        .padding(.bottom, 16)

                    if selectedSection != .board {
                        selectedSectionPanel
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: alignedContentWidth, alignment: .leading)
                .padding(.horizontal, KanbanBoardLayout.outerPadding)

                if selectedSection == .board {
                    KanbanBoardView(
                        tasks: tasks,
                        onOpenTask: onOpenTask,
                        onDeleteTask: onDeleteTask,
                        onSetDoneState: onSetDoneState
                    )
                    .frame(maxWidth: pageRailWidth, alignment: .leading)
                    .padding(.bottom, 24)
                }

            }
            .frame(maxWidth: pageRailWidth, alignment: .leading)
            .padding(.horizontal, WorkspaceHomeLayout.pagePadding)
            .padding(.vertical, WorkspaceHomeLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Stanford.panelBackground)
        .onAppear {
            initializePresentationIfNeeded()
            loadSSHConnections()
        }
        .onChange(of: workspace.id) {
            initializedPresentationWorkspaceID = nil
            initializePresentationIfNeeded()
            loadSSHConnections()
        }
        .onChange(of: workspace.primaryPath) {
            loadSSHConnections()
        }
        .onChange(of: sshReloadTrigger) {
            loadSSHConnections()
        }
        .confirmationDialog(
            pendingSetupDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingSetupDeletion != nil },
                set: { presented in if !presented { pendingSetupDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSetupDeletion
        ) { deletion in
            Button(deletion.confirmTitle, role: .destructive) {
                deletion.perform()
                pendingSetupDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSetupDeletion = nil
            }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    // MARK: - Section Tabs

    private var sectionTabBar: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(WorkspaceHomeSection.allCases) { section in
                sectionTabButton(section)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.055))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace sections")
    }

    private func sectionTabButton(_ section: WorkspaceHomeSection) -> some View {
        let isSelected = selectedSection == section

        return Button {
            selectSection(section)
        } label: {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(Stanford.ui(13, weight: isSelected ? .semibold : .medium))

                if let count = sectionCount(section), count > 0 {
                    Text("\(count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.055)))
                }
            }
            .foregroundStyle(isSelected ? Stanford.lagunita : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Stanford.lagunita : Color.clear)
                .frame(height: 2)
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(section.title)
    }

    private func sectionCount(_ section: WorkspaceHomeSection) -> Int? {
        switch section {
        case .instructions: return nil
        case .board: return tasks.count
        case .capabilities: return capabilityCount
        case .memory: return workspace.memories.count
        case .access: return accessConfiguredCount
        case .apps: return workspaceApps.count
        case .routines: return workspace.schedules.count
        }
    }

    private var accessConfiguredCount: Int {
        WorkspaceSetupChecklistPresentation.userConfiguredFolderCount(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        ) + sshConnections.count
    }

    private func selectSection(_ section: WorkspaceHomeSection) {
        guard selectedSection != section else { return }
        withAnimation(disclosureAnimation) {
            selectedSection = section
        }
        persistSelectedSection(section)
    }

    @ViewBuilder
    private var selectedSectionPanel: some View {
        switch selectedSection {
        case .instructions:
            instructionsBlock.workspaceSectionPanel()
        case .capabilities:
            capabilitiesTab.workspaceSectionPanel()
        case .memory:
            memoryTab.workspaceSectionPanel()
        case .access:
            accessTab.workspaceSectionPanel()
        case .apps:
            appsTab.workspaceSectionPanel()
        case .routines:
            routinesTab.workspaceSectionPanel()
        case .board:
            EmptyView()
        }
    }

    private var boardDensity: KanbanBoardDensity {
        KanbanBoardDensity(rawValue: densityRaw) ?? .spacious
    }

    private var visibleBoardCategories: [KanbanCategory] {
        let persistentDropCategories: Set<KanbanCategory> = [.review, .done]
        guard !tasks.isEmpty else {
            return KanbanCategory.allCases.filter { persistentDropCategories.contains($0) }
        }

        return KanbanCategory.allCases.filter { category in
            persistentDropCategories.contains(category)
                || tasks.contains { category.includes($0) }
        }
    }

    private var boardContentWidth: CGFloat {
        KanbanBoardLayout.contentWidth(for: visibleBoardCategories, density: boardDensity)
    }

    private var pageRailWidth: CGFloat {
        min(
            WorkspaceHomeLayout.boardMaxWidth,
            max(
                WorkspaceHomeLayout.minimumPageRailWidth,
                boardContentWidth + (KanbanBoardLayout.outerPadding * 2)
            )
        )
    }

    private var alignedContentWidth: CGFloat {
        max(0, pageRailWidth - (KanbanBoardLayout.outerPadding * 2))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(Stanford.ui(21, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)

            Text(workspace.name)
                .font(Stanford.heading(22))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Capabilities Tab

    // Deliberately renders only what the Workspace model already holds
    // (names + icons) — no capability-package or approval-record reads. The
    // right rail once scanned those directories from `body` and it cost 68
    // directory reads per evaluation; Manage remains the door to the full
    // capability UI.
    private var capabilitiesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(capabilitySubtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                Button(action: onManageCapabilities ?? onConfigure) {
                    HStack(spacing: 4) {
                        Text("Manage")
                        Image(systemName: "chevron.right")
                            .font(Stanford.ui(10, weight: .semibold))
                    }
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .help("Manage workspace capabilities")
            }

            if capabilityRowCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(workspace.skills.enumerated()), id: \.offset) { _, skill in
                        capabilityRow(icon: skill.icon, fallbackIcon: "sparkles", name: skill.name, kind: "Skill")
                    }
                    ForEach(Array(workspace.connectors.enumerated()), id: \.offset) { _, connector in
                        capabilityRow(icon: connector.icon, fallbackIcon: "link", name: connector.name, kind: "Connector")
                    }
                    ForEach(Array(workspace.localTools.enumerated()), id: \.offset) { _, tool in
                        capabilityRow(icon: tool.icon, fallbackIcon: "wrench.and.screwdriver", name: tool.name, kind: "Tool")
                    }
                }
            } else if capabilityCount > 0 {
                // enabledCapabilityIDs can be ahead of the materialized
                // skill/connector/tool relations, so there is nothing to list
                // here even though capabilities are enabled. Point at Manage
                // instead of claiming "none active".
                sectionEmptyMessage(
                    icon: "checkmark.shield",
                    title: "\(capabilityCount) \(capabilityCount == 1 ? "capability" : "capabilities") enabled",
                    body: "Open Manage to review and configure what's active in this workspace."
                )
            } else {
                sectionEmptyMessage(
                    icon: "checkmark.shield",
                    title: "No capabilities active",
                    body: "Browse the library to add skills, connectors, and tools the agent can use in this workspace."
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func capabilityRow(icon: String, fallbackIcon: String, name: String, kind: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon.isEmpty ? fallbackIcon : icon)
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 22)

            Text(name)
                .font(Stanford.body(13))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(kind)
                .font(Stanford.caption(11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Memory Tab

    // Memory/folders/remote-access mirror the same Workspace fields and
    // actions the right rail's "Workspace setup" checklist already owns
    // (WorkspaceRightRailView.swift) — reusing WorkspaceSetupChecklistPresentation's
    // pure helpers there instead of re-deriving folder/state logic here.
    private var memoryTab: some View {
        memorySetupSubsection
            .padding(.vertical, 4)
    }

    // MARK: - Access Tab

    private var accessTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderSetupSubsection

            workspaceDivider
                .padding(.vertical, 16)

            remoteAccessSetupSubsection
        }
        .padding(.vertical, 4)
    }

    private func setupSubsectionHeader(
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 20)

                Text(title)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(subtitle)
                .font(Stanford.caption(12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
        }
        .padding(.bottom, 10)
    }

    private func setupInlineRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(detail)
                    .font(Stanford.mono(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(detail)

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Memory

    private var memorySetupSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupSubsectionHeader(
                icon: "text.badge.checkmark",
                title: "Memory",
                subtitle: workspace.memories.isEmpty
                    ? "Details the agent remembers"
                    : "\(workspace.memories.count) saved \(workspace.memories.count == 1 ? "detail" : "details")",
                actionTitle: "Add",
                action: {
                    withAnimation(disclosureAnimation) {
                        isMemoryComposerVisible = true
                    }
                }
            )

            if workspace.memories.isEmpty && !isMemoryComposerVisible {
                sectionEmptyMessage(
                    icon: "text.badge.checkmark",
                    title: "No memory yet",
                    body: "Save details the agent should remember about this workspace so you don't have to re-explain them."
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(workspace.memories.indices), id: \.self) { index in
                        memoryRow(index)
                    }
                }
            }

            if isMemoryComposerVisible {
                memoryComposer
            }
        }
    }

    private func memoryRow(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Saved detail", text: memoryBinding(at: index), axis: .vertical)
                .font(Stanford.caption(13))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

            Button {
                requestMemoryDeletion(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 26)
            }
            .buttonStyle(.plain)
            .help("Remove memory")
        }
    }

    private var memoryComposer: some View {
        HStack(spacing: 8) {
            TextField("Remember something about this workspace...", text: $newMemoryText, axis: .vertical)
                .font(Stanford.caption(13))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { addMemory() }

            Button {
                addMemory()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(Stanford.ui(15))
                    .foregroundStyle(
                        newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary.opacity(0.4)
                            : Stanford.lagunita
                    )
            }
            .buttonStyle(.plain)
            .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Save memory")

            Button {
                newMemoryText = ""
                isMemoryComposerVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
    }

    private func memoryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard workspace.memories.indices.contains(index) else { return "" }
                return workspace.memories[index]
            },
            set: { value in
                guard workspace.memories.indices.contains(index) else { return }
                workspace.memories[index] = value
                markWorkspaceConfigurationChanged()
            }
        )
    }

    private func addMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        workspace.memories.append(text)
        markWorkspaceConfigurationChanged()
        newMemoryText = ""
        isMemoryComposerVisible = false
    }

    private func requestMemoryDeletion(at index: Int) {
        guard workspace.memories.indices.contains(index) else { return }
        let detail = workspace.memories[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = detail.isEmpty ? "This saved detail" : "\u{201c}\(detail.prefix(80))\u{201d}"
        pendingSetupDeletion = PendingWorkspaceSetupDeletion(
            title: "Remove memory?",
            message: "\(shown) will be removed from this workspace's memory.",
            confirmTitle: "Remove",
            perform: { removeMemory(at: index) }
        )
    }

    private func removeMemory(at index: Int) {
        guard workspace.memories.indices.contains(index) else { return }
        workspace.memories.remove(at: index)
        markWorkspaceConfigurationChanged()
    }

    // MARK: Folders

    private var folderSetupSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupSubsectionHeader(
                icon: "folder",
                title: WorkspaceSetupChecklistPresentation.folderAccessTitle,
                subtitle: WorkspaceSetupChecklistPresentation.folderSubtitle(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                ),
                actionTitle: WorkspaceSetupChecklistPresentation.addFolderActionTitle,
                action: addExtraFolder
            )

            VStack(alignment: .leading, spacing: 6) {
                if let rootDescriptor = WorkspacePathPresentation.descriptors(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: []
                ).first {
                    folderRow(WorkspaceSetupChecklistPresentation.folderDetailRow(for: rootDescriptor), removeAction: nil)
                }

                ForEach(WorkspaceSetupChecklistPresentation.userConfiguredFolderDescriptors(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                )) { descriptor in
                    folderRow(
                        WorkspaceSetupChecklistPresentation.folderDetailRow(for: descriptor),
                        removeAction: { removeAdditionalPaths(matching: descriptor.path) }
                    )
                }
            }
        }
    }

    private func folderRow(_ row: WorkspaceFolderDetailRowPresentation, removeAction: (() -> Void)?) -> some View {
        setupInlineRow(title: "\(row.title) · \(row.subtitle)", detail: row.path) {
            HStack(spacing: 4) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Stanford.ui(10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .help(row.copyPathHelp)

                if row.canRemove, let removeAction {
                    Button {
                        pendingSetupDeletion = PendingWorkspaceSetupDeletion(
                            title: "Remove folder?",
                            message: "\(row.path) will no longer be available to the agent. The folder itself is not deleted.",
                            confirmTitle: "Remove",
                            perform: removeAction
                        )
                    } label: {
                        Image(systemName: "trash")
                            .font(Stanford.ui(11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Remove folder")
                }
            }
        }
    }

    private func addExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder the agent can also read from or execute in"
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !workspace.additionalPaths.contains(path) {
                workspace.additionalPaths.append(path)
                markWorkspaceConfigurationChanged()
            }
        }
    }

    private func removeAdditionalPaths(matching path: String) {
        let remaining = WorkspaceSetupChecklistPresentation.remainingAdditionalPaths(
            afterRemovingFolderMatching: path,
            from: workspace.additionalPaths
        )
        guard remaining.count != workspace.additionalPaths.count else { return }
        workspace.additionalPaths = remaining
        markWorkspaceConfigurationChanged()
    }

    // MARK: Remote Access

    private var remoteAccessSetupSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupSubsectionHeader(
                icon: "network",
                title: "Remote access",
                subtitle: sshConnections.isEmpty
                    ? "Servers the agent can reach"
                    : "\(sshConnections.count) configured \(sshConnections.count == 1 ? "server" : "servers")",
                actionTitle: sshConnections.isEmpty ? "Connect" : "Add",
                action: onAddSSHConnection
            )

            if sshConnections.isEmpty {
                sectionEmptyMessage(
                    icon: "network",
                    title: "No remote servers",
                    body: "Connect a server over SSH so the agent can run commands there directly."
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sshConnections) { connection in
                        setupInlineRow(
                            title: connection.name.isEmpty ? connection.host : connection.name,
                            detail: remoteConnectionDetail(connection)
                        ) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private func remoteConnectionDetail(_ connection: SSHConnection) -> String {
        let target = "\(connection.user)@\(connection.host):\(connection.port)"
        let remotePath = connection.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return remotePath.isEmpty ? target : "\(target)  \(remotePath)"
    }

    private func loadSSHConnections() {
        guard !workspace.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
    }

    // MARK: Shared

    private func markWorkspaceConfigurationChanged() {
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
    }

    // MARK: - Apps Tab

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(workspaceApps.isEmpty
                    ? "Small apps published by tasks in this workspace"
                    : "\(workspaceApps.count) \(workspaceApps.count == 1 ? "app" : "apps") in this workspace")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                if let onBrowseLibrary {
                    Button(action: onBrowseLibrary) {
                        Label("Library", systemImage: "books.vertical")
                            .font(Stanford.caption(11))
                    }
                    .buttonStyle(.borderless)
                    .help("Browse a shared folder of ASTRA app packages")
                }
                if let onImportWorkspaceApp {
                    Button(action: onImportWorkspaceApp) {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .font(Stanford.caption(11))
                    }
                    .buttonStyle(.borderless)
                    .help("Import an ASTRA app package (.astra-app)")
                }
            }

            if workspaceApps.isEmpty {
                sectionEmptyMessage(
                    icon: "square.grid.2x2",
                    title: "No apps yet",
                    body: "Import an app package or browse the library — published apps show up here."
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workspaceApps) { app in
                        Button {
                            onOpenWorkspaceApp?(app)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: app.icon.isEmpty ? "square.grid.2x2" : app.icon)
                                    .font(Stanford.ui(13))
                                    .foregroundStyle(Stanford.lagunita)
                                    .frame(width: 22)
                                Text(app.name)
                                    .font(Stanford.body(13))
                                    .foregroundStyle(Stanford.black)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(Stanford.ui(11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Routines Tab

    private var routinesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(workspace.schedules.isEmpty
                    ? "Recurring agent runs on a schedule"
                    : "\(workspace.schedules.count) \(workspace.schedules.count == 1 ? "routine" : "routines") configured")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                if onNewSchedule != nil {
                    Button(action: { onNewSchedule?() }) {
                        Label("Add routine", systemImage: "plus")
                            .font(Stanford.caption(11))
                    }
                    .buttonStyle(.borderless)
                    .help("Schedule a recurring agent run")
                }
            }

            if workspace.schedules.isEmpty {
                sectionEmptyMessage(
                    icon: "arrow.triangle.2.circlepath",
                    title: "No routines yet",
                    body: "Add a routine to run a task on a schedule — daily digests, recurring checks, cleanups."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sortedSchedules.enumerated()), id: \.element.id) { index, schedule in
                        if index > 0 {
                            workspaceDivider
                        }

                        WorkspaceScheduleRow(
                            schedule: schedule,
                            onToggle: {
                                schedule.isEnabled.toggle()
                                schedule.updatedAt = Date()
                            },
                            onEdit: { onEditSchedule?(schedule) }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sortedSchedules: [TaskSchedule] {
        workspace.schedules.sorted { $0.name < $1.name }
    }

    private func sectionEmptyMessage(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: WorkspaceHomePresentation.rowSpacing) {
            Image(systemName: icon)
                .font(Stanford.ui(19, weight: .medium))
                .foregroundStyle(Stanford.lagunita.opacity(0.8))
                .frame(width: WorkspaceHomePresentation.rowIconFrame)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(body)
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Instructions Tab

    @ViewBuilder
    private var instructionsBlock: some View {
        if isEditingInstructions {
            instructionsEditingBlock
        } else if hasInstructions {
            instructionsConfiguredBlock
        } else {
            instructionsEmptyBlock
        }
    }

    private var instructionsEmptyBlock: some View {
        Button(action: startEditingInstructions) {
            HStack(alignment: .top, spacing: WorkspaceHomePresentation.rowSpacing) {
                Image(systemName: "text.alignleft")
                    .font(Stanford.ui(19, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: WorkspaceHomePresentation.rowIconFrame)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 7) {
                    Text(WorkspaceInstructionPresentation.emptyPromptTitle)
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(WorkspaceInstructionPresentation.emptyPromptBody)
                        .font(Stanford.caption(13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(WorkspaceInstructionPresentation.emptyActionTitle)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Stanford.lagunita)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add workspace instructions")
    }

    private var instructionsConfiguredBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
            // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
            HStack(alignment: .top, spacing: 10) {
                Text(instructionsStatsSummary)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                Button {
                    startEditingInstructions()
                } label: {
                    Text("Edit")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .help("Edit workspace instructions")
            }

            MarkdownTextView(
                text: instructionsRenderedMarkdown,
                maxContentWidth: nil,
                isSelectable: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !workspace.additionalPaths.isEmpty {
                Text("Includes \(workspace.additionalPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var instructionsEditingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceInstructionToolbar(controller: instructionEditorController)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                WorkspaceInstructionEditorView(text: $editedInstructions, controller: instructionEditorController)
                    .frame(minHeight: 220, maxHeight: 480)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.026))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Stanford.lagunita.opacity(0.28), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Text(editedInstructionsWordCountLabel)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    cancelEditingInstructions()
                } label: {
                    Text("Cancel")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    saveEditedInstructions()
                } label: {
                    Text("Save")
                        .font(Stanford.caption(12).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Stanford.lagunita)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save (⌘↩)")
            }
        }
        .padding(.vertical, 4)
    }

    private var workspaceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(height: 1)
            .padding(.leading, WorkspaceHomePresentation.rowIconFrame + WorkspaceHomePresentation.rowSpacing)
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var hasInstructions: Bool {
        !workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var instructionsRenderedMarkdown: String {
        WorkspaceInstructionMarkdown.preparedForRendering(workspace.instructions)
    }

    private var instructionsStatsSummary: String {
        WorkspaceInstructionMarkdown.summary(for: workspace.instructions)
    }

    private var editedInstructionsWordCountLabel: String {
        let words = editedInstructions.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return "Markdown supported" }
        return "\(words) word\(words == 1 ? "" : "s")"
    }

    private var capabilityRowCount: Int {
        workspace.skills.count + workspace.connectors.count + workspace.localTools.count
    }

    private var capabilityCount: Int {
        max(workspace.enabledCapabilityIDs.count, capabilityRowCount)
    }

    private var capabilitySubtitle: String {
        let parts: [String] = [
            countPhrase(workspace.skills.count, singular: "skill", plural: "skills"),
            countPhrase(workspace.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(workspace.localTools.count, singular: "tool", plural: "tools")
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return capabilityCount > 0
                ? "\(capabilityCount) active"
                : "None active — browse the library to add skills, connectors, and tools"
        }
        return "\(capabilityCount) active — \(parts.joined(separator: ", "))"
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    private func startEditingInstructions() {
        editedInstructions = workspace.instructions
        isEditingInstructions = true
        selectSection(.instructions)
    }

    private func cancelEditingInstructions() {
        isEditingInstructions = false
    }

    private func saveEditedInstructions() {
        workspace.instructions = editedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        markWorkspaceConfigurationChanged()
        isEditingInstructions = false
    }

    private func initializePresentationIfNeeded() {
        guard initializedPresentationWorkspaceID != workspace.id else { return }
        initializedPresentationWorkspaceID = workspace.id
        isEditingInstructions = false
        // This view instance is reused across workspace switches, so any
        // in-progress Memory-tab draft belongs to whichever workspace was
        // showing when the user started it — carrying it over would append a
        // stale draft to the wrong workspace's memory, or leave a deletion
        // dialog for a memory that isn't even on screen anymore.
        isMemoryComposerVisible = false
        newMemoryText = ""
        pendingSetupDeletion = nil
        // Restore the user's last tab choice for this workspace; first visit
        // lands on Instructions so the workspace prompt is open to read.
        selectedSection = loadSelectedSection()
    }

    private func selectedSectionKey() -> String {
        "workspaceHome.selectedSection.\(workspace.id.uuidString)"
    }

    private func loadSelectedSection() -> WorkspaceHomeSection {
        guard let raw = UserDefaults.standard.string(forKey: selectedSectionKey()),
              let section = WorkspaceHomeSection(rawValue: raw) else {
            return WorkspaceHomePresentation.defaultSection
        }
        return section
    }

    private func persistSelectedSection(_ section: WorkspaceHomeSection) {
        UserDefaults.standard.set(section.rawValue, forKey: selectedSectionKey())
    }

}

private struct PendingWorkspaceSetupDeletion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void
}

private struct WorkspaceHomeSummaryRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let onSelect: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: WorkspaceHomePresentation.rowSpacing) {
            // A real Button, not a gesture, so the row body is a proper keyboard /
            // accessibility tap target. The trailing controls stay separate.
            if let onSelect {
                Button(action: onSelect) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }

            trailing()
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, minHeight: WorkspaceHomePresentation.rowMinHeight, alignment: .leading)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: WorkspaceHomePresentation.rowSpacing) {
            Image(systemName: icon)
                .font(Stanford.ui(20, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: WorkspaceHomePresentation.rowIconFrame)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)
        }
        .contentShape(Rectangle())
    }
}

private struct WorkspaceSectionPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceHomePresentation.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceHomePresentation.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

private extension View {
    func workspaceSectionPanel() -> some View {
        modifier(WorkspaceSectionPanelModifier())
    }
}

// MARK: - Routine Row

private struct WorkspaceScheduleRow: View {
    let schedule: TaskSchedule
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        WorkspaceHomeSummaryRow(
            icon: "arrow.triangle.2.circlepath",
            iconColor: schedule.isEnabled ? Stanford.lagunita : Color.secondary.opacity(0.78),
            title: schedule.name,
            subtitle: schedule.frequencySummary,
            onSelect: onEdit
        ) {
            HStack(spacing: 12) {
                if schedule.fireCount > 0 {
                    Text("\(schedule.fireCount) \(schedule.fireCount == 1 ? "run" : "runs")")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Toggle("", isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            }
        }
    }
}
