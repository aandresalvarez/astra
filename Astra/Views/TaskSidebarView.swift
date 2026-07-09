import SwiftUI
import SwiftData
import AppKit
import ASTRAModels
import ASTRAPersistence
import ASTRACore

struct TaskSidebarContainerView: View {
    @Query(sort: \AgentTask.queuePosition) private var tasks: [AgentTask]
    @Query(sort: \WorkspaceApp.name) private var workspaceApps: [WorkspaceApp]

    @Binding var selectedTask: AgentTask?
    let taskQueue: TaskQueue
    let workspaces: [Workspace]
    @Binding var selectedWorkspace: Workspace?
    let onNewTask: () -> Void
    let onRunQueue: () -> Void
    let onRunTask: (AgentTask) -> Void
    var onToggleDone: ((AgentTask) -> Void)?
    var onCancelTask: ((AgentTask) -> Void)?
    var onRetryTask: ((AgentTask) -> Void)?
    var onDeleteTask: ((AgentTask) -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onEditWorkspace: ((Workspace) -> Void)?
    var onImportWorkspace: (() -> Void)?
    var onShowConfigure: (() -> Void)?
    var onDeleteWorkspace: ((Workspace) -> Void)?
    var onRenameWorkspace: ((Workspace) -> Void)?
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onNewApp: (() -> Void)?
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
    var selectedWorkspaceApp: WorkspaceApp?

    var body: some View {
        TaskSidebarView(
            tasks: tasks,
            selectedTask: $selectedTask,
            taskQueue: taskQueue,
            workspaces: workspaces,
            selectedWorkspace: $selectedWorkspace,
            onNewTask: onNewTask,
            onRunQueue: onRunQueue,
            onRunTask: onRunTask,
            onToggleDone: onToggleDone,
            onCancelTask: onCancelTask,
            onRetryTask: onRetryTask,
            onDeleteTask: onDeleteTask,
            onNewWorkspace: onNewWorkspace,
            onEditWorkspace: onEditWorkspace,
            onImportWorkspace: onImportWorkspace,
            onShowConfigure: onShowConfigure,
            onDeleteWorkspace: onDeleteWorkspace,
            onRenameWorkspace: onRenameWorkspace,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            onNewApp: onNewApp,
            workspaceApps: workspaceApps,
            onOpenWorkspaceApp: onOpenWorkspaceApp,
            selectedWorkspaceApp: selectedWorkspaceApp
        )
    }
}

enum WorkspaceSidebarFilter {
    static func visibleWorkspaces(
        _ workspaces: [Workspace],
        showStarredOnly: Bool,
        searchText: String,
        workspaceMatchesSearch: (Workspace) -> Bool,
        hasMatchingTasks: (Workspace) -> Bool
    ) -> [Workspace] {
        let sorted = workspaces.sorted {
            if $0.isStarred != $1.isStarred {
                return $0.isStarred && !$1.isStarred
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let filteredByStar = showStarredOnly ? sorted.filter(\.isStarred) : sorted
        guard !searchText.isEmpty else { return filteredByStar }

        return filteredByStar.filter { workspace in
            workspaceMatchesSearch(workspace) || hasMatchingTasks(workspace)
        }
    }
}

enum SidebarLeanPresentation {
    static let usesQuietNewTaskCommand = true
    static let sectionHeadersShowCounts = true
    static let workspacesUseSingleFlatList = true
    static let sidebarTaskTitlesUsePrefixPrimaryPresentation = true
    static let workspaceStarsMoveToTrailingEdge = true
    static let workspaceMetadataAndActionsShareTrailingSlot = true
    static let selectedWorkspaceChildrenUseGuide = false
    static let sidebarTaskStatusesShowExceptionsOnly = true
    // Status is a leading glyph, never a second text line: rows stay
    // single-height so the list scans as navigation, and one status
    // vocabulary replaces the old icon-vs-subtitle split. (Pinned and
    // Unreads rows still show a workspace-name subtitle — that's
    // context, not status.)
    static let sidebarTaskStatusesNeverAddSecondLine = true
    // Workspace rows expose expansion with a rest-state chevron; the
    // folder icon's fill tracks selection only, so icon fill no longer
    // does double duty as a collapsed/expanded signal.
    static let workspaceRowsShowRestStateDisclosure = true
    static let workspaceDisclosureChevronWidth: CGFloat = 11
    // The pinned drop target is drag-time chrome: it appears while a task
    // drag is in flight and otherwise cedes the space above the fold.
    static let pinnedDropZoneAppearsOnlyDuringDrag = true
    static let pinnedPreviewLimit = 5
    // Row surfaces still span the full rail width (childTaskListLeadingPadding
    // stays 0 so hover/selection chrome lines up with the workspace card), but
    // child content steps in 12pt so containment reads without a guide rail.
    static let childTaskListLeadingPadding: CGFloat = 0
    static let childTaskContentLeadingPadding: CGFloat = 12
    static let workspaceRowTrailingSlotWidth: CGFloat = 58
    static let newTaskVerticalPadding: CGFloat = 7
    static let newTaskRestFillOpacity = 0.045
    static let newTaskHoverFillOpacity = 0.075
}

enum SidebarThreadRowLayout {
    static let rowHorizontalPadding: CGFloat = 8
    static let statusIconWidth: CGFloat = 14
    static let statusIconTitleSpacing: CGFloat = 9
    static let titleFontSize: CGFloat = 14

    static func showsStatusIcon(
        for status: TaskStatus,
        isUnread: Bool,
        isHovered: Bool,
        isSelected: Bool
    ) -> Bool {
        isHovered || isSelected || showsRestStateGlyph(for: status, isUnread: isUnread)
    }

    static func isActionableStatus(_ status: TaskStatus) -> Bool {
        switch status {
        case .running, .pendingUser, .failed, .budgetExceeded:
            return true
        case .draft, .queued, .completed, .cancelled:
            return false
        }
    }

    /// The states that earn a glyph at rest: work that is moving or needs
    /// the user (actionable), plus finished-but-unseen results (unread) so
    /// "what needs my eyes" is answerable from the sidebar alone.
    static func showsRestStateGlyph(for status: TaskStatus, isUnread: Bool) -> Bool {
        isActionableStatus(status) || isUnread
    }

    static func restingTitleLeadingOffset(
        childListPadding: CGFloat,
        contentLeadingPadding: CGFloat,
        status: TaskStatus,
        isUnread: Bool = false
    ) -> CGFloat {
        childListPadding
            + rowHorizontalPadding
            + contentLeadingPadding
            + reservedStatusIconWidth(for: status, isUnread: isUnread)
    }

    private static func reservedStatusIconWidth(for status: TaskStatus, isUnread: Bool) -> CGFloat {
        showsRestStateGlyph(for: status, isUnread: isUnread)
            ? statusIconWidth + statusIconTitleSpacing
            : 0
    }
}

enum SidebarColumnLayout {
    /// The expanded sidebar needs enough room for a workspace name plus the
    /// fixed trailing count/action slot. Below this, collapse the column instead
    /// of rendering a clipped navigation rail.
    static let expandedMinimumWidth: CGFloat = 310
    static let expandedIdealWidth: CGFloat = 320
    static let expandedMaximumWidth: CGFloat = 360
    static let collapseEdge: Edge = .leading
    static let collapseUsesRightPanelMotion = true

    static func shouldCollapseExpandedSidebar(width: CGFloat, isRevealInProgress: Bool = false) -> Bool {
        guard !isRevealInProgress else { return false }
        return width > 0 && width < expandedMinimumWidth
    }

    static func shouldCollapseVisibleSplitWidth(
        _ width: CGFloat,
        minimumExpandedWidth: CGFloat = expandedMinimumWidth,
        isRevealInProgress: Bool = false
    ) -> Bool {
        guard !isRevealInProgress else { return false }
        return width.isFinite && width > 0 && width < minimumExpandedWidth
    }

    static func shouldCompleteSidebarReveal(
        width: CGFloat,
        minimumExpandedWidth: CGFloat = expandedMinimumWidth
    ) -> Bool {
        width.isFinite && width >= minimumExpandedWidth
    }

    static func collapseAnimation(reduceMotion: Bool) -> Animation? {
        AstraMotion.rightPanel(reduceMotion: reduceMotion)
    }

    static func collapseTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .move(edge: collapseEdge)
    }
}

enum SidebarRevealSettlingPolicy {
    static let fallbackDelayNanoseconds: UInt64 = 450_000_000

    static func nextRevision(after revision: Int) -> Int {
        revision == Int.max ? 1 : revision + 1
    }

