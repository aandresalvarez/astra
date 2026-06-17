import AppKit
import SwiftData
import SwiftUI

private enum WorkspaceHomeLayout {
    static let boardMaxWidth: CGFloat = 1_520
    static let minimumPageRailWidth: CGFloat = 920
    static let pagePadding: CGFloat = 24
}

enum WorkspaceHomePresentation {
    static let usesWorkspaceContextCard = true
    static let usesKanbanMeasuredPageRail = true
    static let contextRowsUseSummaryPattern = true
    static let contextCardShowsCapabilitiesRow = true
    static let contextCardAlignsWithBoardColumns = true
    static let headerShowsWorkspaceStatus = false
    static let headerUsesOverviewMetrics = false
    static let headerUsesCompactOverviewMetrics = false
    static let statusCountsStayOnBoard = true
    static let instructionsArePrimaryWorkspaceSurface = true
    static let instructionsExpandByDefaultWhenConfigured = false
    static let instructionsShowPreviewWhenConfigured = true
    static let emptyInstructionsUseSinglePrompt = true
    static let instructionBlockUsesPrimaryCTAWhenEmpty = true
    static let usesMinimumWelcomeRailWidth = true
    static let headerShowsPrimaryNewTaskAction = false
    static let routinesUseSummaryRows = true
    static let instructionEditorStaysInsideContextCard = true
    static let rowIconFrame: CGFloat = 40
    static let rowMinHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
    static let minimumWelcomeRailWidth = WorkspaceHomeLayout.minimumPageRailWidth
}

struct WorkspaceInstructionBlock: Equatable {
    var title: String?
    var items: [String]
}

enum WorkspaceInstructionPresentation {
    static let emptyPromptTitle = "Tell the agent how you work"
    static let emptyPromptBody = "Add conventions, tone, and what to avoid. They apply to every task in this workspace."
    static let emptyActionTitle = "Write instructions"
    static let configuredSubtitle = "Workspace prompt"
    static let configuredFallbackSubtitle = "Workspace guidance configured"
    static let usesReadableExpandedBlocks = true
    static let previewItemLimit = 2
    static let detailTitleFontSize: CGFloat = 12
    static let detailBodyFontSize: CGFloat = 13
    static let detailLineSpacing: CGFloat = 3
    static let detailBlockSpacing: CGFloat = 10
    static let detailItemSpacing: CGFloat = 6
    static let bulletSize: CGFloat = 4
    static let bulletColumnWidth: CGFloat = 12

    static func subtitle(for instructions: String) -> String {
        let blocks = blocks(from: instructions)
        let itemCount = blocks.reduce(0) { $0 + $1.items.count }

        if itemCount > 1 {
            return "\(itemCount) guidance items"
        }

        return blocks.first?.items.first
            ?? configuredFallbackSubtitle
    }

    static func previewItems(from instructions: String) -> [String] {
        Array(
            blocks(from: instructions)
                .flatMap(\.items)
                .prefix(previewItemLimit)
        )
    }

    static func blocks(from instructions: String) -> [WorkspaceInstructionBlock] {
        var seenItems = Set<String>()
        var renderedBlocks: [WorkspaceInstructionBlock] = []

        for paragraph in normalizedParagraphs(from: instructions) {
            if let firstLine = paragraph.first,
               firstLine.hasSuffix(":"),
               paragraph.count > 1 {
                appendBlock(
                    title: formattedHeading(firstLine),
                    items: paragraph.dropFirst().flatMap { sentenceFragments(from: $0) },
                    seenItems: &seenItems,
                    renderedBlocks: &renderedBlocks
                )
                continue
            }

            var plainItems: [String] = []
            var activeSectionTitle: String?
            var activeSectionItems: [String] = []

            for fragment in sentenceFragments(from: paragraph.joined(separator: " ")) {
                if let section = splitSection(from: fragment) {
                    appendBlock(
                        title: nil,
                        items: plainItems,
                        seenItems: &seenItems,
                        renderedBlocks: &renderedBlocks
                    )
                    plainItems = []

                    if activeSectionTitle != section.title {
                        appendBlock(
                            title: activeSectionTitle,
                            items: activeSectionItems,
                            seenItems: &seenItems,
                            renderedBlocks: &renderedBlocks
                        )
                        activeSectionTitle = section.title
                        activeSectionItems = []
                    }

                    activeSectionItems.append(section.item)
                } else if activeSectionTitle != nil {
                    activeSectionItems.append(fragment)
                } else {
                    plainItems.append(fragment)
                }
            }

            appendBlock(
                title: nil,
                items: plainItems,
                seenItems: &seenItems,
                renderedBlocks: &renderedBlocks
            )
            appendBlock(
                title: activeSectionTitle,
                items: activeSectionItems,
                seenItems: &seenItems,
                renderedBlocks: &renderedBlocks
            )
        }

        return renderedBlocks
    }

