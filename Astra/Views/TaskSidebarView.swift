import SwiftUI
import SwiftData

struct TaskSidebarContainerView: View {
    @Query(sort: \AgentTask.queuePosition) private var tasks: [AgentTask]

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
    var onShowLogs: (() -> Void)?
    var onShowDashboard: (() -> Void)?
    var onDeleteWorkspace: ((Workspace) -> Void)?
    var onRenameWorkspace: ((Workspace) -> Void)?
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    @Binding var isSearchActive: Bool

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
            onShowLogs: onShowLogs,
            onShowDashboard: onShowDashboard,
            onDeleteWorkspace: onDeleteWorkspace,
            onRenameWorkspace: onRenameWorkspace,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            isSearchActive: $isSearchActive
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

private struct SidebarTaskAttemptGroup: Identifiable {
    let task: AgentTask
    let attemptCount: Int

    var id: UUID { task.id }
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
    var onShowLogs: (() -> Void)?
    var onShowDashboard: (() -> Void)?
    var onDeleteWorkspace: ((Workspace) -> Void)?
    var onRenameWorkspace: ((Workspace) -> Void)?
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    @Binding var isSearchActive: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isPinnedExpanded = true
    @State private var isWorkspacesExpanded = true
    @State private var expandedWorkspaceIDs: Set<UUID> = []
    @State private var collapsedWorkspaceIDs: Set<UUID> = []
    @State private var isPinnedDropTargeted = false
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

    private func rebuildTaskIndex() {
        taskIndex = SidebarTaskIndex(tasks: tasks, searchText: searchText)
    }

    private func rebuildSchedules() {
        allSchedules = workspaces.flatMap(\.schedules).sorted { $0.name < $1.name }
    }

    // Lightweight fingerprint of task fields that the sidebar index cares about.
    // Avoids rebuilding the index when unrelated fields (output, tokens) change.
    private var sidebarTasksVersion: Int {
        tasks.reduce(into: 0) { acc, task in
            acc ^= task.id.hashValue
            acc ^= task.status.rawValue.hashValue
            acc ^= task.isPinned ? 1 : 0
            acc ^= task.isDone ? 2 : 0
            acc ^= task.shouldShowUnread ? 4 : 0
            acc &+= Int(task.updatedAt.timeIntervalSince1970)
        }
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
            }

            pinnedDock(using: taskIndex)
            unreadDock(using: taskIndex)

            // Hairline split between the docks (Pinned / Unread) and the
            // List below. A standard Divider() ships at NSColor.separator,
            // which renders heavy under our soft sidebar background — the
            // 0.5pt rule at strokeRest reads as a quiet boundary instead
            // of a hard line.
            Rectangle()
                .fill(Color.primary.opacity(Stanford.strokeRest))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)