    static func shouldBeginReveal(isRevealInProgress: Bool) -> Bool {
        !isRevealInProgress
    }

    static func shouldClearReveal(
        scheduledRevision: Int,
        currentRevision: Int,
        isRevealInProgress: Bool
    ) -> Bool {
        isRevealInProgress && scheduledRevision == currentRevision
    }
}

private struct SidebarTopToolbar: View {
    let showsWorkspaceActions: Bool
    var onNewWorkspace: (() -> Void)?
    var onImportWorkspace: (() -> Void)?

    private var showsAddWorkspaceMenu: Bool {
        showsWorkspaceActions && (onNewWorkspace != nil || onImportWorkspace != nil)
    }

    var body: some View {
        // Search moved to the leading titlebar accessory (AstraLeadingCommandBar).
        // Only the workspace-list add menu remains; render nothing when it doesn't
        // apply so the column toolbar stays empty rather than padded.
        if showsAddWorkspaceMenu {
            AstraToolbarCommandCluster {
                Menu {
                    if let onNewWorkspace {
                        Button(action: onNewWorkspace) {
                            Label("New Workspace", systemImage: "folder.badge.plus")
                        }
                    }
                    if let onImportWorkspace {
                        Button(action: onImportWorkspace) {
                            Label("Import Workspace", systemImage: "square.and.arrow.down")
                        }
                    }
                } label: {
                    AstraToolbarCommandIcon(systemImage: "folder.badge.plus", isActive: false)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Add workspace")
                .accessibilityLabel("Add workspace")
            }
        }
    }
}

enum SidebarWorkspaceTaskList {
    static let collapsedLimit = 6

    static func visibleTasks(_ tasks: [AgentTask], isShowingAll: Bool) -> [AgentTask] {
        isShowingAll ? tasks : Array(tasks.prefix(collapsedLimit))
    }

    static func hiddenTaskCount(totalTasks: Int, visibleTasks: Int) -> Int {
        max(0, totalTasks - visibleTasks)
    }
}

struct TaskSidebarView: View {
    let tasks: [AgentTask]
    @Binding var selectedTask: AgentTask?
    let taskQueue: TaskQueue
    let workspaces: [Workspace]
    @Binding var selectedWorkspace: Workspace?
    let onNewTask: () -> Void
    let onRunQueue: () -> Void
    let onRunTask: (AgentTask) -> Void
    var onToggleDone: ((AgentTask) -> Void)?
    var onCancelTask: ((AgentTask) -> Void)?
    var onRetryTask: ((AgentTask) -> Void)?
    var onDeleteTask: ((AgentTask) -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onEditWorkspace: ((Workspace) -> Void)?
    var onImportWorkspace: (() -> Void)?
    var onShowConfigure: (() -> Void)?
    var onDeleteWorkspace: ((Workspace) -> Void)?
    var onRenameWorkspace: ((Workspace) -> Void)?
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onNewApp: (() -> Void)?
    /// The workspace's published apps, surfaced inline under each workspace alongside
    /// its chats. Empty (and the rows are suppressed) when no open handler is wired.
    var workspaceApps: [WorkspaceApp] = []
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
    var selectedWorkspaceApp: WorkspaceApp?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isPinnedExpanded = true
    @State private var showsAllPinnedTasks = false
    @State private var isWorkspacesExpanded = true
    // Single-open accordion intent + per-query search-reveal dismissals.
    // All writes funnel through `setAccordionState` so the "Show more"
    // expansion of a drawer that just closed is always retired with it.
    @State private var accordion = WorkspaceSidebarAccordion.State()
    @State private var isPinnedDropTargeted = false
    // True from the moment a sidebar task drag begins until the mouse
    // button is released. An `onDrop(isTargeted:)` on the column proved
    // unreliable for revealing hidden chrome on macOS (it never flipped),
    // so the signal comes straight from the drag source: the task row's
    // `.onDrag` arms it, and a pressed-mouse-button watchdog clears it
    // when the session ends — drop, cancel, or release outside the app.
    @State private var isTaskDragInFlight = false
    @State private var taskDragWatchdog: Timer?
    @State private var isPinnedHeaderHovered = false
    @State private var isSchedulesExpanded = true
    @State private var isWorkspacesAddHovered = false
    @State private var isWorkspacesFilterHovered = false
    @State private var isWorkspacesHeaderHovered = false
    @State private var isSchedulesAddHovered = false
    @State private var isSchedulesHeaderHovered = false
    @State private var renamingTask: AgentTask?
    @State private var renameTaskText = ""
    @State private var expandedWorkspaceTaskLists: Set<UUID> = []
    @State private var isShowingNewTaskNudge = false
    @State private var isNewTaskNudgePulsing = false
    @AppStorage(AppStorageKeys.showStarredWorkspacesOnly) private var showStarredWorkspacesOnly = false
    @AppStorage(AppStorageKeys.hasSeenNewTaskNudge) private var hasSeenNewTaskNudge = false

    @State private var taskIndex = SidebarTaskIndex(tasks: [], searchText: "")
    @State private var allSchedules: [TaskSchedule] = []

    private var disclosureAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var fastHoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.10)
    }

    private func rebuildTaskIndex() {
        taskIndex = SidebarTaskIndex(tasks: tasks, searchText: searchText)
    }

    private func rebuildSchedules() {
        allSchedules = workspaces.flatMap(\.schedules).sorted { $0.name < $1.name }
    }

    // Lightweight fingerprint of task fields that the sidebar index cares about.
    // Avoids rebuilding the index when unrelated fields (output, tokens) change.
    private var sidebarTasksVersion: Int {
        SidebarTaskIndexInvalidation.signature(for: tasks, searchText: searchText)
    }

    private var schedulesVersion: Int {
        workspaces.reduce(into: 0) { acc, ws in
            acc &+= ws.schedules.count
        }
    }

    private var selectedWorkspaceHasNoTasks: Bool {
        guard let selectedWorkspace else { return false }
        return !tasks.contains { $0.workspace?.id == selectedWorkspace.id }
    }

    private var shouldShowNewTaskNudge: Bool {
        selectedWorkspace != nil && selectedWorkspaceHasNoTasks && !hasSeenNewTaskNudge
    }