    private static func appendBlock(
        title: String?,
        items: [String],
        seenItems: inout Set<String>,
        renderedBlocks: inout [WorkspaceInstructionBlock]
    ) {
        let uniqueItems = items.compactMap { item -> String? in
            let normalized = normalizedDisplayText(item)
            guard !normalized.isEmpty else { return nil }

            let key = normalized
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seenItems.contains(key) else { return nil }
            seenItems.insert(key)
            return normalized
        }

        guard !uniqueItems.isEmpty else { return }
        renderedBlocks.append(WorkspaceInstructionBlock(title: title, items: uniqueItems))
    }

    private static func normalizedParagraphs(from instructions: String) -> [[String]] {
        let lines = instructions
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var paragraphs: [[String]] = []
        var current: [String] = []

        for line in lines {
            let normalized = normalizedDisplayText(line)
            if normalized.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            } else {
                current.append(stripListMarker(from: normalized))
            }
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
    }

    private static func sentenceFragments(from text: String) -> [String] {
        let normalized = normalizedDisplayText(text)
        var fragments: [String] = []
        var current = ""

        for character in normalized {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let fragment = normalizedDisplayText(current)
                if !fragment.isEmpty {
                    fragments.append(fragment)
                }
                current = ""
            }
        }

        let remainder = normalizedDisplayText(current)
        if !remainder.isEmpty {
            fragments.append(remainder)
        }

