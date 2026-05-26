import AppKit
import SwiftData
import SwiftUI

private enum WorkspaceHomeLayout {
    static let boardMaxWidth: CGFloat = 1_520
    static let pagePadding: CGFloat = 24
}

enum WorkspaceHomePresentation {
    static let usesWorkspaceContextCard = true
    static let usesKanbanMeasuredPageRail = true
    static let contextRowsUseSummaryPattern = true
    static let contextCardShowsCapabilitiesRow = true
    static let contextCardAlignsWithBoardColumns = true
    static let headerShowsPrimaryNewTaskAction = true
    static let routinesUseSummaryRows = true
    static let instructionEditorStaysInsideContextCard = true
    static let rowIconFrame: CGFloat = 40
    static let rowMinHeight: CGFloat = 72
    static let rowSpacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
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
    @AppStorage("kanbanBoardDensity") private var densityRaw = KanbanBoardDensity.spacious.rawValue
    @FocusState private var isInstructionsFocused: Bool

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

                    workspaceContextCard
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: alignedContentWidth, alignment: .leading)
                .padding(.horizontal, KanbanBoardLayout.outerPadding)

                KanbanBoardView(
                    tasks: tasks,
                    onOpenTask: onOpenTask,
                    onDeleteTask: onDeleteTask,
                    onSetDoneState: onSetDoneState
                )
                .frame(maxWidth: pageRailWidth, alignment: .leading)
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
                    .frame(maxWidth: alignedContentWidth, alignment: .leading)
                    .padding(.horizontal, KanbanBoardLayout.outerPadding)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: pageRailWidth, alignment: .leading)
            .padding(.horizontal, WorkspaceHomeLayout.pagePadding)
            .padding(.vertical, WorkspaceHomeLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Stanford.panelBackground)
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
            boardContentWidth + (KanbanBoardLayout.outerPadding * 2)
        )
    }

    private var alignedContentWidth: CGFloat {
        max(0, pageRailWidth - (KanbanBoardLayout.outerPadding * 2))
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

            Button(action: onCreateTask) {
                Label("New task", systemImage: "plus")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Stanford.lagunita)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Create a task in \(workspace.name)")
        }
    }

    // MARK: - Workspace Context

    private var workspaceContextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Workspace context")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.bottom, 8)

            instructionsSummaryRow

            if isEditingInstructions {
                instructionsEditor
                    .padding(.leading, WorkspaceHomePresentation.rowIconFrame + WorkspaceHomePresentation.rowSpacing)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            } else if isInstructionsExpanded {
                instructionsExpandedDetail
                    .padding(.leading, WorkspaceHomePresentation.rowIconFrame + WorkspaceHomePresentation.rowSpacing)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }

            workspaceDivider

            capabilitiesSummaryRow
        }
        .workspaceSectionPanel()
    }

    private var instructionsSummaryRow: some View {
        WorkspaceHomeSummaryRow(
            icon: "text.alignleft",
            iconColor: Stanford.lagunita,
            title: "Instructions",
            subtitle: instructionsSubtitle,
            onSelect: {
                guard hasInstructions else {
                    startEditingInstructions()
                    return
                }
                withAnimation(disclosureAnimation) {
                    isInstructionsExpanded.toggle()
                }
            }
        ) {
            HStack(spacing: 12) {
                Button {
                    startEditingInstructions()
                } label: {
                    Text(hasInstructions ? "Edit" : "Add")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .help(hasInstructions ? "Edit workspace instructions" : "Add workspace instructions")

                if hasInstructions {
                    Image(systemName: isInstructionsExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $editedInstructions)
                .font(Stanford.mono(13))
                .focused($isInstructionsFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 280)
                .padding(10)
                .background(Color.primary.opacity(0.026))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Stanford.lagunita.opacity(0.32), lineWidth: 1)
                )
                .onAppear { isInstructionsFocused = true }

            HStack(spacing: 10) {
                Spacer()

                Button {
                    isEditingInstructions = false
                } label: {
                    Text("Cancel")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    workspace.instructions = editedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    workspace.updatedAt = Date()
                    isEditingInstructions = false
                    isInstructionsExpanded = !workspace.instructions.isEmpty
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
            }
        }
    }

    private var instructionsExpandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.instructions)
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.black)
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !workspace.additionalPaths.isEmpty {
                Text("Includes \(workspace.additionalPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var capabilitiesSummaryRow: some View {
        WorkspaceHomeSummaryRow(
            icon: "checkmark.shield",
            iconColor: Stanford.lagunita,
            title: capabilityHeadline,
            subtitle: capabilitySubtitle,
            onSelect: onManageCapabilities ?? onConfigure
        ) {
            HStack(spacing: 12) {
                Button(action: onManageCapabilities ?? onConfigure) {
                    Text("Manage")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
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

    private var instructionsSubtitle: String {
        guard hasInstructions else {
            return "Add guidance for how tasks should run"
        }
        return workspace.instructions
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var capabilityHeadline: String {
        let count = max(
            workspace.enabledCapabilityIDs.count,
            workspace.skills.count + workspace.connectors.count + workspace.localTools.count
        )
        guard count > 0 else { return "No active capabilities" }
        return "\(count) active \(count == 1 ? "capability" : "capabilities")"
    }

    private var capabilitySubtitle: String {
        let parts: [String] = [
            countPhrase(workspace.skills.count, singular: "skill", plural: "skills"),
            countPhrase(workspace.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(workspace.localTools.count, singular: "tool", plural: "tools")
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return "Browse the library to add skills, connectors, and tools"
        }
        return parts.joined(separator: ", ")
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    private func startEditingInstructions() {
        editedInstructions = workspace.instructions
        isEditingInstructions = true
        isInstructionsExpanded = false
    }

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
            Image(systemName: icon)
                .font(Stanford.ui(20, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: WorkspaceHomePresentation.rowIconFrame)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            trailing()
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, minHeight: WorkspaceHomePresentation.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
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

// MARK: - Routine Section

private struct WorkspaceScheduleSection: View {
    let schedules: [TaskSchedule]
    let onToggle: (TaskSchedule) -> Void
    let onEdit: (TaskSchedule) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 8)

            ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.055))
                        .frame(height: 1)
                        .padding(.leading, WorkspaceHomePresentation.rowIconFrame + WorkspaceHomePresentation.rowSpacing)
                }

                WorkspaceScheduleRow(
                    schedule: schedule,
                    onToggle: { onToggle(schedule) },
                    onEdit: { onEdit(schedule) }
                )
            }
        }
    }
}

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
