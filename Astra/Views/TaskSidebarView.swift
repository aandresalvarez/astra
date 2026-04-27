import SwiftUI
import SwiftData

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
    @State private var isSchedulesAddHovered = false
    @State private var renamingTask: AgentTask?
    @State private var renameTaskText = ""
    @State private var expandedWorkspaceTaskLists: Set<UUID> = []

    private var visibleWorkspaces: [Workspace] {
        let sorted = workspaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            workspaceMatchesSearch($0) ||
            tasksForWorkspace($0, matchingSearch: true).isEmpty == false
        }
    }

    private var pinnedTasks: [AgentTask] {
        tasks
            .filter { $0.isPinned && isSidebarReviewTask($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var allSchedules: [TaskSchedule] {
        workspaces.flatMap(\.schedules).sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top new task button — lightweight inline style
            if selectedWorkspace != nil {
                Button(action: onNewTask) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(Stanford.ui(15, weight: .medium))
                        Text("New task")
                            .font(Stanford.ui(16, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Stanford.lagunita)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .padding(.top, 6)
            }

            List {
                pinnedSection
                workspaceSection
                schedulesSection
            }
            .listStyle(.sidebar)
        }
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

                    if taskQueue.isProcessing || tasks.contains(where: { $0.status == .queued }) {
                        Button(action: onRunQueue) {
                            Label(taskQueue.isProcessing ? "Stop Queue" : "Run Queue", systemImage: taskQueue.isProcessing ? "stop.circle" : "play.fill")
                        }
                    }
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

    private var pinnedSection: some View {
        Section {
            if isPinnedExpanded {
                if pinnedTasks.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: isPinnedDropTargeted ? "pin.fill" : "arrow.down.doc")
                            .font(Stanford.ui(11))
                            .foregroundStyle(isPinnedDropTargeted ? Stanford.poppy : Color.secondary.opacity(0.4))
                        Text(isPinnedDropTargeted ? "Drop to pin" : "Drag tasks here to pin")
                            .font(Stanford.caption(12))
                            .foregroundStyle(isPinnedDropTargeted ? Stanford.poppy : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isPinnedDropTargeted ? Stanford.poppy.opacity(0.08) : .clear)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isPinnedDropTargeted ? Stanford.poppy.opacity(0.5) : Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: isPinnedDropTargeted ? 1.5 : 1, dash: [5, 3]))
                    )
                    .animation(.easeInOut(duration: 0.15), value: isPinnedDropTargeted)
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 10))
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(pinnedTasks) { task in
                        pinnedTaskRow(for: task)
                    }
                    if isPinnedDropTargeted {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill")
                                .font(Stanford.ui(10))
                                .foregroundStyle(Stanford.poppy)
                            Text("Drop to pin")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.poppy)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Stanford.poppy.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 10))
                        .listRowBackground(Color.clear)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        } header: {
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
            .padding(.horizontal, 8)
            .padding(.top, 20)
            .padding(.bottom, 4)
            .textCase(nil)
        }
        .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
                guard let data = data as? Data,
                      let idString = String(data: data, encoding: .utf8),
                      let uuid = UUID(uuidString: idString) else { return }
                DispatchQueue.main.async {
                    if let task = tasks.first(where: { $0.id == uuid }) {
                        withAnimation {
                            task.isPinned = true
                            try? modelContext.save()
                        }
                    }
                }
            }
            return true
        }
    }

    private func pinnedTaskRow(for task: AgentTask) -> some View {
        let isSelected = selectedTask?.id == task.id
        return Button {
            selectedTask = task
        } label: {
            SidebarThreadRow(
                task: task,
                isSelected: isSelected,
                isHovered: hoveredTaskID == task.id,
                subtitle: task.workspace?.name
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredTaskID = hovering ? task.id : nil }
        .overlay(alignment: .trailing) {
            if hoveredTaskID == task.id {
                Button {
                    withAnimation {
                        task.isPinned = false
                        try? modelContext.save()
                    }
                } label: {
                    Image(systemName: "pin.slash.fill")
                        .font(Stanford.ui(10))
                        .foregroundStyle(Stanford.poppy.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unpin")
                .padding(.trailing, 4)
                .transition(.opacity)
            }
        }
        .contextMenu {
            Button {
                withAnimation {
                    task.isPinned = false
                    try? modelContext.save()
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }

            Divider()

            taskContextMenu(for: task)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
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

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        if interval < 2592000 { return "\(Int(interval / 604800))w" }
        return "\(Int(interval / 2592000))mo"
    }

    // MARK: - Schedules Section

    private var schedulesSection: some View {
        Section {
            if isSchedulesExpanded {
                if allSchedules.isEmpty {
                    // Empty state is now an actionable link instead of an
                    // inert "No schedules yet" label. One line to learn:
                    // the section has an affordance.
                    Button {
                        onNewSchedule?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(Stanford.ui(10, weight: .medium))
                            Text("Add schedule")
                                .font(Stanford.caption(12))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Create a recurring task")
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 10))
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(allSchedules) { schedule in
                        Button {
                            if let ws = schedule.workspace {
                                selectedWorkspace = ws
                            }
                            onEditSchedule?(schedule)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: schedule.isEnabled ? "clock.fill" : "clock")
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
                        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 10))
                        .listRowBackground(Color.clear)
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
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(Stanford.ui(12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text("Schedules")
                            .font(Stanford.caption(14))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                .help("New Schedule")
            }
            .padding(.horizontal, 8)
            // Extra top padding creates breathing room between the three
            // top-level sections (Pinned / Workspaces / Schedules). Cheaper
            // than a divider and lets the eye find the section boundaries.
            .padding(.top, 20)
            .padding(.bottom, 4)
            .textCase(nil)
        }
    }

    // MARK: - Workspace Section

    private var workspaceSection: some View {
        Section {
            if isWorkspacesExpanded && visibleWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No workspaces yet")
                        .font(Stanford.body(14))
                    Text("Create or import a workspace to start.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else if isWorkspacesExpanded {
                ForEach(visibleWorkspaces) { workspace in
                    workspaceRow(for: workspace)
                    if isWorkspaceExpanded(workspace) {
                        workspaceTaskGroups(for: workspace)
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        isWorkspacesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Workspaces")
                            .font(Stanford.caption(14))
                            .foregroundStyle(.secondary)
                        Image(systemName: isWorkspacesExpanded ? "chevron.down" : "chevron.right")
                            .font(Stanford.ui(9, weight: .medium))
                            .foregroundStyle(.quaternary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                // Direct-action Button — identical wrapper and visual
                // chrome to the Schedules header's + button. Previously a
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
            .padding(.horizontal, 8)
            // See Schedules section — 20pt top creates visual rhythm
            // between top-level sections (Pinned / Workspaces / Schedules).
            .padding(.top, 20)
            .padding(.bottom, 4)
            .textCase(nil)
        }
    }

    @State private var hoveredWorkspaceID: UUID?
    @State private var hoveredTaskID: UUID?

    private func workspaceRow(for workspace: Workspace) -> some View {
        let isExpanded = isWorkspaceExpanded(workspace)
        let isHovered = hoveredWorkspaceID == workspace.id
        let isSelected = selectedWorkspace?.id == workspace.id && selectedTask == nil

        return HStack(alignment: .center, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    toggleWorkspaceExpansion(workspace)
                }
            } label: {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(Stanford.ui(13, weight: .medium))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Name: smart select + expand
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    if isExpanded && isSelected {
                        // Already open and selected → collapse
                        toggleWorkspaceExpansion(workspace)
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
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .padding(.leading, 6)
        .padding(.trailing, isHovered ? 30 : 6)
        .padding(.vertical, 6)
        .frame(height: Stanford.sidebarWorkspaceRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in hoveredWorkspaceID = hovering ? workspace.id : nil }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedWorkspace?.id == workspace.id && selectedTask == nil ? Color.primary.opacity(0.10) : .clear)
        )
        .overlay(alignment: .trailing) {
            if isHovered {
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Stanford.ui(14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Workspace options")
                .accessibilityLabel("Options for \(workspace.name)")
                .padding(.trailing, 4)
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
        .contextMenu {
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

    @ViewBuilder
    private func workspaceTaskGroups(for workspace: Workspace) -> some View {
        let workspaceTasks = tasksForWorkspace(workspace).sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        let isShowingAll = expandedWorkspaceTaskLists.contains(workspace.id)
        let visibleTasks = isShowingAll ? workspaceTasks : Array(workspaceTasks.prefix(6))

        if workspaceTasks.isEmpty && !hasAnyTask(in: workspace) {
            emptyWorkspaceRow(for: workspace)
        } else if !workspaceTasks.isEmpty {
            ForEach(visibleTasks) { task in
                compactTaskRow(for: task)
            }

            if workspaceTasks.count > visibleTasks.count {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        _ = expandedWorkspaceTaskLists.insert(workspace.id)
                    }
                } label: {
                    Text("Show \(workspaceTasks.count - visibleTasks.count) more")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 24, bottom: 3, trailing: 8))
                .listRowBackground(Color.clear)
            }
        }
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
                    .font(Stanford.caption(12))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func compactTaskRow(for task: AgentTask) -> some View {
        Button {
            selectedTask = task
        } label: {
            SidebarThreadRow(
                task: task,
                isSelected: selectedTask?.id == task.id,
                // Hover signal is shared with the .overlay below — same
                // source of truth for the menu and the timestamp's
                // opacity, so they can't fall out of sync.
                isHovered: hoveredTaskID == task.id
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hoveredTaskID == task.id {
                Menu {
                    Button {
                        withAnimation {
                            task.isPinned.toggle()
                            try? modelContext.save()
                        }
                    } label: {
                        Label(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin")
                    }

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

                    Divider()

                    Button(role: .destructive) {
                        onDeleteTask?(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
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
                .padding(.top, 4)
                .padding(.trailing, 4)
            }
        }
        .onHover { hovering in hoveredTaskID = hovering ? task.id : nil }
        .onDrag {
            NSItemProvider(object: task.id.uuidString as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.poppy)
                Text(task.title)
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Button {
                withAnimation {
                    task.isPinned.toggle()
                    try? modelContext.save()
                }
            } label: {
                Label(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin")
            }

            Divider()

            taskContextMenu(for: task)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func taskRow(for task: AgentTask) -> some View {
        Button {
            selectedTask = task
        } label: {
            TaskRowView(task: task, isSelected: selectedTask?.id == task.id)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selectedTask?.id == task.id ? Color.primary.opacity(0.05) : .clear)
                )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .contextMenu {
            taskContextMenu(for: task)
        }
        .listRowBackground(Color.clear)
    }

    private func isWorkspaceExpanded(_ workspace: Workspace) -> Bool {
        if collapsedWorkspaceIDs.contains(workspace.id) {
            return false
        }

        return selectedWorkspace?.id == workspace.id ||
            expandedWorkspaceIDs.contains(workspace.id) ||
            (!searchText.isEmpty && !tasksForWorkspace(workspace, matchingSearch: true).isEmpty)
    }

    private func toggleWorkspaceExpansion(_ workspace: Workspace) {
        if isWorkspaceExpanded(workspace) {
            expandedWorkspaceIDs.remove(workspace.id)
            collapsedWorkspaceIDs.insert(workspace.id)
            expandedWorkspaceTaskLists.remove(workspace.id)
        } else {
            collapsedWorkspaceIDs.remove(workspace.id)
            expandedWorkspaceIDs.insert(workspace.id)
        }
    }

    private func tasksForWorkspace(_ workspace: Workspace, matchingSearch: Bool = false) -> [AgentTask] {
        let workspaceTasks = tasks.filter {
            $0.workspace?.id == workspace.id && isSidebarReviewTask($0)
        }
        guard matchingSearch || !searchText.isEmpty else { return workspaceTasks }
        guard !workspaceMatchesSearch(workspace) else { return workspaceTasks }
        return workspaceTasks.filter(taskMatchesSearch)
    }

    private func hasAnyTask(in workspace: Workspace) -> Bool {
        tasks.contains { $0.workspace?.id == workspace.id }
    }

    private func isSidebarReviewTask(_ task: AgentTask) -> Bool {
        !task.isDone && (
            task.status == .running ||
            KanbanCategory.review.includes(task)
        )
    }

    private func workspaceMatchesSearch(_ workspace: Workspace) -> Bool {
        workspace.name.localizedCaseInsensitiveContains(searchText) ||
            workspace.primaryPath.localizedCaseInsensitiveContains(searchText)
    }

    private func taskMatchesSearch(_ task: AgentTask) -> Bool {
        task.title.localizedCaseInsensitiveContains(searchText) ||
            task.goal.localizedCaseInsensitiveContains(searchText)
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
/// (Workspaces, Schedules). Calm secondary glyph that lights up lagunita
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
            .font(Stanford.ui(11, weight: .medium))
            .foregroundStyle(isHovered ? Color.white : Color.secondary)
            .frame(width: 20, height: 20)
            .background(isHovered ? Stanford.lagunita : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
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
    var subtitle: String?

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

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            statusIcon
                .frame(width: 14, height: 14)
                .opacity(showIcon ? (isActionableStatus && !isSelected && !isHovered ? 0.6 : 1) : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Stanford.ui(14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let secondaryText {
                    Text(secondaryText)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Right-side metadata is hidden on
            // hover so the three-dots context-menu overlay (added by
            // `compactTaskRow`) can render without overlapping text.
            // Keep the layout in place (no width shift) by using opacity,
            // not conditional removal.
            Text(relativeTime(task.updatedAt))
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 24, alignment: .trailing)
            .opacity(isHovered ? 0 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
        .help(task.title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.primary.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier("TaskRow_\(task.title)")
    }

    private var secondaryText: String? {
        subtitle ?? statusLabel
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

struct SearchPanelOverlay: View {
    let tasks: [AgentTask]
    let workspaces: [Workspace]
    @Binding var selectedTask: AgentTask?
    @Binding var selectedWorkspace: Workspace?
    @Binding var isActive: Bool
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
        guard !searchText.isEmpty else { return recentTasks }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.goal.localizedCaseInsensitiveContains(searchText)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(12)
        .map { $0 }
    }

    private var filteredWorkspaces: [Workspace] {
        guard !searchText.isEmpty else { return [] }
        return workspaces.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.primaryPath.localizedCaseInsensitiveContains(searchText)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

                    TextField("Search tasks...", text: $searchText)
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
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(searchText.isEmpty ? "Recent tasks" : "Tasks")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, filteredWorkspaces.isEmpty ? 10 : 14)
                            .padding(.bottom, 4)

                        ForEach(Array(filteredTasks.enumerated()), id: \.element.id) { idx, task in
                            Button {
                                selectedTask = task
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bubble.left")
                                        .font(Stanford.ui(13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(task.title)
                                        .font(Stanford.ui(14))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let ws = task.workspace {
                                        Text(ws.name)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(idx == selectedIndex ? Color.primary.opacity(0.06) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