    private var newTaskNudgePresentation: Binding<Bool> {
        Binding(
            get: { isShowingNewTaskNudge },
            set: { isPresented in
                if isPresented {
                    isShowingNewTaskNudge = true
                } else {
                    dismissNewTaskNudge()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top new task button
            if selectedWorkspace != nil {
                NewTaskButton(
                    isShowingNudge: isShowingNewTaskNudge,
                    isNudgePulsing: isNewTaskNudgePulsing,
                    reduceMotion: reduceMotion,
                    action: handleNewTaskButton
                )
                .keyboardShortcut("n", modifiers: .command)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .popover(isPresented: newTaskNudgePresentation, arrowEdge: .leading) {
                    NewTaskNudgePopover(onDismiss: dismissNewTaskNudge)
                }

                if let onNewApp {
                    Button(action: onNewApp) {
                        // Mirrors NewTaskButton's insets (12 outer + 12
                        // content) and 7pt glyph gap so the two commands
                        // read as one aligned column.
                        HStack(spacing: 7) {
                            Image(systemName: "square.grid.2x2")
                                .font(Stanford.ui(13, weight: .medium))
                            Text("New app")
                                .font(Stanford.ui(13, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .help("Create a Workspace App in App Studio (⌘⇧A)")
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pinnedSection(using: taskIndex)
                    unreadSection(using: taskIndex)
                    workspaceSection(using: taskIndex)
                    schedulesSection
                }
                .padding(.bottom, 12)
            }

            appAccessFooter
        }
        .onAppear {
            loadSidebarDisclosure()
            rebuildTaskIndex()
            rebuildSchedules()
            updateNewTaskNudge()
        }
        // Tear the drag watchdog down with the view: if the sidebar leaves
        // the hierarchy mid-drag (window close, split collapse) the
        // repeating timer must not outlive it.
        .onDisappear { endTaskDrag() }
        .onChange(of: sidebarTasksVersion) { rebuildTaskIndex() }
        .onChange(of: searchText) {
            rebuildTaskIndex()
            setAccordionState(WorkspaceSidebarAccordion.searchChanged(in: accordion))
        }
        .onChange(of: schedulesVersion) { rebuildSchedules() }
        .onChange(of: selectedWorkspace?.id) { handleSelectedWorkspaceChanged() }
        .onChange(of: selectedWorkspaceHasNoTasks) { updateNewTaskNudge() }
        .navigationTitle(selectedWorkspace?.name ?? "ASTRA")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SidebarTopToolbar(
                    showsWorkspaceActions: selectedWorkspace == nil,
                    onNewWorkspace: onNewWorkspace,
                    onImportWorkspace: onImportWorkspace
                )
            }
        }
        .accessibilityIdentifier("TaskSidebar")
        .alert("Rename Task", isPresented: Binding(
            get: { renamingTask != nil },
            set: { if !$0 { renamingTask = nil } }
        )) {
            TextField("Task name", text: $renameTaskText)
            Button("Cancel", role: .cancel) { renamingTask = nil }
            Button("Rename") {
                if let task = renamingTask, !renameTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    task.title = renameTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
                    task.updatedAt = Date()
                    WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                }
                renamingTask = nil
            }
        } message: {
            Text("Enter a new name for this task.")
        }
    }

    private var appAccessFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.35)
            AppAccessMenu()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .accessibilityIdentifier("AppAccessSidebarFooter")
    }

    // MARK: - Pinned Section

    private func pinnedSection(using taskIndex: SidebarTaskIndex) -> some View {
        let hasPinnedTasks = !taskIndex.pinnedTasks.isEmpty
        // With nothing pinned the section stays out of the rail entirely;
        // the dashed target materializes the moment a task drag begins
        // (source-signalled, so it cannot miss) and stays while the drag
        // hovers it.
        let showsEmptyDropTarget = !hasPinnedTasks && (isTaskDragInFlight || isPinnedDropTargeted)
        let visiblePinnedTasks = showsAllPinnedTasks
            ? taskIndex.pinnedTasks
            : Array(taskIndex.pinnedTasks.prefix(SidebarLeanPresentation.pinnedPreviewLimit))

        return VStack(alignment: .leading, spacing: 0) {
            if hasPinnedTasks {
                pinnedHeader(count: taskIndex.pinnedTasks.count)
            }

            if (isPinnedExpanded && hasPinnedTasks) || showsEmptyDropTarget {
                VStack(alignment: .leading, spacing: 2) {
                    if showsEmptyDropTarget {
                        pinnedEmptyDropTarget
                            .transition(.opacity)
                    } else {
                        ForEach(visiblePinnedTasks) { task in
                            pinnedTaskRow(for: task)
                        }

                        if taskIndex.pinnedTasks.count > visiblePinnedTasks.count {
                            sidebarShowMoreButton(
                                title: "Show \(taskIndex.pinnedTasks.count - visiblePinnedTasks.count) more",
                                action: {
                                    withAnimation(disclosureAnimation) {
                                        showsAllPinnedTasks = true
                                    }
                                }
                            )
                            .padding(.leading, 2)
                        }

                        if isPinnedDropTargeted {
                            pinnedInlineDropTarget
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                .padding(.top, hasPinnedTasks ? 0 : 8)
            }
        }
        .padding(.bottom, hasPinnedTasks || showsEmptyDropTarget ? 8 : 0)
        .animation(disclosureAnimation, value: showsEmptyDropTarget)
        .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
            endTaskDrag()
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                guard let data = data as? Data,
                      let idString = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: idString) else { return }
                DispatchQueue.main.async {
                    if let task = tasks.first(where: { $0.id == uuid }) {
                        withAnimation(disclosureAnimation) {
                            setPinned(true, for: task)
                        }
                    }
                }
            }
            return true
        }
    }

    private func pinnedHeader(count: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(disclosureAnimation) {
                    isPinnedExpanded.toggle()
                }
                persistSidebarDisclosure()
            } label: {
                HStack(spacing: 5) {
                    Text("Pinned")
                        .font(Stanford.caption(14))
                        .foregroundStyle(.secondary)
                    SidebarCountBadge(count: count)
                    Image(systemName: "chevron.right")
                        .font(Stanford.ui(9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isPinnedExpanded ? 90 : 0))
                        .opacity(isPinnedHeaderHovered ? 1 : 0)
                        .animation(disclosureAnimation, value: isPinnedExpanded)
                        .animation(hoverAnimation, value: isPinnedHeaderHovered)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isPinnedHeaderHovered = $0 }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var pinnedEmptyDropTarget: some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
        let dashStyle = StrokeStyle(
            lineWidth: isPinnedDropTargeted ? 1.25 : 1,
            lineCap: .round,
            dash: [3, 3]
        )

        return HStack(spacing: 7) {
            Image(systemName: isPinnedDropTargeted ? "pin.fill" : "arrow.down.doc")
                .font(Stanford.ui(11, weight: .medium))
                .foregroundStyle(isPinnedDropTargeted ? Stanford.poppy : Color.secondary.opacity(0.5))
                .frame(width: 14)
            Text(isPinnedDropTargeted ? "Drop to pin" : "Drag tasks here to pin")
                .font(Stanford.caption(12))
                .foregroundStyle(isPinnedDropTargeted ? Stanford.poppy : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(
                isPinnedDropTargeted
                    ? Stanford.poppy.opacity(0.08)
                    : Color.primary.opacity(0.025)
            )
        )
        .overlay(
            shape.strokeBorder(
                isPinnedDropTargeted
                    ? Stanford.poppy.opacity(0.55)
                    : Color.primary.opacity(Stanford.strokeRest),
                style: dashStyle
            )
        )
        .animation(disclosureAnimation, value: isPinnedDropTargeted)
    }

    private var pinnedInlineDropTarget: some View {
        HStack(spacing: 7) {
            Image(systemName: "pin.fill")
                .font(Stanford.ui(10, weight: .medium))
                .foregroundStyle(Stanford.poppy)
                .frame(width: 14)
            Text("Drop to pin")
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.poppy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.poppy.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
    }

    private func pinnedTaskRow(for task: AgentTask) -> some View {
        let isSelected = selectedTask?.id == task.id
        let isHovered = hoveredTaskID == task.id

        // Was a `Button { } .overlay { unpinButton }` with `.onHover` on
        // the outer button. When the cursor crossed onto the overlay,
        // the outer button's `.onHover` would fire `false` and then
        // `true` again as SwiftUI re-resolved the hit area, causing
        // `hoveredTaskID` to flap. The unpin button's opacity is bound
        // to that flap, so it blinked. ZStack siblings with `.onHover`
        // on the ZStack — the same shape used by `compactTaskRow` —
        // sees a single hover region across both children, so moving
        // between them no longer toggles the state.
        return ZStack(alignment: .trailing) {
            Button {
                selectedTask = task
            } label: {
                SidebarThreadRow(
                    task: task,
                    isSelected: isSelected,
                    isHovered: isHovered,
                    subtitle: task.workspace?.name,
                    showsPinIndicator: false,
                    showsTimestamp: false
                )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(disclosureAnimation) {
                    setPinned(false, for: task)
                }
            } label: {
                Image(systemName: "pin.slash.fill")
                    .font(Stanford.ui(10, weight: .medium))
                    .foregroundStyle(Stanford.poppy.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unpin")
            .padding(.trailing, 8)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(hoverAnimation, value: isHovered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { updateTaskHover($0, id: task.id) }
        .contextMenu {
            Button {
                withAnimation(disclosureAnimation) {
                    setPinned(false, for: task)
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }

            Divider()

            taskContextMenu(for: task)
        }
    }

    // MARK: - Unreads Section

    @ViewBuilder
    private func unreadSection(using taskIndex: SidebarTaskIndex) -> some View {
        if !taskIndex.unreadTasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                unreadHeader(count: taskIndex.unreadTasks.count)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(taskIndex.unreadTasks) { task in
                        unreadTaskRow(for: task)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 8)
        }
    }

    private func unreadHeader(count: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(Stanford.ui(6, weight: .medium))
                    .foregroundStyle(Stanford.cardinalRed)
                Text("Unreads")
                    .font(Stanford.caption(14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SidebarCountBadge(count: count)
        }
        .padding(.horizontal, 10)
        // 12pt keeps the header breathing when Unreads opens the rail (the
        // pinned section above it now renders nothing while empty).
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func unreadTaskRow(for task: AgentTask) -> some View {
        let isHovered = hoveredTaskID == task.id

        return ZStack(alignment: .trailing) {
            Button {
                selectedTask = task
            } label: {
                SidebarThreadRow(
                    task: task,
                    isSelected: selectedTask?.id == task.id,
                    isHovered: isHovered,
                    subtitle: task.workspace?.name
                )
            }
            .buttonStyle(.plain)

            taskOptionsMenu(for: task, isHovered: isHovered)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { updateTaskHover($0, id: task.id) }
        .contextMenu {
            taskContextMenu(for: task)
        }
    }

    // MARK: - Routines Section

    private var schedulesSection: some View {
        Section {
            if isSchedulesExpanded {
                if allSchedules.isEmpty {
                    // Empty state is now an actionable link instead of an
                    // inert "No routines yet" label. One line to learn:
                    // the section has an affordance.
                    Button {
                        onNewSchedule?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(Stanford.ui(10, weight: .medium))
                            Text("Add routine")
                                .font(Stanford.caption(12))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Create a routine")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                } else {
                    ForEach(allSchedules) { schedule in
                        Button {
                            if let ws = schedule.workspace {
                                selectedWorkspace = ws
                            }
                            onEditSchedule?(schedule)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(Stanford.ui(12))
                                    .foregroundStyle(schedule.isEnabled ? Stanford.lagunita : .secondary)
                                    .frame(width: 13, height: 13)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(schedule.name)
                                        .font(Stanford.ui(13))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(schedule.frequencySummary)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(Stanford.textSecondary)
                                            .lineLimit(1)
                                        if let ws = schedule.workspace {
                                            Text("·")
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(Stanford.textSecondary)
                                            Text(ws.name)
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(Stanford.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(height: Stanford.sidebarScheduleRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                            // Same hover chrome as task rows: routines were
                            // the one clickable row type with no hover
                            // feedback, which made them read as inert text.
                            .background(
                                RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                                    .fill(hoveredScheduleID == schedule.id ? Color.primary.opacity(0.052) : .clear)
                                    .animation(hoverAnimation, value: hoveredScheduleID == schedule.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { updateScheduleHover($0, id: schedule.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Button {
                    withAnimation(disclosureAnimation) {
                        isSchedulesExpanded.toggle()
                    }
                    persistSidebarDisclosure()
                } label: {
                    HStack(spacing: 5) {
                        Text("Routines")
                            .font(Stanford.caption(14))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isSchedulesExpanded ? 90 : 0))
                            .opacity(isSchedulesHeaderHovered ? 1 : 0)
                            .animation(disclosureAnimation, value: isSchedulesExpanded)
                            .animation(hoverAnimation, value: isSchedulesHeaderHovered)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isSchedulesHeaderHovered = $0 }

                Spacer()

                // Shares SectionAddIcon with the Workspaces header so the
                // two controls render byte-identical — the Menu-vs-Button
                // wrapper used to introduce a hairline layout shift.
                // Hidden while the empty state's "Add routine" row is on
                // screen: one visible add affordance per section at a time.
                if !allSchedules.isEmpty {
                    Button {
                        onNewSchedule?()
                    } label: {
                        SectionAddIcon(isHovered: isSchedulesAddHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { isSchedulesAddHovered = $0 }
                    .help("New routine")
                }
            }
            .padding(.horizontal, 10)
            // Extra top padding creates breathing room between the three
            // top-level sections (Pinned / Workspaces / Routines). Cheaper
            // than a divider and lets the eye find the section boundaries.
            .padding(.top, 20)
            .padding(.bottom, 4)
            .textCase(nil)
        }
    }

    // MARK: - Workspace Section

    private func visibleWorkspaces(using taskIndex: SidebarTaskIndex) -> [Workspace] {
        PerformanceTelemetry.measure(
            "sidebar_visible_workspaces",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_count": PerformanceTelemetryFields.count(tasks.count),
                "workspace_count": PerformanceTelemetryFields.count(workspaces.count),
                "search_active": PerformanceTelemetryFields.bool(!searchText.isEmpty)
            ],
            resultFields: { visibleWorkspaces in
                [
                    "visible_workspace_count": PerformanceTelemetryFields.count(visibleWorkspaces.count)
                ]
            }
        ) {
            WorkspaceSidebarFilter.visibleWorkspaces(
                workspaces,
                showStarredOnly: showStarredWorkspacesOnly,
                searchText: searchText,
                workspaceMatchesSearch: workspaceMatchesSearch
            ) { workspace in
                taskIndex.reviewTasks(
                    for: workspace,
                    matchingSearch: true,
                    workspaceMatchesSearch: false
                ).isEmpty == false || workspaceHasMatchingApp(workspace)
            }
        }
    }

    private func workspaceSection(using taskIndex: SidebarTaskIndex) -> some View {
        let visibleWorkspaces = visibleWorkspaces(using: taskIndex)

        return Section {
            if isWorkspacesExpanded && visibleWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspaceEmptyTitle)
                        .font(Stanford.body(14))
                    Text(workspaceEmptySubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else if isWorkspacesExpanded {
                ForEach(visibleWorkspaces) { workspace in
                    workspaceListRow(for: workspace, using: taskIndex)
                }
            }
        } header: {
            HStack(spacing: 10) {
                Button {
                    withAnimation(disclosureAnimation) {
                        isWorkspacesExpanded.toggle()
                    }
                    persistSidebarDisclosure()
                } label: {
                    HStack(spacing: 5) {
                        Text("Workspaces")
                            .font(Stanford.caption(14))
                            .foregroundStyle(.secondary)
                        if !visibleWorkspaces.isEmpty {
                            SidebarCountBadge(count: visibleWorkspaces.count)
                        }
                        // Hover-only disclosure cue. Lives next to the
                        // label rather than at the right edge so the
                        // chevron clearly belongs to the section name.
                        // Rotation tracks expansion state; opacity
                        // tracks header hover so the section reads as
                        // pure typography at rest but signals
                        // "collapsible" the moment the cursor lands.
                        Image(systemName: "chevron.right")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isWorkspacesExpanded ? 90 : 0))
                            .opacity(isWorkspacesHeaderHovered ? 1 : 0)
                            .animation(disclosureAnimation, value: isWorkspacesExpanded)
                            .animation(hoverAnimation, value: isWorkspacesHeaderHovered)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isWorkspacesHeaderHovered = $0 }

                Spacer()

                Button {
                    withAnimation(disclosureAnimation) {
                        showStarredWorkspacesOnly.toggle()
                    }
                } label: {
                    Image(systemName: showStarredWorkspacesOnly ? "star.fill" : "star")
                        .font(Stanford.ui(13, weight: .medium))
                        .foregroundStyle(showStarredWorkspacesOnly ? Stanford.lagunita : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Stanford.lagunita.opacity(isWorkspacesFilterHovered || showStarredWorkspacesOnly ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isWorkspacesFilterHovered = $0 }
                .help(showStarredWorkspacesOnly ? "Show all workspaces" : "Show starred only")
                .accessibilityLabel(showStarredWorkspacesOnly ? "Show all workspaces" : "Show starred only")

                // Direct-action Button — identical wrapper and visual
                // chrome to the Routines header's + button. Previously a
                // Menu with New / Import choices, but Menu's button style
                // introduces press-animation chrome that plain Button
                // doesn't, so the two could never render byte-identical.
                //
                // Import Workspace now lives in the File menu
                // (ASTRAApp.swift) — where macOS users expect to
                // find import / export anyway.
                Button {
                    onNewWorkspace?()
                } label: {
                    SectionAddIcon(isHovered: isWorkspacesAddHovered)
                }
                .buttonStyle(.plain)
                .onHover { isWorkspacesAddHovered = $0 }
                .help("New Workspace")
            }
            .padding(.horizontal, 10)
            // See Routines section — 20pt top creates visual rhythm
            // between top-level sections (Pinned / Workspaces / Routines).
            .padding(.top, 20)
            .padding(.bottom, 4)
            .textCase(nil)
        }
    }

    /// One List row per workspace that bundles the folder header and
    /// (when expanded) its task children. Putting the children inside a
    /// single List row — instead of as sibling rows — lets SwiftUI's
    /// `.transition` modifier actually fire: List on macOS is backed by
    /// NSTableView which animates its own row insertions and ignores
    /// SwiftUI transitions on row-level children. By collapsing the
    /// workspace + tasks into one row, the conditional that toggles
    /// the tasks lives inside the row's view tree, where transitions
    /// behave like they do everywhere else.
    ///
    /// Child task rows keep a compact workspace-relative indent, but avoid the
    /// permanent guide rail that used to consume title width and dominate the
    /// scan path. The row surface still spans the same width as the parent
    /// workspace row so hover and selection chrome stay stable.
    @ViewBuilder
    private func workspaceListRow(for workspace: Workspace, using taskIndex: SidebarTaskIndex) -> some View {
        let isExpanded = isWorkspaceExpanded(workspace, using: taskIndex)
        let workspaceTasks = tasksForWorkspace(workspace, using: taskIndex)
        let hasTasks = !workspaceTasks.isEmpty
        let hasAny = hasAnyTask(in: workspace, using: taskIndex)
        let isShowingAll = expandedWorkspaceTaskLists.contains(workspace.id)
        let visibleTasks = SidebarWorkspaceTaskList.visibleTasks(workspaceTasks, isShowingAll: isShowingAll)
        let hiddenTaskCount = SidebarWorkspaceTaskList.hiddenTaskCount(
            totalTasks: workspaceTasks.count,
            visibleTasks: visibleTasks.count
        )
        let workspaceAppRows = appsForWorkspace(workspace)
        let showGroupLabels = !workspaceAppRows.isEmpty && hasTasks  // label groups only when both exist

        VStack(spacing: 0) {
            workspaceRow(for: workspace, using: taskIndex)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Apps sit atop the drawer, above the collapsible chat list, so they never hide behind "Show more".
                    if showGroupLabels { SidebarGroupLabel(text: "Apps") }
                    ForEach(workspaceAppRows) { app in
                        SidebarWorkspaceAppRow(
                            app: app,
                            isSelected: selectedWorkspaceApp?.id == app.id,
                            contentLeadingPadding: SidebarLeanPresentation.childTaskContentLeadingPadding,
                            onOpen: { onOpenWorkspaceApp?(app) }
                        )
                    }
                    if !hasTasks && !hasAny && workspaceAppRows.isEmpty {
                        emptyWorkspaceRow(for: workspace)
                    } else if hasTasks {
                        if showGroupLabels { SidebarGroupLabel(text: "Tasks") }
                        ForEach(visibleTasks) { task in
                            compactTaskRow(
                                for: task,
                                contentLeadingPadding: SidebarLeanPresentation.childTaskContentLeadingPadding
                            )
                        }
                        if hiddenTaskCount > 0 {
                            sidebarShowMoreButton(
                                title: "Show \(hiddenTaskCount) more",
                                action: {
                                    withAnimation(disclosureAnimation) {
                                        _ = expandedWorkspaceTaskLists.insert(workspace.id)
                                    }
                                }
                            )
                            .padding(.leading, 2)
                        }
                    }
                }
                .padding(.leading, SidebarLeanPresentation.childTaskListLeadingPadding)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Pure opacity in both directions. Earlier `.move(edge:
                // .top)` slid tasks vertically as the container's height
                // changed, so the rows visually crossed through the
                // workspace row above them — distracting both on expand
                // and collapse. With opacity-only the tasks fade in
                // place and the row's height does the heavy lifting,
                // giving the cleanest "drawer opens / drawer closes"
                // read without the layered motion.
                .transition(.opacity)
            }
        }
        // Clips children that briefly extend past the row's natural
        // bounds during the collapse animation — without this, tasks
        // can render outside the row's footprint while the container
        // height shrinks, making them appear to bleed into the
        // workspace row below.
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        // Symmetric 10pt horizontal margin gives the row's selection
        // background equal breathing room on both sides instead of
        // the previous 2/8 asymmetry, which made the right edge of
        // the rounded bg almost touch the sidebar's right border.
        // Matches the inset modern macOS sidebars (Notes, Reminders)
        // use for selection chrome.
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .animation(disclosureAnimation, value: isExpanded)
    }

    @State private var hoveredWorkspaceID: UUID?
    @State private var hoveredTaskID: UUID?
    @State private var hoveredScheduleID: UUID?

    // `.onHover` exit events are not ordered against the next row's enter
    // event: clearing unconditionally lets a stale exit from the previous
    // row wipe the hover the new row just claimed, which reads as chrome
    // flicker while tracking down the rail. Only the current owner clears.
    private func updateWorkspaceHover(_ hovering: Bool, id: UUID) {
        if hovering {
            hoveredWorkspaceID = id
        } else if hoveredWorkspaceID == id {
            hoveredWorkspaceID = nil
        }
    }

    private func updateTaskHover(_ hovering: Bool, id: UUID) {
        if hovering {
            hoveredTaskID = id
        } else if hoveredTaskID == id {
            hoveredTaskID = nil
        }
    }

    private func updateScheduleHover(_ hovering: Bool, id: UUID) {
        if hovering {
            hoveredScheduleID = id
        } else if hoveredScheduleID == id {
            hoveredScheduleID = nil
        }
    }

    private var workspaceEmptyTitle: String {
        if showStarredWorkspacesOnly {
            return searchText.isEmpty ? "No starred workspaces" : "No starred matches"
        }
        return searchText.isEmpty ? "No workspaces yet" : "No workspace matches"
    }

    private var workspaceEmptySubtitle: String {
        if showStarredWorkspacesOnly {
            return "Star a workspace or turn off the filter."
        }
        return searchText.isEmpty ? "Create or import a workspace to start." : "Try a different search."
    }

    private func workspaceRow(for workspace: Workspace, using taskIndex: SidebarTaskIndex) -> some View {
        let isExpanded = isWorkspaceExpanded(workspace, using: taskIndex)
        let isHovered = hoveredWorkspaceID == workspace.id
        let isSelected = selectedWorkspace?.id == workspace.id && selectedTask == nil
        let workspaceTaskCount = tasksForWorkspace(workspace, using: taskIndex).count
        // Closed drawers still owe the user a liveness signal: with the
        // accordion keeping one drawer open, running work elsewhere would
        // otherwise be invisible. Expanded drawers show the spinner on the
        // task row itself, so the badge would just double the signal there.
        let runningTaskCount = isExpanded ? 0 : taskIndex.runningTaskCount(in: workspace)

        return HStack(alignment: .center, spacing: 7) {
            Button {
                withAnimation(disclosureAnimation) {
                    toggleWorkspaceOpenState(workspace, using: taskIndex)
                }
            } label: {
                HStack(spacing: 7) {
                    // Rest-state disclosure: expansion used to be signalled
                    // only by folder-icon fill, which read as two *kinds* of
                    // folder rather than two states. The chevron stays
                    // visible (tertiary) so rows advertise that they expand,
                    // and brightens with the rest of the row on hover.
                    Image(systemName: "chevron.right")
                        .font(Stanford.ui(9, weight: .semibold))
                        .foregroundStyle(isHovered ? .secondary : .tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: SidebarLeanPresentation.workspaceDisclosureChevronWidth, height: 22)
                        .animation(disclosureAnimation, value: isExpanded)

                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .font(Stanford.ui(13, weight: .medium))
                        .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                        .frame(width: 17, height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(workspace.name)" : "Expand \(workspace.name)")

            Button {
                withAnimation(disclosureAnimation) {
                    toggleWorkspaceOpenState(workspace, using: taskIndex)
                }
            } label: {
                HStack(spacing: 0) {
                    Text(workspace.name)
                        .font(Stanford.body(15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isExpanded ? "Collapse \(workspace.name)" : "Expand \(workspace.name)")
            .accessibilityHint("Expands or collapses the workspace.")
            .help(workspace.name)

            workspaceRowActions(
                for: workspace,
                isHovered: isHovered,
                taskCount: workspaceTaskCount,
                runningTaskCount: runningTaskCount
            )
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: Stanford.sidebarWorkspaceRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { updateWorkspaceHover($0, id: workspace.id) }
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(workspaceRowFill(isSelected: isSelected, isHovered: isHovered))
                .animation(hoverAnimation, value: isSelected)
                .animation(fastHoverAnimation, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(workspaceRowStroke(isSelected: isSelected, isHovered: isHovered), lineWidth: 1)
                .animation(hoverAnimation, value: isSelected)
                .animation(fastHoverAnimation, value: isHovered)
        )
        .contextMenu {
            Button {
                startNewTask(in: workspace)
            } label: {
                Label("New Task", systemImage: "square.and.pencil")
            }

            Button {
                toggleStarred(for: workspace)
            } label: {
                Label(workspace.isStarred ? "Unstar Workspace" : "Star Workspace", systemImage: workspace.isStarred ? "star.slash" : "star")
            }

            Divider()

            Button {
                selectedWorkspace = workspace
                onEditWorkspace?(workspace)
            } label: {
                Label("Workspace Details", systemImage: "info.circle")
            }

            Button {
                onRenameWorkspace?(workspace)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDeleteWorkspace?(workspace)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// Resolves the workspace row's background tint. Selection takes
    /// precedence over hover. Selection uses `Stanford.selectionFill`
    /// (lagunita @ 12%) so the active row reads as on-brand instead of a
    /// neutral gray; hover is a quiet primary tint at 7% — visible
    /// enough to read as "armed" against the soft sidebar background
    /// without crowding the selected row's teal.
    private func workspaceRowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Stanford.selectionFill }
        if isHovered { return Color.primary.opacity(0.09) }
        return .clear
    }

    private func workspaceRowStroke(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.12) }
        return .clear
    }

    private func workspaceRowActions(
        for workspace: Workspace,
        isHovered: Bool,
        taskCount: Int,
        runningTaskCount: Int
    ) -> some View {
        WorkspaceRowActions(
            workspace: workspace,
            isRowHovered: isHovered,
            taskCount: taskCount,
            runningTaskCount: runningTaskCount,
            onNewTask: { startNewTask(in: workspace) },
            onToggleStarred: { toggleStarred(for: workspace) },
            onEdit: {
                selectedWorkspace = workspace
                onEditWorkspace?(workspace)
            },
            onRename: { onRenameWorkspace?(workspace) },
            onDelete: { onDeleteWorkspace?(workspace) }
        )
    }

    private func startNewTask(in workspace: Workspace) {
        openWorkspace(workspace)
        onNewTask()
    }

    private func openWorkspace(_ workspace: Workspace) {
        selectedTask = nil
        selectedWorkspace = workspace
        ensureWorkspaceExpanded(workspace)
    }

    private func toggleWorkspaceOpenState(_ workspace: Workspace, using taskIndex: SidebarTaskIndex) {
        let wasExpanded = isWorkspaceExpanded(workspace, using: taskIndex)
        selectedTask = nil
        selectedWorkspace = workspace
        setAccordionState(WorkspaceSidebarAccordion.toggling(
            workspace.id,
            in: accordion,
            wasExpanded: wasExpanded
        ))
    }

    /// The one writer of the accordion state. Closing a drawer — explicitly
    /// or by opening another — also retires its "Show more" expansion so it
    /// reopens compact.
    private func setAccordionState(_ newState: WorkspaceSidebarAccordion.State) {
        guard newState != accordion else { return }
        if let previousOpen = accordion.openWorkspaceID, previousOpen != newState.openWorkspaceID {
            expandedWorkspaceTaskLists.remove(previousOpen)
        }
        accordion = newState
        persistSidebarDisclosure()
    }

    private func loadSidebarDisclosure() {
        let state = TaskSidebarDisclosureStore.load()
        isPinnedExpanded = state.isPinnedExpanded
        isWorkspacesExpanded = state.isWorkspacesExpanded
        isSchedulesExpanded = state.isSchedulesExpanded
        // Nothing persisted (first run, or the accordion migration) seeds
        // the open drawer from the restored selection, so launch shows the
        // working context instead of a wall of closed folders.
        accordion.openWorkspaceID = state.openWorkspaceID ?? selectedWorkspace?.id
    }

    private func persistSidebarDisclosure() {
        TaskSidebarDisclosureStore.save(TaskSidebarDisclosureState(
            isPinnedExpanded: isPinnedExpanded,
            isWorkspacesExpanded: isWorkspacesExpanded,
            isSchedulesExpanded: isSchedulesExpanded,
            openWorkspaceID: accordion.openWorkspaceID
        ))
    }

    private func sidebarShowMoreButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Stanford.caption(12).weight(.medium))
                Image(systemName: "chevron.down")
                    .font(Stanford.ui(9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyWorkspaceRow(for workspace: Workspace) -> some View {
        Button {
            selectedWorkspace = workspace
            onNewTask()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(Stanford.ui(10, weight: .medium))
                Text("Add task")
                    .font(Stanford.caption(12).weight(.medium))
            }
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Stanford.lagunita.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactTaskRow(
        for task: AgentTask,
        attemptCount: Int = 1,
        contentLeadingPadding: CGFloat = 12
    ) -> some View {
        let isHovered = hoveredTaskID == task.id

        return ZStack(alignment: .trailing) {
            Button {
                selectedTask = task
            } label: {
                SidebarThreadRow(
                    task: task,
                    isSelected: selectedTask?.id == task.id,
                    isHovered: isHovered,
                    contentLeadingPadding: contentLeadingPadding,
                    attemptCount: attemptCount
                )
            }
            .buttonStyle(.plain)

            taskOptionsMenu(for: task, includePinToggle: true, isHovered: isHovered)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { updateTaskHover($0, id: task.id) }
        .onDrag {
            beginTaskDrag()
            return NSItemProvider(object: task.id.uuidString as NSString)
        } preview: {
            // Drag chip — was a thin material rectangle. Now sits on
            // `cardBackground` with a hairline border + soft shadow so
            // it reads as a proper "card lifted off the surface" rather
            // than a translucent overlay.
            let shape = RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
            HStack(spacing: 7) {
                Image(systemName: "pin.fill")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(Stanford.poppy)
                Text(task.title)
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(shape.fill(Stanford.cardBackground))
            .overlay(shape.strokeBorder(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
        }
        .contextMenu {
            Button {
                withAnimation(disclosureAnimation) {
                    togglePinned(for: task)
                }
            } label: {
                Label(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin")
            }

            Divider()

            taskContextMenu(for: task)
        }
    }

    private func taskOptionsMenu(
        for task: AgentTask,
        includePinToggle: Bool = false,
        isHovered: Bool
    ) -> some View {
        Menu {
            if includePinToggle {
                Button {
                    withAnimation(disclosureAnimation) {
                        togglePinned(for: task)
                    }
                } label: {
                    Label(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin")
                }

                Divider()
            }

            taskContextMenu(for: task)
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 24, alignment: .center)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
        .animation(hoverAnimation, value: isHovered)
        .help("Task options")
    }

    private func isWorkspaceExpanded(_ workspace: Workspace, using taskIndex: SidebarTaskIndex) -> Bool {
        WorkspaceSidebarAccordion.isExpanded(
            workspaceID: workspace.id,
            state: accordion,
            isSearchActive: !searchText.isEmpty
        ) {
            !tasksForWorkspace(workspace, matchingSearch: true, using: taskIndex).isEmpty ||
                workspaceHasMatchingApp(workspace)
        }
    }

    private func tasksForWorkspace(
        _ workspace: Workspace,
        matchingSearch: Bool = false,
        using taskIndex: SidebarTaskIndex
    ) -> [AgentTask] {
        taskIndex.reviewTasks(
            for: workspace,
            matchingSearch: matchingSearch,
            workspaceMatchesSearch: workspaceMatchesSearch(workspace)
        )
    }

    private func hasAnyTask(in workspace: Workspace, using taskIndex: SidebarTaskIndex) -> Bool {
        taskIndex.hasAnyTask(in: workspace)
    }

    /// The apps belonging to a workspace, name-sorted and search-filtered like chat rows.
    /// Empty when no open handler is wired, so the rows never appear inert.
    private func appsForWorkspace(_ workspace: Workspace) -> [WorkspaceApp] {
        guard onOpenWorkspaceApp != nil else { return [] }
        return SidebarWorkspaceAppFilter.apps(
            workspaceApps,
            in: workspace,
            searchText: searchText,
            workspaceMatchesSearch: workspaceMatchesSearch(workspace)
        )
    }

    private func workspaceHasMatchingApp(_ workspace: Workspace) -> Bool {
        onOpenWorkspaceApp != nil && SidebarWorkspaceAppFilter.hasMatch(workspaceApps, in: workspace, searchText: searchText)
    }

    private func workspaceMatchesSearch(_ workspace: Workspace) -> Bool {
        workspace.name.localizedCaseInsensitiveContains(searchText) ||
            workspace.primaryPath.localizedCaseInsensitiveContains(searchText)
    }

    @ViewBuilder
    private func taskContextMenu(for task: AgentTask) -> some View {
        Button {
            renameTaskText = task.title
            renamingTask = task
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        if task.status != .running {
            Button {
                if let onToggleDone {
                    onToggleDone(task)
                } else {
                    withAnimation(disclosureAnimation) {
                        task.isDone.toggle()
                        task.updatedAt = Date()
                        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                    }
                }
            } label: {
                Label(
                    task.isDone ? "Reopen task" : TaskPresentationState.closeTaskActionTitle,
                    systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark.circle"
                )
            }
        }

        if task.status == .queued {
            Button {
                onRunTask(task)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
        }

        if task.status == .running {
            Button {
                onCancelTask?(task)
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
        }

        if task.status == .failed || task.status == .cancelled || task.status == .budgetExceeded {
            Button {
                onRetryTask?(task)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Button(role: .destructive) {
            onDeleteTask?(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Arms the drag-in-flight flag and a watchdog that clears it once the
    /// left mouse button is released. `.onDrag` has no end callback and the
    /// drag session swallows mouse-up events, so polling the pressed-button
    /// mask is the one signal that covers drop, cancel, and release outside
    /// the window alike.
    private func beginTaskDrag() {
        taskDragWatchdog?.invalidate()
        withAnimation(disclosureAnimation) {
            isTaskDragInFlight = true
        }
        taskDragWatchdog = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
            DispatchQueue.main.async { endTaskDrag() }
        }
    }

    private func endTaskDrag() {
        taskDragWatchdog?.invalidate()
        taskDragWatchdog = nil
        withAnimation(disclosureAnimation) {
            isTaskDragInFlight = false
        }
    }

    private func togglePinned(for task: AgentTask) {
        setPinned(!task.isPinned, for: task)
    }

    private func setPinned(_ isPinned: Bool, for task: AgentTask) {
        guard task.isPinned != isPinned else { return }
        task.isPinned = isPinned
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func toggleStarred(for workspace: Workspace) {
        if selectedWorkspace?.id == workspace.id {
            ensureWorkspaceExpanded(workspace)
        }
        workspace.isStarred.toggle()
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func handleSelectedWorkspaceChanged() {
        // Accordion: the open drawer follows the workspace you switch to,
        // wherever the switch originates (row click, new workspace, schedule
        // row, App Studio). The drawer animates because `workspaceListRow`
        // animates on `isExpanded` itself, not only on toggle clicks.
        // `selectionChanged` (not `selecting`) so this deferred echo cannot
        // reopen a drawer the user just collapsed.
        setAccordionState(WorkspaceSidebarAccordion.selectionChanged(selectedWorkspace?.id, in: accordion))
        updateNewTaskNudge()
    }

    private func ensureWorkspaceExpanded(_ workspace: Workspace) {
        setAccordionState(WorkspaceSidebarAccordion.selecting(workspace.id, in: accordion))
    }

    private func handleNewTaskButton() {
        if isShowingNewTaskNudge {
            dismissNewTaskNudge()
        }
        onNewTask()
    }

    private func updateNewTaskNudge() {
        guard shouldShowNewTaskNudge else {
            isShowingNewTaskNudge = false
            isNewTaskNudgePulsing = false
            return
        }

        DispatchQueue.main.async {
            guard shouldShowNewTaskNudge else { return }
            isShowingNewTaskNudge = true
            if !reduceMotion {
                isNewTaskNudgePulsing = true
            }
        }
    }

    private func dismissNewTaskNudge() {
        guard isShowingNewTaskNudge || !hasSeenNewTaskNudge else { return }
        isShowingNewTaskNudge = false
        isNewTaskNudgePulsing = false
        hasSeenNewTaskNudge = true
    }
}

/// Sidebar's primary CTA. Stays quiet at rest (lagunita ink on a soft
/// tinted ground), warms on hover, and inherits the nudge ring when the
/// workspace is empty. Was inline in `body` — pulled out so the styling
/// rationale lives in one place and the body reads as layout, not paint.
private struct NewTaskButton: View {
    let isShowingNudge: Bool
    let isNudgePulsing: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    private let cornerRadius: CGFloat = Stanford.radiusSmall + 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(Stanford.ui(13, weight: .semibold))
                Text("New task")
                    .font(Stanford.ui(14, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 12)
            .padding(.vertical, SidebarLeanPresentation.newTaskVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 1))
            .overlay(nudgeRing(shape: shape))
            .contentShape(shape)
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pressEvents(onPress: { isPressed = true }, onRelease: { isPressed = false })
    }

    private var fillColor: Color {
        Stanford.lagunita.opacity(
            isHovered
                ? SidebarLeanPresentation.newTaskHoverFillOpacity
                : SidebarLeanPresentation.newTaskRestFillOpacity
        )
    }

    private var strokeColor: Color {
        Stanford.lagunita.opacity(isHovered ? 0.18 : 0.10)
    }

    @ViewBuilder
    private func nudgeRing(shape: RoundedRectangle) -> some View {
        if isShowingNudge {
            shape
                .stroke(Stanford.lagunita.opacity(0.36), lineWidth: 2)
                .scaleEffect(isNudgePulsing ? 1.05 : 1.0)
                .opacity(isNudgePulsing ? 0.15 : 0.70)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.95).repeatForever(autoreverses: true),
                    value: isNudgePulsing
                )
        }
    }
}

private extension View {
    /// Lightweight press tracker for plain buttons. SwiftUI's `.plain`
    /// `ButtonStyle` strips the press configuration, so we read it back
    /// via a drag gesture with zero distance.
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}

/// Trailing accessory cluster on each workspace row. At rest it shows
/// navigational metadata (task count + star). On hover that same slot
/// becomes the row's controls, so hidden settings/new-task icons do not
/// steal extra width from the workspace title.
private struct WorkspaceRowActions: View {
    let workspace: Workspace
    let isRowHovered: Bool
    let taskCount: Int
    /// Live tasks inside a *closed* drawer — callers pass 0 for expanded
    /// rows, where the task rows' own spinners already carry the signal.
    let runningTaskCount: Int
    let onNewTask: () -> Void
    let onToggleStarred: () -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isEllipsisHovered = false
    @State private var isNewTaskHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.10)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            metadata
                .opacity(isRowHovered ? 0 : 1)
                .accessibilityHidden(isRowHovered)

            actions
                .opacity(isRowHovered ? 1 : 0)
                .allowsHitTesting(isRowHovered)
                .accessibilityHidden(!isRowHovered)
        }
        .frame(width: SidebarLeanPresentation.workspaceRowTrailingSlotWidth, alignment: .trailing)
        .animation(hoverAnimation, value: isRowHovered)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            if runningTaskCount > 0 {
                WorkspaceRunningIndicator(count: runningTaskCount)
            }

            if taskCount > 0 {
                // Pill badge — same chrome as the section-header counts —
                // so counts and relative timestamps stop sharing one
                // visual voice at the rail's right edge: badge = how
                // many, plain text = how old.
                SidebarCountBadge(count: taskCount)
                    .fixedSize()
                    .accessibilityLabel("\(taskCount) tasks")
            }

            if workspace.isStarred {
                Image(systemName: "star.fill")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 22)
                    .accessibilityLabel("Starred")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Menu {
                Button(action: onToggleStarred) {
                    Label(
                        workspace.isStarred ? "Unstar Workspace" : "Star Workspace",
                        systemImage: workspace.isStarred ? "star.slash" : "star"
                    )
                }

                Divider()

                Button(action: onEdit) {
                    Label("Workspace Details", systemImage: "info.circle")
                }
                Button(action: onRename) {
                    Label("Rename", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                accessoryGlyph("ellipsis", size: 14, weight: .semibold, isHovered: isEllipsisHovered)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Stanford.lagunita)
            .fixedSize()
            .onHover { isEllipsisHovered = $0 }
            .help("Workspace options")
            .accessibilityLabel("Options for \(workspace.name)")

            Button(action: onNewTask) {
                accessoryGlyph("square.and.pencil", size: 13, weight: .medium, isHovered: isNewTaskHovered)
            }
            .buttonStyle(.plain)
            .onHover { isNewTaskHovered = $0 }
            .help("Start new chat in Astra")
            .accessibilityLabel("Start new chat in \(workspace.name)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func accessoryGlyph(_ symbol: String, size: CGFloat, weight: Font.Weight, isHovered: Bool) -> some View {
        Image(systemName: symbol)
            .font(Stanford.ui(size, weight: weight))
            .foregroundStyle(Stanford.lagunita)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall - 1, style: .continuous)
                    .fill(Stanford.lagunita.opacity(isHovered ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .animation(hoverAnimation, value: isHovered)
    }
}

private struct NewTaskNudgePopover: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)

                Text("Start here")
                    .font(Stanford.body(14).weight(.semibold))
                    .foregroundStyle(Stanford.black)
            }

            Text("Create your first task in this workspace from the New task button.")
                .font(Stanford.body(13))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(Stanford.cardBackground)
    }
}

/// Quiet liveness signal on a collapsed workspace row: a small lagunita dot
/// with a slow breathing pulse, meaning "an agent is working inside this
/// closed drawer". Lagunita matches the running spinner's tint so "teal =
/// running" stays one vocabulary, distinct from the cardinal unread dot.
/// Under Reduce Motion the dot holds steady — presence alone carries it.
private struct WorkspaceRunningIndicator: View {
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var label: String {
        count == 1 ? "1 task running" : "\(count) tasks running"
    }

    var body: some View {
        Circle()
            .fill(Stanford.lagunita)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.35 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .frame(width: 10, height: 22)
            .onAppear { isPulsing = !reduceMotion }
            .help(label)
            .accessibilityLabel(label)
    }
}

private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Stanford.caption(11).weight(.medium))
            // AA-floor grey (see Stanford.textSecondary): system .secondary
            // dips under 4.5:1 at these sizes.
            .foregroundStyle(Stanford.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, Stanford.sidebarBadgeHorizontalPadding)
            .frame(minWidth: Stanford.sidebarBadgeMinWidth, minHeight: Stanford.sidebarBadgeHeight)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.sidebarBadgeCornerRadius, style: .continuous))
    }
}

/// Visual used inside every sidebar section-header "+" affordance
/// (Workspaces, Routines). Calm secondary glyph that lights up lagunita
/// on hover — reserves the cardinal-red brand hue for CTAs like
/// "+ New task", and avoids the "red filled circle = notification"
/// confusion we had before.
///
/// Callers wrap this in either `Button` (direct action) or `Menu`
/// (multi-choice), then attach `.onHover` to drive `isHovered`. Keeping
/// the hover state outside lets both Button and Menu paths render
/// byte-identical visuals.
private struct SectionAddIcon: View {
    let isHovered: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    var body: some View {
        Image(systemName: "plus")
            .font(Stanford.ui(12, weight: .medium))
            .foregroundStyle(isHovered ? Color.white : Color.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall - 1, style: .continuous)
                    .fill(isHovered ? Stanford.lagunita : Color.clear)
            )
            .contentShape(Rectangle())
            .animation(hoverAnimation, value: isHovered)
    }
}

private struct SidebarThreadRow: View {
    let task: AgentTask
    let isSelected: Bool
    /// Hover signal driven by the parent's `hoveredTaskID` instead of an
    /// internal `@State`. Two separate hover sources (one inner, one
    /// outer) used to race — the three-dots overlay would appear (parent's
    /// hover fired) while the inner timestamp stayed visible (inner
    /// hover hadn't fired yet), which is what produced the overlap. One
    /// source of truth fixes the race.
    let isHovered: Bool
    var contentLeadingPadding: CGFloat = 0
    var attemptCount: Int = 1
    var subtitle: String?
    /// Hidden when the row is rendered inside the Pinned section — the
    /// section already implies "pinned" and the unpin overlay button
    /// covers the same gutter on hover, so showing the glyph there
    /// would just add noise. Pinned tasks are excluded from their
    /// workspace's own list entirely (`SidebarTaskIndex` groups them into
    /// `pinnedTasks` instead of the per-workspace groups), so in practice
    /// this glyph now only fires in the Unreads row, for a task that is
    /// both pinned and unread.
    var showsPinIndicator: Bool = true
    /// Hidden inside the Pinned section: the same task already shows
    /// its timestamp in the Unreads row when it's also unread, and
    /// dropping it here keeps the right gutter clear for the unpin
    /// overlay (which previously had to fight the timestamp for the same
    /// x-position) and gives pinned titles more room before they truncate.
    var showsTimestamp: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.10)
    }

    private var metadataAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private var titleWeight: Font.Weight {
        if task.shouldShowUnread { return .semibold }
        return isSelected ? .medium : .regular
    }

    private var metadataWeight: Font.Weight {
        task.shouldShowUnread ? .semibold : .regular
    }

    private var showIcon: Bool {
        SidebarThreadRowLayout.showsStatusIcon(
            for: task.status,
            isUnread: task.shouldShowUnread,
            isHovered: isHovered,
            isSelected: isSelected
        )
    }

    private var isActionableStatus: Bool {
        SidebarThreadRowLayout.isActionableStatus(task.status)
    }

    /// True when the row's glyph is the unread dot: a finished result the
    /// user hasn't looked at yet. Actionable states keep their own glyphs —
    /// they already say "needs me" more specifically than a dot could.
    private var showsUnreadDot: Bool {
        task.shouldShowUnread && !isActionableStatus
    }

    /// Names the leading glyph for tooltips and VoiceOver — the status text
    /// no longer renders as a second line, so the glyph has to speak.
    private var statusGlyphDescription: String {
        if showsUnreadDot { return "Unread result" }
        switch task.status {
        case .running:        return "Running"
        case .pendingUser:    return "Needs input"
        case .failed:         return "Needs retry"
        case .budgetExceeded: return "Budget hit"
        case .cancelled:      return "Cancelled"
        case .completed:      return "Completed"
        case .queued:         return "Queued"
        case .draft:          return "Draft"
        }
    }

    private var titlePresentation: Formatters.SidebarTaskTitlePresentation {
        Formatters.sidebarTaskTitlePresentation(task.title)
    }

    var body: some View {
        HStack(alignment: .center, spacing: SidebarThreadRowLayout.statusIconTitleSpacing) {
            if showIcon {
                statusIcon
                    .frame(
                        width: SidebarThreadRowLayout.statusIconWidth,
                        height: SidebarThreadRowLayout.statusIconWidth
                    )
                    .opacity(isActionableStatus && !isSelected && !isHovered ? 0.6 : 1)
                    .padding(.leading, contentLeadingPadding)
                    .help(statusGlyphDescription)
                    .accessibilityLabel(statusGlyphDescription)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    SidebarTaskTitleText(
                        presentation: titlePresentation,
                        font: Stanford.ui(SidebarThreadRowLayout.titleFontSize, weight: titleWeight)
                    )
                    .layoutPriority(1)

                    if attemptCount > 1 {
                        Text("\(attemptCount) attempts")
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(Stanford.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize()
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, showIcon ? 0 : contentLeadingPadding)

            Spacer(minLength: 6)

            // Right-side metadata is hidden on
            // hover so the three-dots context-menu overlay (added by
            // `compactTaskRow`) can render without overlapping text.
            // Keep the layout in place (no width shift) by using opacity,
            // not conditional removal.
            if showsTimestamp {
                HStack(spacing: 5) {
                    if task.isPinned && showsPinIndicator {
                        // Tells the user "this row also appears in the
                        // Pinned section" — reachable only from the
                        // Unreads row (pinned tasks are excluded from
                        // their workspace's own list, so they no longer
                        // render there too).
                        Image(systemName: "pin.fill")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.58))
                            .help("Pinned")
                            .accessibilityLabel("Pinned")
                    }
                    Text(relativeTime(task.updatedAt))
                        .font(Stanford.caption(11).weight(metadataWeight))
                        .foregroundStyle(task.shouldShowUnread ? Color.primary : Stanford.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 24, alignment: .trailing)
                }
                .opacity(isHovered ? 0 : 1)
                // Fades the timestamp out at the same rate as the
                // hover-only overlay buttons (`unpin`, `taskOptionsMenu`)
                // fade in, so the right gutter swaps smoothly instead of
                // one element snapping while the other animates.
                .animation(metadataAnimation, value: isHovered)
            }
        }
        .padding(.horizontal, SidebarThreadRowLayout.rowHorizontalPadding)
        .padding(.vertical, 5)
        .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .fill(rowFill)
                .animation(selectionAnimation, value: isSelected)
                .animation(hoverAnimation, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
                .animation(selectionAnimation, value: isSelected)
                .animation(hoverAnimation, value: isHovered)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var rowFill: Color {
        if isSelected { return Stanford.selectionFill }
        if isHovered { return Color.primary.opacity(0.052) }
        return .clear
    }

    private var rowStroke: Color {
        if isSelected { return Color.primary.opacity(0.10) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }

    @ViewBuilder
    private var statusIcon: some View {
        if showsUnreadDot {
            // Same dot the Unreads section header wears, so "red dot =
            // unseen result" stays one vocabulary across the rail.
            Image(systemName: "circle.fill")
                .font(Stanford.ui(6, weight: .medium))
                .foregroundStyle(Stanford.cardinalRed)
        } else {
            statusGlyph
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch task.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(Stanford.lagunita)
                .scaleEffect(0.8)
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.completed)
        case .pendingUser:
            Image(systemName: "person.crop.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.pendingUser)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.failed)
        case .budgetExceeded:
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.poppy)
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock")
                .font(Stanford.ui(12))
                .foregroundStyle(.secondary)
        case .draft:
            Image(systemName: "pencil")
                .font(Stanford.ui(11))
                .foregroundStyle(.secondary)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        if interval < 2592000 { return "\(Int(interval / 604800))w" }
        return "\(Int(interval / 2592000))mo"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