            // Was `List { ... }.listStyle(.sidebar)`. Switched to a
            // ScrollView + LazyVStack because List on macOS is backed by
            // NSTableView, which manages its own row insertion/removal
            // animations and ignores SwiftUI `.transition` modifiers on
            // its rows. That made the workspace expand/collapse animation
            // impossible to drive through SwiftUI — tasks snapped in even
            // inside `withAnimation`. With a plain LazyVStack the tasks
            // are regular SwiftUI views again, transitions fire, and the
            // workspace row stays put while children animate.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    workspaceSection(using: taskIndex)
                    schedulesSection
                }
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            rebuildTaskIndex()
            rebuildSchedules()
            updateNewTaskNudge()
        }
        .onChange(of: sidebarTasksVersion) { rebuildTaskIndex() }
        .onChange(of: searchText) { rebuildTaskIndex() }
        .onChange(of: schedulesVersion) { rebuildSchedules() }
        .onChange(of: selectedWorkspace?.id) { updateNewTaskNudge() }
        .onChange(of: selectedWorkspaceHasNoTasks) { updateNewTaskNudge() }
        .navigationTitle(selectedWorkspace?.name ?? "ASTRA")
        .toolbar {
            if selectedWorkspace == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { isSearchActive.toggle() } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)

                    Menu {
                        Button(action: { onNewWorkspace?() }) {
                            Label("New Workspace", systemImage: "folder.badge.plus")
                        }
                        Button(action: { onImportWorkspace?() }) {
                            Label("Import Workspace", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add Workspace", systemImage: "folder.badge.plus")
                    }
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { isSearchActive.toggle() } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)
                }
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
                    try? modelContext.save()
                }
                renamingTask = nil
            }
        } message: {
            Text("Enter a new name for this task.")
        }
    }

    // MARK: - Pinned Section

    private func pinnedDock(using taskIndex: SidebarTaskIndex) -> some View {
        let hasPinnedTasks = !taskIndex.pinnedTasks.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            if hasPinnedTasks {
                pinnedHeader
            }

            if isPinnedExpanded || !hasPinnedTasks {
                ScrollView(.vertical, showsIndicators: taskIndex.pinnedTasks.count > 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !hasPinnedTasks {
                            pinnedEmptyDropTarget
                        } else {
                            ForEach(taskIndex.pinnedTasks) { task in
                                pinnedTaskRow(for: task)
                            }

                            if isPinnedDropTargeted {
                                pinnedInlineDropTarget
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
                .frame(height: pinnedContentHeight(using: taskIndex))
                .padding(.top, hasPinnedTasks ? 0 : 8)
            }
        }
        .padding(.bottom, 8)
        .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                guard let data = data as? Data,
                      let idString = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: idString) else { return }
                DispatchQueue.main.async {
                    if let task = tasks.first(where: { $0.id == uuid }) {
                        withAnimation {
                            setPinned(true, for: task)
                        }
                    }
                }
            }
            return true
        }
    }

    private var pinnedHeader: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    isPinnedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Pinned")
                        .font(Stanford.caption(14))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 16)
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
        .animation(.easeInOut(duration: 0.18), value: isPinnedDropTargeted)
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

    private func pinnedContentHeight(using taskIndex: SidebarTaskIndex) -> CGFloat {
        guard isPinnedExpanded else { return 0 }
        if taskIndex.pinnedTasks.isEmpty { return 36 }

        let rowHeight = Stanford.sidebarThreadRowHeight + 2
        let taskHeight = CGFloat(taskIndex.pinnedTasks.count) * rowHeight
        let dropTargetHeight: CGFloat = isPinnedDropTargeted ? 30 : 0
        return min(taskHeight + dropTargetHeight + 2, 220)
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
                withAnimation {
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in hoveredTaskID = hovering ? task.id : nil }
        .contextMenu {
            Button {
                withAnimation {
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
    private func unreadDock(using taskIndex: SidebarTaskIndex) -> some View {
        if !taskIndex.unreadTasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                unreadHeader(count: taskIndex.unreadTasks.count)

                ScrollView(.vertical, showsIndicators: taskIndex.unreadTasks.count > 3) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(taskIndex.unreadTasks) { task in
                            unreadTaskRow(for: task)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
                .frame(height: unreadContentHeight(using: taskIndex))
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
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func unreadContentHeight(using taskIndex: SidebarTaskIndex) -> CGFloat {
        let rowHeight = Stanford.sidebarThreadRowHeight + 2
        let taskHeight = CGFloat(taskIndex.unreadTasks.count) * rowHeight
        return min(taskHeight + 2, 156)
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
        .onHover { hovering in hoveredTaskID = hovering ? task.id : nil }
        .contextMenu {
            taskContextMenu(for: task)
        }
    }

    @ViewBuilder
    private func statusIconView(for task: AgentTask) -> some View {
        switch task.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.completed)
        case .pendingUser:
            Image(systemName: "person.crop.circle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.pendingUser)
        case .failed, .budgetExceeded:
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.failed)
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
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let ws = schedule.workspace {
                                            Text("·")
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(.secondary)
                                            Text(ws.name)
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(.secondary)
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
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        isSchedulesExpanded.toggle()
                    }
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
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSchedulesExpanded)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSchedulesHeaderHovered)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isSchedulesHeaderHovered = $0 }

                Spacer()

                // Shares SectionAddIcon with the Workspaces header so the
                // two controls render byte-identical — the Menu-vs-Button
                // wrapper used to introduce a hairline layout shift.
                Button {
                    onNewSchedule?()
                } label: {
                    SectionAddIcon(isHovered: isSchedulesAddHovered)
                }
                .buttonStyle(.plain)
                .onHover { isSchedulesAddHovered = $0 }
                .help("New Routine")
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
            ).isEmpty == false
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        isWorkspacesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("Workspaces")
                            .font(Stanford.caption(14))
                            .foregroundStyle(.secondary)
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
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isWorkspacesExpanded)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isWorkspacesHeaderHovered)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isWorkspacesHeaderHovered = $0 }

                Spacer()

                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
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
    /// The leading inset (12pt) on the tasks VStack restores the visual
    /// indent the old `.listRowInsets(leading: 14)` provided — the
    /// outer row already pays 2pt of leading inset, so 12pt extra
    /// reaches the same 14pt total.
    @ViewBuilder
    private func workspaceListRow(for workspace: Workspace, using taskIndex: SidebarTaskIndex) -> some View {
        let isExpanded = isWorkspaceExpanded(workspace, using: taskIndex)
        let workspaceTasks = tasksForWorkspace(workspace, using: taskIndex)
        let workspaceTaskGroups = groupedTaskAttempts(workspaceTasks)
        let hasTasks = !workspaceTasks.isEmpty
        let hasAny = hasAnyTask(in: workspace, using: taskIndex)
        let isShowingAll = expandedWorkspaceTaskLists.contains(workspace.id)
        let visibleTaskGroups = isShowingAll ? workspaceTaskGroups : Array(workspaceTaskGroups.prefix(6))

        VStack(spacing: 0) {
            workspaceRow(for: workspace, using: taskIndex)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if !hasTasks && !hasAny {
                        emptyWorkspaceRow(for: workspace)
                    } else if hasTasks {
                        ForEach(visibleTaskGroups) { group in
                            compactTaskRow(for: group.task, attemptCount: group.attemptCount)
                        }
                        if workspaceTaskGroups.count > visibleTaskGroups.count {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    _ = expandedWorkspaceTaskLists.insert(workspace.id)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text("Show \(workspaceTaskGroups.count - visibleTaskGroups.count) more")
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
                            // Show More sat at leading 24 in old listRowInsets
                            // (vs tasks at 14). Keep that 10pt extra indent so
                            // the link reads as a tertiary affordance under
                            // the task list, not as another task.
                            .padding(.leading, 10)
                        }
                    }
                }
                .padding(.leading, 12)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: isExpanded)
    }

    @State private var hoveredWorkspaceID: UUID?
    @State private var hoveredTaskID: UUID?

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

        return HStack(alignment: .center, spacing: 7) {
            // Folder icon doubles as the expand/collapse affordance —
            // the `folder` ↔ `folder.fill` swap carries the state, and
            // clicking it toggles expansion. Dropped the leading
            // chevron entirely to match the simplified header style
            // (no glyphs, no disclosure indicators); the folder fill
            // change + the row's task children below are the only
            // expansion cues now.
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    toggleWorkspaceExpansion(workspace, using: taskIndex)
                }
            } label: {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(Stanford.ui(13, weight: .medium))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                    .frame(width: 17, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(workspace.name)" : "Expand \(workspace.name)")

            // Name: smart select + expand
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    if isExpanded && isSelected {
                        // Already open and selected → collapse
                        toggleWorkspaceExpansion(workspace, using: taskIndex)
                    } else if !isExpanded {
                        // Collapsed → expand and select
                        collapsedWorkspaceIDs.remove(workspace.id)
                        expandedWorkspaceIDs.insert(workspace.id)
                        selectedWorkspace = workspace
                        selectedTask = nil
                    } else {
                        // Expanded but not selected → just select
                        selectedWorkspace = workspace
                        selectedTask = nil
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    Text(workspace.name)
                        .font(Stanford.body(15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if workspace.isStarred {
                        Image(systemName: "star.fill")
                            .font(Stanford.ui(10, weight: .semibold))
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.leading, 6)
                            .accessibilityLabel("Starred")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workspace.name)

            workspaceRowActions(for: workspace, isHovered: isHovered)
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: Stanford.sidebarWorkspaceRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in hoveredWorkspaceID = hovering ? workspace.id : nil }
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(workspaceRowFill(isSelected: isSelected, isHovered: isHovered))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(workspaceRowStroke(isSelected: isSelected, isHovered: isHovered), lineWidth: 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovered)
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
        if isSelected { return Stanford.lagunita.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.12) }
        return .clear
    }

    private func workspaceRowActions(for workspace: Workspace, isHovered: Bool) -> some View {
        WorkspaceRowActions(
            workspace: workspace,
            isRowHovered: isHovered,
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
        selectedWorkspace = workspace
        selectedTask = nil
        collapsedWorkspaceIDs.remove(workspace.id)
        expandedWorkspaceIDs.insert(workspace.id)
        onNewTask()
    }

    private func groupedTaskAttempts(_ tasks: [AgentTask]) -> [SidebarTaskAttemptGroup] {
        var buckets: [String: [AgentTask]] = [:]
        var orderedKeys: [String] = []

        for task in tasks {
            let key = retryGroupingKey(for: task)
            if buckets[key] == nil {
                orderedKeys.append(key)
            }
            buckets[key, default: []].append(task)
        }

        return orderedKeys.compactMap { key in
            guard let attempts = buckets[key], !attempts.isEmpty else { return nil }
            let latestAttempt = attempts.max { $0.updatedAt < $1.updatedAt } ?? attempts[0]
            return SidebarTaskAttemptGroup(task: latestAttempt, attemptCount: attempts.count)
        }
    }

    private func retryGroupingKey(for task: AgentTask) -> String {
        task.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\(?attempt\\s+\\d+\\)?\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\(?retry\\s+\\d+\\)?\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func compactTaskRow(for task: AgentTask, attemptCount: Int = 1) -> some View {
        let isHovered = hoveredTaskID == task.id

        return ZStack(alignment: .trailing) {
            Button {
                selectedTask = task
            } label: {
                SidebarThreadRow(
                    task: task,
                    isSelected: selectedTask?.id == task.id,
                    isHovered: isHovered,
                    attemptCount: attemptCount
                )
            }
            .buttonStyle(.plain)

            taskOptionsMenu(for: task, includePinToggle: true, isHovered: isHovered)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in hoveredTaskID = hovering ? task.id : nil }
        .onDrag {
            NSItemProvider(object: task.id.uuidString as NSString)
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
                withAnimation {
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
                    withAnimation {
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
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .help("Task options")
    }

    private func isWorkspaceExpanded(_ workspace: Workspace, using taskIndex: SidebarTaskIndex) -> Bool {
        if collapsedWorkspaceIDs.contains(workspace.id) {
            return false
        }

        return selectedWorkspace?.id == workspace.id ||
            expandedWorkspaceIDs.contains(workspace.id) ||
            (!searchText.isEmpty && !tasksForWorkspace(workspace, matchingSearch: true, using: taskIndex).isEmpty)
    }

    private func toggleWorkspaceExpansion(_ workspace: Workspace, using taskIndex: SidebarTaskIndex) {
        if isWorkspaceExpanded(workspace, using: taskIndex) {
            expandedWorkspaceIDs.remove(workspace.id)
            collapsedWorkspaceIDs.insert(workspace.id)
            expandedWorkspaceTaskLists.remove(workspace.id)
        } else {
            collapsedWorkspaceIDs.remove(workspace.id)
            expandedWorkspaceIDs.insert(workspace.id)
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
                    withAnimation {
                        task.isDone.toggle()
                        task.updatedAt = Date()
                        try? modelContext.save()
                    }
                }
            } label: {
                Label(task.isDone ? "Reopen" : "Mark as Done", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark.circle")
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

    private func togglePinned(for task: AgentTask) {
        setPinned(!task.isPinned, for: task)
    }

    private func setPinned(_ isPinned: Bool, for task: AgentTask) {
        guard task.isPinned != isPinned else { return }
        task.isPinned = isPinned
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func toggleStarred(for workspace: Workspace) {
        workspace.isStarred.toggle()
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
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

    private let cornerRadius: CGFloat = Stanford.radiusMedium

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(Stanford.ui(14, weight: .semibold))
                Text("New task")
                    .font(Stanford.ui(15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
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
        Stanford.lagunita.opacity(isHovered ? 0.11 : 0.075)
    }

    private var strokeColor: Color {
        Stanford.lagunita.opacity(isHovered ? 0.22 : 0.14)
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

/// Trailing accessory cluster on each workspace row: ellipsis menu +
/// quick "new task" button. Was inlined and used a permanent
/// `lagunita.opacity(0.07)` pill on the ellipsis, which read as an
/// always-armed control. New treatment matches `SectionAddIcon` —
/// transparent at rest, lagunita tint on individual hover — so the row
/// feels calm until you move the cursor over a specific affordance.
private struct WorkspaceRowActions: View {
    let workspace: Workspace
    let isRowHovered: Bool
    let onNewTask: () -> Void
    let onToggleStarred: () -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isEllipsisHovered = false
    @State private var isNewTaskHovered = false

    var body: some View {
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
        .frame(width: 52, alignment: .trailing)
        .opacity(isRowHovered ? 1 : 0)
        .allowsHitTesting(isRowHovered)
        .accessibilityHidden(!isRowHovered)
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
            .animation(.easeOut(duration: 0.10), value: isHovered)
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

private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Stanford.caption(11).weight(.medium))
            .foregroundStyle(.secondary)
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
            .animation(.easeOut(duration: 0.12), value: isHovered)
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
    var attemptCount: Int = 1
    var subtitle: String?
    /// Hidden when the row is rendered inside the Pinned section — the
    /// section already implies "pinned" and the unpin overlay button
    /// covers the same gutter on hover, so showing the glyph there
    /// would just add noise.
    var showsPinIndicator: Bool = true
    /// Hidden inside the Pinned section: the same task already shows
    /// its timestamp in its workspace row, and dropping it here keeps
    /// the right gutter clear for the unpin overlay (which previously
    /// had to fight the timestamp for the same x-position) and gives
    /// pinned titles more room before they truncate.
    var showsTimestamp: Bool = true

    private var titleWeight: Font.Weight {
        if task.shouldShowUnread { return .semibold }
        return isSelected ? .medium : .regular
    }

    private var metadataWeight: Font.Weight {
        task.shouldShowUnread ? .semibold : .regular
    }

    private var showIcon: Bool {
        isSelected || isHovered || isActionableStatus
    }

    private var isActionableStatus: Bool {
        switch task.status {
        case .running, .pendingUser, .failed, .budgetExceeded:
            return true
        default:
            return false
        }
    }

    /// Inline chip surfaced next to the timestamp when the task isn't in a
    /// quiet state. Draft / completed fall through to nil so the row is
    /// title + time only — keeps the right gutter scannable.
    private var statusLabel: String? {
        switch task.status {
        case .running:        "Running"
        case .pendingUser:    "Needs input"
        case .queued:         "Queued"
        case .failed:         "Needs retry"
        case .budgetExceeded: "Budget hit"
        case .cancelled:      "Cancelled"
        case .draft, .completed: nil
        }
    }

    private var displayTitle: String {
        Formatters.shortenIdentifierTokens(task.title)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            statusIcon
                .frame(width: 14, height: 14)
                .opacity(showIcon ? (isActionableStatus && !isSelected && !isHovered ? 0.6 : 1) : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(displayTitle)
                        .font(Stanford.ui(14, weight: titleWeight))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if attemptCount > 1 {
                        Text("\(attemptCount) attempts")
                            .font(Stanford.caption(10).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize()
                    }
                }

                if let secondaryText {
                    Text(secondaryText)
                        .font(Stanford.caption(11))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Right-side metadata is hidden on
            // hover so the three-dots context-menu overlay (added by
            // `compactTaskRow`) can render without overlapping text.
            // Keep the layout in place (no width shift) by using opacity,
            // not conditional removal.
            if showsTimestamp {
                HStack(spacing: 5) {
                    if task.isPinned && showsPinIndicator {
                        // Tells the user "this row is also up top in the
                        // Pinned dock" — pinned tasks render twice (once
                        // in Pinned, once under their workspace), and
                        // without this glyph the workspace appearance
                        // looks like a duplicate.
                        Image(systemName: "pin.fill")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(Stanford.lagunita.opacity(0.55))
                            .help("Pinned")
                            .accessibilityLabel("Pinned")
                    }
                    Text(relativeTime(task.updatedAt))
                        .font(Stanford.caption(11).weight(metadataWeight))
                        .foregroundStyle(task.shouldShowUnread ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 24, alignment: .trailing)
                }
                .opacity(isHovered ? 0 : 1)
                // Fades the timestamp out at the same rate as the
                // hover-only overlay buttons (`unpin`, `taskOptionsMenu`)
                // fade in, so the right gutter swaps smoothly instead of
                // one element snapping while the other animates.
                .animation(.easeOut(duration: 0.14), value: isHovered)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .fill(rowFill)
                .animation(.easeOut(duration: 0.12), value: isSelected)
                .animation(.easeOut(duration: 0.10), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
                .animation(.easeOut(duration: 0.12), value: isSelected)
                .animation(.easeOut(duration: 0.10), value: isHovered)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var rowFill: Color {
        if isSelected { return Stanford.selectionFill }
        if isHovered { return Color.primary.opacity(0.09) }
        return .clear
    }

    private var rowStroke: Color {
        if isSelected { return Stanford.lagunita.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.12) }
        return .clear
    }

    private var secondaryText: String? {
        subtitle ?? statusLabel
    }

    private var secondaryTextColor: Color {
        guard subtitle == nil else { return .secondary }
        switch task.status {
        case .running:
            return Stanford.lagunita.opacity(0.82)
        case .pendingUser, .budgetExceeded:
            return Stanford.poppy.opacity(0.84)
        case .failed:
            return Stanford.cardinalRed.opacity(0.84)
        case .cancelled, .queued, .draft, .completed:
            return .secondary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
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

// MARK: - Search Panel Overlay

struct SearchPanelOverlayContainer: View {
    @Query(sort: \AgentTask.queuePosition) private var tasks: [AgentTask]

    let workspaces: [Workspace]
    @Binding var selectedTask: AgentTask?
    @Binding var selectedWorkspace: Workspace?
    @Binding var isActive: Bool

    var body: some View {
        SearchPanelOverlay(
            tasks: tasks,
            workspaces: workspaces,
            selectedTask: $selectedTask,
            selectedWorkspace: $selectedWorkspace,
            isActive: $isActive
        )
    }
}

struct SearchPanelOverlay: View {
    let tasks: [AgentTask]
    let workspaces: [Workspace]
    @Binding var selectedTask: AgentTask?
    @Binding var selectedWorkspace: Workspace?
    @Binding var isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    @State private var selectedIndex = 0

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) {
            isActive = false
            searchText = ""
        }
    }

    private var recentTasks: [AgentTask] {
        Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(9))
    }

    private var filteredTasks: [AgentTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recentTasks }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.goal.localizedCaseInsensitiveContains(query) ||
            ($0.workspace?.name.localizedCaseInsensitiveContains(query) ?? false) ||
            ($0.workspace?.primaryPath.localizedCaseInsensitiveContains(query) ?? false)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(12)
        .map { $0 }
    }

    private var filteredWorkspaces: [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return workspaces.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.primaryPath.localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func toggleStarred(for workspace: Workspace) {
        workspace.isStarred.toggle()
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func togglePinned(for task: AgentTask) {
        task.isPinned.toggle()
        task.updatedAt = Date()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    var body: some View {
        ZStack {
            Stanford.scrim.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(Stanford.ui(15))
                        .foregroundStyle(.secondary)

                    TextField("Search tasks and workspaces", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Stanford.ui(16))
                        .focused($isFocused)
                        .onSubmit {
                            if let task = filteredTasks.first {
                                selectedTask = task
                                dismiss()
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                // Results
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !filteredWorkspaces.isEmpty {
                            Text("Workspaces")
                                .font(Stanford.caption(11).weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            ForEach(filteredWorkspaces) { ws in
                                HStack(spacing: 6) {
                                    Button {
                                        selectedWorkspace = ws
                                        selectedTask = nil
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "folder.fill")
                                                .font(Stanford.ui(13))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 18)
                                            Text(ws.name)
                                                .font(Stanford.ui(14))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(ws.name)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        toggleStarred(for: ws)
                                    } label: {
                                        Image(systemName: ws.isStarred ? "star.fill" : "star")
                                            .font(Stanford.ui(13, weight: .semibold))
                                            .foregroundStyle(ws.isStarred ? Stanford.lagunita : .secondary)
                                            .frame(width: 26, height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(ws.isStarred ? "Unstar workspace" : "Star workspace")
                                    .accessibilityLabel(ws.isStarred ? "Unstar \(ws.name)" : "Star \(ws.name)")
                                }
                                .padding(.leading, 16)
                                .padding(.trailing, 12)
                                .padding(.vertical, 7)
                            }
                        }

                        Text(searchText.isEmpty ? "Recent tasks" : "Tasks")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, filteredWorkspaces.isEmpty ? 10 : 14)
                            .padding(.bottom, 4)

                        ForEach(Array(filteredTasks.enumerated()), id: \.element.id) { idx, task in
                            HStack(spacing: 6) {
                                Button {
                                    selectedTask = task
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "bubble.left")
                                            .font(Stanford.ui(13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        Text(Formatters.shortenIdentifierTokens(task.title))
                                            .font(Stanford.ui(14, weight: task.shouldShowUnread ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(task.title)
                                        Spacer()
                                        if let ws = task.workspace {
                                            Text(Formatters.shortenIdentifierTokens(ws.name, maxTokenLength: 24, keepEachSide: 8))
                                                .font(Stanford.caption(11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .help(ws.name)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    togglePinned(for: task)
                                } label: {
                                    Image(systemName: task.isPinned ? "pin.fill" : "pin")
                                        .font(Stanford.ui(13, weight: .semibold))
                                        .foregroundStyle(task.isPinned ? Stanford.lagunita : .secondary)
                                        .frame(width: 26, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(task.isPinned ? "Unpin task" : "Pin task")
                                .accessibilityLabel(task.isPinned ? "Unpin \(task.title)" : "Pin \(task.title)")
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 12)
                            .padding(.vertical, 7)
                            .background(idx == selectedIndex ? Color.primary.opacity(0.06) : .clear)
                        }

                        if filteredTasks.isEmpty && filteredWorkspaces.isEmpty {
                            HStack {
                                Spacer()
                                Text("No results found")
                                    .font(Stanford.ui(13))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 350)
            }
            .frame(width: 520)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
            .onExitCommand { dismiss() }
            .onAppear { isFocused = true }
            .onChange(of: searchText) { _, _ in selectedIndex = 0 }
        }
        .transition(.opacity)
    }
}