        return fragments
    }

    private static func splitSection(from fragment: String) -> (title: String, item: String)? {
        guard let colonIndex = fragment.firstIndex(of: ":") else { return nil }

        let title = normalizedDisplayText(String(fragment[..<colonIndex]))
        let itemStart = fragment.index(after: colonIndex)
        let item = normalizedDisplayText(String(fragment[itemStart...]))

        guard !title.isEmpty,
              !item.isEmpty,
              title.count <= 48,
              !title.contains(".") else {
            return nil
        }

        return (formattedHeading(title), item)
    }

    private static func formattedHeading(_ text: String) -> String {
        let trimmed = normalizedDisplayText(text.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    private static func stripListMarker(from text: String) -> String {
        text.replacingOccurrences(
            of: #"^([-*•]|\d+[.)])\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
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
            // Enforce the board invariant at the view layer: a card is delegated
            // work, so drafts (in-composition chats) are never surfaced. A task
            // appears here the moment it's queued/run.
            tasks: tasks.filter { !TaskHygiene.isHiddenFromBoard($0) },
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
    @State private var initializedInstructionsWorkspaceID: UUID?
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
        .onAppear {
            initializeInstructionsPresentationIfNeeded()
        }
        .onChange(of: workspace.id) {
            initializedInstructionsWorkspaceID = nil
            initializeInstructionsPresentationIfNeeded()
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

    // MARK: - Workspace Context

    private var workspaceContextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
            // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
            HStack(alignment: .top, spacing: 8) {
                Text("Workspace context")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.bottom, 8)

            instructionsBlock

            workspaceDivider

            capabilitiesSummaryRow
        }
        .workspaceSectionPanel()
    }

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
        HStack(alignment: .top, spacing: WorkspaceHomePresentation.rowSpacing) {
            Image(systemName: "text.alignleft")
                .font(Stanford.ui(19, weight: .medium))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: WorkspaceHomePresentation.rowIconFrame)
                .padding(.top, 13)

            VStack(alignment: .leading, spacing: 10) {
                // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
                // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instructions")
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(WorkspaceInstructionPresentation.configuredSubtitle)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.tertiary)
                    }

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

                    Button {
                        withAnimation(disclosureAnimation) {
                            isInstructionsExpanded.toggle()
                        }
                        persistInstructionsExpanded(isInstructionsExpanded)
                    } label: {
                        HStack(spacing: 4) {
                            Text(isInstructionsExpanded ? "Hide" : "Read")
                            Image(systemName: isInstructionsExpanded ? "chevron.up" : "chevron.down")
                                .font(Stanford.ui(10, weight: .semibold))
                        }
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                    .help(isInstructionsExpanded ? "Collapse workspace instructions" : "Read workspace instructions")
                }

                if isInstructionsExpanded {
                    instructionsExpandedDetail
                } else {
                    instructionsPreview
                }
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var instructionsEditingBlock: some View {
        HStack(alignment: .top, spacing: WorkspaceHomePresentation.rowSpacing) {
            Image(systemName: "text.alignleft")
                .font(Stanford.ui(19, weight: .medium))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: WorkspaceHomePresentation.rowIconFrame)
                .padding(.top, 13)

            VStack(alignment: .leading, spacing: 10) {
                Text("Instructions")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
                        persistInstructionsExpanded(isInstructionsExpanded)
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
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var instructionsPreview: some View {
        VStack(alignment: .leading, spacing: WorkspaceInstructionPresentation.detailItemSpacing) {
            ForEach(Array(instructionPreviewItems.enumerated()), id: \.offset) { _, item in
                instructionItem(item)
            }

            let remainingCount = max(0, instructionItemCount - instructionPreviewItems.count)
            if remainingCount > 0 {
                Text("\(remainingCount) more \(remainingCount == 1 ? "guidance item" : "guidance items")")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, WorkspaceInstructionPresentation.bulletColumnWidth + 6)
            }
        }
    }

    private var instructionsExpandedDetail: some View {
        VStack(alignment: .leading, spacing: WorkspaceInstructionPresentation.detailBlockSpacing) {
            ForEach(Array(instructionBlocks.enumerated()), id: \.offset) { _, block in
                instructionBlock(block)
            }

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

    private var instructionBlocks: [WorkspaceInstructionBlock] {
        WorkspaceInstructionPresentation.blocks(from: workspace.instructions)
    }

    private var instructionPreviewItems: [String] {
        WorkspaceInstructionPresentation.previewItems(from: workspace.instructions)
    }

    private var capabilityHeadline: String {
        // Lead with the noun; the count and breakdown are metadata in the subtitle.
        "Capabilities"
    }

    private var instructionItemCount: Int {
        instructionBlocks.reduce(0) { $0 + $1.items.count }
    }

    private var capabilityCount: Int {
        max(
            workspace.enabledCapabilityIDs.count,
            workspace.skills.count + workspace.connectors.count + workspace.localTools.count
        )
    }

    private var capabilitySubtitle: String {
        let parts: [String] = [
            countPhrase(workspace.skills.count, singular: "skill", plural: "skills"),
            countPhrase(workspace.connectors.count, singular: "connector", plural: "connectors"),
            countPhrase(workspace.localTools.count, singular: "tool", plural: "tools")
        ].compactMap { $0 }

        guard !parts.isEmpty else {
            return "None active — browse the library to add skills, connectors, and tools"
        }
        let count = capabilityCount
        return "\(count) active — \(parts.joined(separator: ", "))"
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

    private func initializeInstructionsPresentationIfNeeded() {
        guard initializedInstructionsWorkspaceID != workspace.id else { return }
        initializedInstructionsWorkspaceID = workspace.id
        isEditingInstructions = false
        // Restore the user's last expand choice for this workspace rather than
        // forcing it collapsed every appearance / workspace switch.
        isInstructionsExpanded = loadInstructionsExpanded()
    }

    private func instructionsExpandedKey() -> String {
        "workspaceHome.instructionsExpanded.\(workspace.id.uuidString)"
    }

    private func loadInstructionsExpanded() -> Bool {
        UserDefaults.standard.bool(forKey: instructionsExpandedKey())
    }

    private func persistInstructionsExpanded(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: instructionsExpandedKey())
    }

    @ViewBuilder
    private func instructionBlock(_ block: WorkspaceInstructionBlock) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceInstructionPresentation.detailItemSpacing) {
            if let title = block.title {
                Text(title)
                    .font(Stanford.caption(WorkspaceInstructionPresentation.detailTitleFontSize).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: WorkspaceInstructionPresentation.detailItemSpacing) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    instructionItem(item)
                }
            }
        }
    }

    private func instructionItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(
                    width: WorkspaceInstructionPresentation.bulletSize,
                    height: WorkspaceInstructionPresentation.bulletSize
                )
                .frame(width: WorkspaceInstructionPresentation.bulletColumnWidth)
                .padding(.top, 7)

            Text(text)
                .font(Stanford.ui(WorkspaceInstructionPresentation.detailBodyFontSize))
                .foregroundStyle(.primary)
                .lineSpacing(WorkspaceInstructionPresentation.detailLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    Label("Add routine", systemImage: "plus")
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
