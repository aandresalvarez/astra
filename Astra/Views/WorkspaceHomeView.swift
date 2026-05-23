import AppKit
import SwiftData
import SwiftUI

private enum WorkspaceHomeLayout {
    static let contentMaxWidth: CGFloat = 1_060
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

    @Query private var tasks: [AgentTask]

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
        onManageCapabilities: (() -> Void)? = nil
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

        let workspaceID = workspace.id
        _tasks = Query(
            filter: #Predicate<AgentTask> { task in
                task.workspace?.id == workspaceID
            },
            sort: \AgentTask.queuePosition
        )
    }

    var body: some View {
        WorkspaceHomeView(
            workspace: workspace,
            tasks: tasks,
            onCreateTask: onCreateTask,
            onOpenTask: onOpenTask,
            onDeleteTask: onDeleteTask,
            onSetDoneState: onSetDoneState,
            onConfigure: onConfigure,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            onManageCapabilities: onManageCapabilities
        )
    }
}

struct WorkspaceHomeView: View {
    let workspace: Workspace
    let tasks: [AgentTask]
    let onCreateTask: () -> Void
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    var onSetDoneState: ((AgentTask, Bool) -> Void)?
    let onConfigure: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingInstructions = false
    @State private var editedInstructions = ""
    @State private var isInstructionsExpanded = false
    @FocusState private var isInstructionsFocused: Bool

    // The skill/connector/tool aggregators previously rendered by the
    // center-panel Plugins summary were deleted when that section moved
    // entirely to the right rail. If you need them again, the right rail
    // (WorkspaceRightRailView) already computes the same aggregates.

    private var allTemplates: [TaskTemplate] {
        workspace.templates
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                header
                    .padding(.bottom, 16)

                // Instructions — prominent, always visible
                instructionsCard
                    .padding(.bottom, 20)

                // Tasks
                KanbanBoardView(
                    tasks: tasks,
                    onOpenTask: onOpenTask,
                    onDeleteTask: onDeleteTask,
                    onSetDoneState: onSetDoneState
                )
                    .padding(.bottom, 24)

                // Workspace-scoped context such as Memories lives in the
                // right rail's Workspace Setup section, so the main canvas
                // stays focused on task flow.

                // Routines (only when they exist)
                if !workspace.schedules.isEmpty {
                    WorkspaceScheduleSection(
                        schedules: workspace.schedules.sorted { $0.name < $1.name },
                        onToggle: { schedule in
                            schedule.isEnabled.toggle()
                            schedule.updatedAt = Date()
                        },
                        onEdit: { schedule in onEditSchedule?(schedule) },
                        onNew: { onNewSchedule?() }
                    )
                    .workspaceSectionPanel()
                    .padding(.bottom, 24)
                }
            }
            .padding(24)
            .frame(maxWidth: WorkspaceHomeLayout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Stanford.panelBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Bare folder icon — the tinted chip that used to sit behind
            // this made the workspace name feel like a badge. Cleaner as
            // just an inline glyph next to the title.
            Image(systemName: "folder.fill")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)

            Text(workspace.name)
                .font(Stanford.heading(22))

            Spacer()
        }
    }

    // MARK: - Instructions

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditingInstructions {
                // Editing mode
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "text.alignleft")
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)
                        Text("Instructions")
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isEditingInstructions = false
                        } label: {
                            Text("Cancel")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Button {
                            workspace.instructions = editedInstructions
                            isEditingInstructions = false
                        } label: {
                            Text("Save")
                                .font(Stanford.caption(12).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Stanford.lagunita)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }

                    TextEditor(text: $editedInstructions)
                        .font(Stanford.mono(13))
                        .focused($isInstructionsFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120, maxHeight: 300)
                        .padding(10)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Stanford.lagunita.opacity(0.4)))
                        .onAppear { isInstructionsFocused = true }
                }
                .padding(14)
                .background(Stanford.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isInstructionsExpanded {
                // Expanded mode
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "text.alignleft")
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)
                        Text("Instructions")
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                isInstructionsExpanded = false
                            }
                        } label: {
                            Text("Collapse")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                        Button {
                            editedInstructions = workspace.instructions
                            isEditingInstructions = true
                        } label: {
                            Text("Edit")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(workspace.instructions)
                        .font(Stanford.ui(13))
                        .foregroundStyle(Stanford.black)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !workspace.additionalPaths.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(Stanford.ui(10))
                                .foregroundStyle(.tertiary)
                            Text(workspace.additionalPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                .font(Stanford.caption(11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(14)
                .background(Stanford.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Compact bar
                HStack(spacing: 10) {
                    if !workspace.instructions.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(Stanford.ui(12))
                            .foregroundStyle(.secondary)

                        Text("Instructions")
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(workspace.instructions.replacingOccurrences(of: "\n", with: " "))
                            .font(Stanford.ui(13))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(workspace.instructions)

                        Spacer(minLength: 8)

                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                isInstructionsExpanded = true
                            }
                        } label: {
                            Text("Expand")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editedInstructions = workspace.instructions
                            isEditingInstructions = true
                        } label: {
                            Text("Edit")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            editedInstructions = ""
                            isEditingInstructions = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(Stanford.ui(12))
                                Text("Add instructions")
                                    .font(Stanford.caption(13).weight(.medium))
                            }
                            .foregroundStyle(Stanford.lagunita)
                        }
                        .buttonStyle(.plain)
                        .help("Set workspace-level instructions that guide every agent task in this workspace")

                        Spacer(minLength: 8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Stanford.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Memories

    private var memoriesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.checkmark")
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                Text("Memories")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(workspace.memories.count)")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(workspace.memories.enumerated()), id: \.offset) { _, memory in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.lagunita.opacity(0.55))
                    Text(memory)
                        .font(Stanford.ui(14))
                        .foregroundStyle(Stanford.black)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // The center panel used to render a full "Plugins" summary section
    // here (pluginsSection + pluginColumn) that duplicated the right
    // rail's Configure tab. Removed in the center-panel-polish pass.
    // Skills/Connectors/Tools are still shown in the right rail and
    // edited via Configure; no center-panel footprint needed.

}

private struct WorkspaceSectionPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Stanford.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

private extension View {
    func workspaceSectionPanel() -> some View {
        modifier(WorkspaceSectionPanelModifier())
    }
}

// MARK: - Routine Section

private struct WorkspaceScheduleSection: View {
    let schedules: [TaskSchedule]
    let onToggle: (TaskSchedule) -> Void
    let onEdit: (TaskSchedule) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routines")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onNew) {
                    Label("New", systemImage: "plus")
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 4) {
                ForEach(schedules) { schedule in
                    Button { onEdit(schedule) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(Stanford.ui(12))
                                .foregroundStyle(schedule.isEnabled ? Stanford.lagunita : .secondary)

                            Text(schedule.name)
                                .font(Stanford.body(13))
                                .foregroundStyle(Stanford.black)
                                .lineLimit(1)

                            Text(schedule.frequencySummary)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.tertiary)

                            Spacer()

                            if schedule.fireCount > 0 {
                                Text("\(schedule.fireCount) runs")
                                    .font(Stanford.caption(11))
                                    .foregroundStyle(.quaternary)
                            }

                            Toggle("", isOn: Binding(
                                get: { schedule.isEnabled },
                                set: { _ in onToggle(schedule) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
