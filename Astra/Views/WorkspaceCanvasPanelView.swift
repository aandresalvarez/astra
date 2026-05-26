import SwiftData
import SwiftUI

enum PlanShelfPresentation {
    static let showsTopSummaryChips = false
    static let metadataIsInlineUnderTitle = true
    static let usesCardChromeForCollapsedStepRows = false
    static let usesRowDividers = true
    static let showsStepActionsOnlyWhenExpanded = true
    static let showsStatusBadgesOnlyForExceptionalStates = true
    static let addStepUsesBorderedChrome = false
    static let approvalNoticeUsesCardChrome = false
    static let footerUsesBarBackground = false

    static func showsRowDivider(
        rowIndex: Int,
        groupCount: Int,
        usesRowDividers: Bool = Self.usesRowDividers
    ) -> Bool {
        usesRowDividers && rowIndex < groupCount - 1
    }
}

enum PlanShelfStepGroupKind: String, CaseIterable, Identifiable, Equatable {
    case current
    case next
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current:
            return "Current"
        case .next:
            return "Next"
        case .done:
            return "Done"
        }
    }
}

struct PlanShelfGroupedStep: Identifiable, Equatable {
    let originalIndex: Int
    let step: TaskPlanStep

    var id: String { step.id }
}

struct PlanShelfStepGroup: Identifiable, Equatable {
    let kind: PlanShelfStepGroupKind
    let steps: [PlanShelfGroupedStep]

    var id: PlanShelfStepGroupKind { kind }
}

enum PlanShelfStepGrouping {
    static func groups(for steps: [TaskPlanStep]) -> [PlanShelfStepGroup] {
        let indexed = steps.enumerated().map { index, step in
            PlanShelfGroupedStep(originalIndex: index, step: step)
        }
        let current = indexed.filter { $0.step.status == .running || $0.step.status == .blocked }
        let next = indexed.filter { $0.step.status == .pending }
        let done = indexed.filter { $0.step.status == .done || $0.step.status == .skipped }

        return [
            PlanShelfStepGroup(kind: .current, steps: current),
            PlanShelfStepGroup(kind: .next, steps: next),
            PlanShelfStepGroup(kind: .done, steps: done)
        ].filter { !$0.steps.isEmpty }
    }
}

struct WorkspaceCanvasPanelView: View {
    let selectedTask: AgentTask?
    @Binding var isPresented: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @State private var draftPlan: TaskPlan?
    @State private var lastPlanSignature = ""
    @State private var cachedPlanState = TaskPlanState.empty
    @State private var cachedPlanInputSignature = ""
    @State private var pendingPlanRefreshTask: Task<Void, Never>?
    @State private var expandedStepID: String?

    private let knownTools = ["Read", "Grep", "Write", "Edit", "Bash"]

    private var planState: TaskPlanState {
        guard cachedPlanInputSignature == planInputSignature else { return .empty }
        return cachedPlanState
    }

    private var sourcePlan: TaskPlan? {
        planState.plan
    }

    private var planInputSignature: String {
        guard let selectedTask else { return "none" }
        let latestRun = selectedTask.runs.max { $0.startedAt < $1.startedAt }
        return [
            selectedTask.id.uuidString,
            selectedTask.status.rawValue,
            String(Int(selectedTask.updatedAt.timeIntervalSince1970)),
            String(selectedTask.events.count),
            String(selectedTask.runs.count),
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            String(latestRun?.output.count ?? 0)
        ].joined(separator: "|")
    }

    private var planSignature: String {
        guard let plan = sourcePlan else { return "none" }
        let stepSummary = plan.steps.map {
            [
                $0.id,
                $0.title,
                $0.detail,
                $0.status.rawValue,
                $0.risk.rawValue,
                $0.likelyTools.joined(separator: ","),
                $0.doneSignal
            ].joined(separator: ":")
        }.joined(separator: "|")
        return "\(plan.planID.uuidString):\(plan.title):\(plan.goal):\(planState.lifecycleStatus.rawValue):\(stepSummary)"
    }

    private var isTaskRunning: Bool {
        selectedTask?.status == .running
    }

    private var permissionMode: String {
        skipPermissions ? "Auto mode" : "Ask mode"
    }

    private var stepDisclosureAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private var canEditPlan: Bool {
        guard !isTaskRunning else { return false }
        switch planState.lifecycleStatus {
        case .none, .completed, .cancelled:
            return false
        case .draft, .approved, .executing, .failed:
            return true
        }
    }

    private var currentDraft: TaskPlan? {
        draftPlan ?? sourcePlan
    }

    private var canSave: Bool {
        guard canEditPlan,
              let draft = currentDraft,
              let sourcePlan else {
            return false
        }
        guard sanitizedPlan(draft) != nil else { return false }
        return sanitizedPlan(draft) != sourcePlan
    }

    var body: some View {
        VStack(spacing: 0) {
            if PlanShelfPresentation.showsTopSummaryChips {
                header
                Divider()
            }
            if let sourcePlan {
                planCanvas(sourcePlan)
            } else if shouldShowPlanLoadingState {
                loadingCanvas
            } else {
                emptyCanvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No background — parent paints .bar material that extends behind toolbar.
        .onAppear {
            schedulePlanStateRefresh(force: true)
        }
        .onChange(of: planInputSignature) {
            schedulePlanStateRefresh(force: true)
        }
        .onChange(of: planSignature) {
            syncDraftIfNeeded(force: true)
        }
        .onDisappear {
            pendingPlanRefreshTask?.cancel()
            pendingPlanRefreshTask = nil
        }
    }

    private var shouldShowPlanLoadingState: Bool {
        selectedTask != nil && cachedPlanInputSignature != planInputSignature
    }

    private var header: some View {
        HStack(spacing: 8) {
            planHeaderChips
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: Stanford.density(36), alignment: .center)
        .background(.bar)
    }

    @ViewBuilder
    private var planHeaderChips: some View {
        if let draft = currentDraft {
            let editableCount = TaskPlanService.editableStepCount(in: draft)
            HStack(spacing: 6) {
                canvasChip("\(draft.steps.count) steps")
                if editableCount > 0 {
                    canvasChip("\(editableCount) editable")
                }
            }
        }
    }

    private func planCanvas(_ sourcePlan: TaskPlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    planHeader
                    if let approvalNoticeText {
                        approvalNotice(text: approvalNoticeText)
                    }
                    stepList
                    if canEditPlan {
                        addStepButton
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 26)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }

            // Footer only appears in edit mode where local edit actions are useful.
            // Read-only states inline their status text under the plan metadata
            // so the bottom bar isn't just informational chrome.
            if canEditPlan {
                Divider()
                footer(sourcePlan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            if canEditPlan {
                TextField("Plan title", text: planTitleBinding)
                    .textFieldStyle(.plain)
                    .font(Stanford.heading(18))
                    .lineLimit(2)

                TextField("Plan summary", text: planGoalBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1...2)
            } else if let draft = currentDraft {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.title)
                        .font(Stanford.heading(18))
                        .foregroundStyle(.primary)
                    Text(draft.goal)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            planMetaLine

            if isReadOnlyAndTerminal, !readOnlyFooterMessage.isEmpty {
                Text(readOnlyFooterMessage)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // Clickable mode chooser. The decision (whether agent runs steps automatically or
    // pauses for approval) is the most consequential setting on a plan, so we keep
    // it visible in the plan header — not buried in a menu — with a chevron to make
    // its tappable nature obvious.
    private var permissionModePill: some View {
        Menu {
            Button {
                skipPermissions = true
            } label: {
                Label("Auto mode - run steps without pausing", systemImage: "bolt.fill")
            }
            Button {
                skipPermissions = false
            } label: {
                Label("Ask mode - pause before each step", systemImage: "checkmark.shield")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: skipPermissions ? "bolt.fill" : "checkmark.shield")
                    .font(Stanford.ui(10, weight: .semibold))
                Text(permissionMode)
                    .font(Stanford.caption(10).weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(Stanford.ui(8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(Stanford.lagunita)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose whether the plan runs automatically or pauses for review.")
    }

    private var planMetaLine: some View {
        HStack(spacing: 6) {
            if let draft = currentDraft {
                Label(stepCountLabel(for: draft.steps.count), systemImage: "list.number")
                    .labelStyle(.titleAndIcon)
            }
            metaSeparator
            permissionModePill
            metaSeparator
            Text(planLifecycleLabel)
                .font(Stanford.caption(10).weight(.semibold))
        }
        .font(Stanford.caption(10).weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var metaSeparator: some View {
        Text("·")
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(.secondary.opacity(0.65))
    }

    private func stepCountLabel(for count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    private var planLifecycleLabel: String {
        if isTaskRunning { return "In progress" }
        switch planState.lifecycleStatus {
        case .none:
            return "No plan"
        case .draft:
            return "Draft"
        case .approved:
            return "Approved"
        case .executing:
            return "In progress"
        case .completed:
            return "Completed"
        case .failed:
            return "Needs retry"
        case .cancelled:
            return "Cancelled"
        }
    }

    // True when the plan is in a state where the old footer's read-only message used to
    // appear. Used to inline that message under the plan metadata instead of taking a
    // dedicated footer row.
    private var isReadOnlyAndTerminal: Bool {
        if isTaskRunning { return true }
        switch planState.lifecycleStatus {
        case .completed, .cancelled:
            return true
        case .none, .draft, .approved, .executing, .failed:
            return false
        }
    }

    private var approvalNoticeText: String? {
        switch planState.lifecycleStatus {
        case .approved:
            if canEditPlan {
                return "Approved plan can still be refined here. Edit pending or blocked steps before running them."
            }
            return "Approved plan is open on the Shelf. It is read-only while the current step is running."
        case .executing:
            if canEditPlan {
                return "This approved plan is running step by step. You can still refine future pending or blocked steps before approving them."
            }
            return "This approved plan is running. Shelf is read-only until the current step pauses or finishes."
        case .none, .draft, .completed, .cancelled, .failed:
            return nil
        }
    }

    private func approvalNotice(text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.seal.fill")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.paloAltoGreen)
                .frame(width: 16, height: 16)

            Text(text)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var stepList: some View {
        let steps = currentDraft?.steps ?? []
        let expandedID = effectiveExpandedStepID(for: steps)
        let groups = PlanShelfStepGrouping.groups(for: steps)

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
                planStepGroup(group, expandedID: expandedID)
            }
        }
        .animation(stepDisclosureAnimation, value: expandedID)
    }

    private func planStepGroup(_ group: PlanShelfStepGroup, expandedID: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.kind.title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            ForEach(Array(group.steps.enumerated()), id: \.element.id) { rowIndex, groupedStep in
                planStepRow(
                    index: groupedStep.originalIndex,
                    step: groupedStep.step,
                    isExpanded: groupedStep.step.id == expandedID
                )

                if PlanShelfPresentation.showsRowDivider(rowIndex: rowIndex, groupCount: group.steps.count) {
                    Divider()
                        .overlay(Color.primary.opacity(0.055))
                        .padding(.leading, 42)
                }
            }
        }
    }

    private func planStepRow(index: Int, step: TaskPlanStep, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            if isExpanded, isStepEditable(step) {
                expandedEditableStepHeader(index: index, step: step)
            } else {
                compactStepHeader(index: index, step: step, isExpanded: isExpanded)
            }

            if isExpanded {
                if isStepEditable(step) {
                    expandedEditableStepBody(index: index, step: step)
                } else {
                    expandedLockedStepBody(step)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 10 : 8)
        .background(stepRowBackground(for: step, isExpanded: isExpanded))
        .overlay(alignment: .leading) {
            if shouldShowStepAccent(step, isExpanded: isExpanded) {
                Capsule()
                    .fill(color(for: step.status))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 1)
            }
        }
    }

    private func compactStepHeader(index: Int, step: TaskPlanStep, isExpanded: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                expandedStepID = isExpanded ? nil : step.id
            } label: {
                HStack(alignment: .center, spacing: 9) {
                    stepNumberBadge(index: index, step: step, isExpanded: isExpanded)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title)
                                .font(Stanford.caption(13).weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if shouldShowStatusBadge(for: step.status) {
                                statusBadge(for: step.status)
                            }
                        }

                        HStack(spacing: 5) {
                            Label(toolSummary(for: step), systemImage: "key.horizontal")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                            if let detail = compactDetail(for: step) {
                                Text("·")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                Text(detail)
                                    .foregroundStyle(step.status == .blocked ? Stanford.poppy : .secondary)
                            }
                        }
                        .font(Stanford.caption(11))
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, isStepEditable(step) {
                stepActionsMenu(index: index, step: step)
            }
        }
    }

    private func expandedEditableStepHeader(index: Int, step: TaskPlanStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stepNumberBadge(index: index, step: step, isExpanded: true)

            TextField("Step title", text: stepTitleBinding(index))
                .textFieldStyle(.plain)
                .font(Stanford.caption(13).weight(.semibold))
                .lineLimit(2)

            Spacer(minLength: 8)
            if shouldShowStatusBadge(for: step.status) {
                statusBadge(for: step.status)
            }
            stepActionsMenu(index: index, step: step)
        }
    }

    private func expandedEditableStepBody(index: Int, step: TaskPlanStep) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if step.status == .blocked, !step.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockedCallout(step.detail)
            }

            labeledEditor(
                label: step.status == .blocked ? "Blocker / Instructions" : "Instructions",
                placeholder: "What this step does",
                text: stepDetailBinding(index)
            )

            labeledField(
                label: "Acceptance",
                placeholder: "Done when",
                text: stepDoneSignalBinding(index)
            )

            stepSettingsRow(index: index, step: step)
        }
        .padding(.leading, 31)
    }

    private func expandedLockedStepBody(_ step: TaskPlanStep) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if step.status == .blocked, !step.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockedCallout(step.detail)
            } else if !step.detail.isEmpty {
                stepReadOnlyText(step.detail, systemImage: "text.alignleft", tint: .secondary)
            }

            if !step.doneSignal.isEmpty {
                stepReadOnlyText(
                    step.doneSignal,
                    systemImage: step.status == .done ? "checkmark.circle.fill" : "checkmark.circle",
                    tint: step.status == .done ? Stanford.paloAltoGreen : .secondary
                )
            }

            HStack(spacing: 6) {
                Label(toolSummary(for: step), systemImage: "key.horizontal")
                    .labelStyle(.titleAndIcon)
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.55))
                Label(step.risk.rawValue.capitalized, systemImage: "gauge")
                    .labelStyle(.titleAndIcon)
            }
            .font(Stanford.caption(11))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 31)
    }

    private var addStepButton: some View {
        Button {
            addStep()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(Stanford.caption(12).weight(.semibold))
                Text("Add step")
                    .font(Stanford.caption(12).weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
        .disabled(!canEditPlan)
    }

    private func footer(_ sourcePlan: TaskPlan) -> some View {
        HStack(spacing: 10) {
            footerOverflowMenu(sourcePlan)

            Spacer(minLength: 8)

            Button("Cancel") {
                syncDraftIfNeeded(force: true)
                isPresented = false
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .help("Close the plan panel without saving local edits.")

            Button("Save changes") {
                saveDraft()
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: true))
            .disabled(!canSave)
            .help(saveButtonHelp)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var readOnlyFooterMessage: String {
        if isTaskRunning {
            return "Shelf is read-only while the task is running."
        }
        switch planState.lifecycleStatus {
        case .completed:
            return "Plan completed. Completed steps are locked."
        case .cancelled:
            return "Plan cancelled. Historical steps are locked."
        case .none, .draft, .approved, .executing, .failed:
            return "No editable steps are available."
        }
    }

    private var saveButtonHelp: String {
        guard canEditPlan else {
            return "This plan cannot be edited right now."
        }
        guard let draft = currentDraft else {
            return "There is no plan draft to save."
        }
        guard sanitizedPlan(draft) != nil else {
            return "Fill in the plan title, goal, and step titles before saving."
        }
        guard canSave else {
            return "Make a plan edit before saving."
        }
        return "Save plan edits."
    }

    private var emptyCanvas: some View {
        ZStack {
            Stanford.panelBackground
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("No Plan Open")
                    .font(Stanford.heading(18))
                    .lineLimit(1)
                Text("Generate or select a plan to open it on the Shelf.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: 300)
            .liquidSurface(
                cornerRadius: Stanford.radiusLarge,
                fallbackFill: Stanford.cardBackground,
                fallbackStrokeOpacity: Stanford.strokeRest
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 7)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingCanvas: some View {
        ZStack {
            Stanford.panelBackground
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading plan")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: 240)
            .liquidSurface(
                cornerRadius: Stanford.radiusLarge,
                fallbackFill: Stanford.cardBackground,
                fallbackStrokeOpacity: Stanford.strokeRest
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func effectiveExpandedStepID(for steps: [TaskPlanStep]) -> String? {
        if let expandedStepID, steps.contains(where: { $0.id == expandedStepID }) {
            return expandedStepID
        }

        if let running = steps.first(where: { $0.status == .running }) {
            return running.id
        }

        if let blocked = steps.first(where: { $0.status == .blocked }) {
            return blocked.id
        }

        if canEditPlan, let editable = steps.first(where: TaskPlanService.isEditablePlanStep) {
            return editable.id
        }

        if let pending = steps.first(where: { $0.status == .pending }) {
            return pending.id
        }

        return nil
    }

    private func compactDetail(for step: TaskPlanStep) -> String? {
        let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return detail }

        let doneSignal = step.doneSignal.trimmingCharacters(in: .whitespacesAndNewlines)
        return doneSignal.isEmpty ? nil : doneSignal
    }

    private func permissionSummary(for step: TaskPlanStep) -> String {
        guard !step.likelyTools.isEmpty else { return "Needs: none" }
        return "Needs: \(step.likelyTools.joined(separator: ", "))"
    }

    private func toolSummary(for step: TaskPlanStep) -> String {
        guard !step.likelyTools.isEmpty else { return "No tools" }
        return step.likelyTools.joined(separator: ", ")
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
    }

    private func stepRowBackground(for step: TaskPlanStep, isExpanded: Bool) -> Color {
        guard isExpanded else { return Color.clear }
        switch step.status {
        case .running:
            return Stanford.lagunita.opacity(0.035)
        case .blocked:
            return Stanford.poppy.opacity(0.035)
        case .pending, .done, .skipped:
            return Color.primary.opacity(0.018)
        }
    }

    private func shouldShowStepAccent(_ step: TaskPlanStep, isExpanded: Bool) -> Bool {
        isExpanded && (step.status == .running || step.status == .blocked)
    }

    private func shouldShowStatusBadge(for status: TaskPlanStepStatus) -> Bool {
        switch status {
        case .running, .blocked:
            true
        case .pending, .done, .skipped:
            false
        }
    }

    private func stepNumberBadge(index: Int, step: TaskPlanStep, isExpanded: Bool) -> some View {
        ZStack {
            Circle()
                .fill(color(for: step.status).opacity(isExpanded ? 0.18 : 0.12))
            Text("\(index + 1)")
                .font(Stanford.caption(10).weight(.bold))
                .foregroundStyle(color(for: step.status))
        }
        .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private func statusBadge(for status: TaskPlanStepStatus) -> some View {
        switch status {
        case .pending:
            EmptyView()
        case .running:
            canvasChip("Running", color: color(for: status))
        case .blocked:
            canvasChip("Blocked", color: color(for: status))
        case .done:
            canvasChip("Done", color: color(for: status))
        case .skipped:
            canvasChip("Skipped", color: color(for: status))
        }
    }

    private func labeledEditor(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .padding(.top, 6)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(Stanford.caption(12))
                    .frame(minHeight: 46)
                    .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(fieldShape.fill(Color.primary.opacity(0.035)))
            .overlay(fieldShape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }

    private func labeledField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Stanford.caption(12))
                .lineLimit(1...3)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(fieldShape.fill(Color.primary.opacity(0.035)))
                .overlay(fieldShape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func blockedCallout(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.poppy)
                .frame(width: 16)
                .padding(.top, 1)

            Text(reason)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(fieldShape.fill(Color.primary.opacity(0.035)))
        .overlay(fieldShape.strokeBorder(Stanford.poppy.opacity(0.20), lineWidth: 1))
    }

    private func stepReadOnlyText(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: systemImage)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepSettingsRow(index: Int, step: TaskPlanStep) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label(permissionSummary(for: step), systemImage: "key.horizontal")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Menu {
                Picker("Risk", selection: stepRiskBinding(index)) {
                    ForEach(TaskPlanRisk.allCases, id: \.self) { risk in
                        Text(risk.rawValue.capitalized).tag(risk)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(riskColor(step.risk))
                        .frame(width: 6, height: 6)
                    Text(step.risk.rawValue.capitalized)
                }
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(riskColor(step.risk))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Set step risk.")

            Menu {
                ForEach(knownTools, id: \.self) { tool in
                    Button {
                        toggleTool(tool, at: index)
                    } label: {
                        if step.likelyTools.contains(tool) {
                            Label(tool, systemImage: "checkmark")
                        } else {
                            Text(tool)
                        }
                    }
                }
            } label: {
                Label("Permissions", systemImage: "slider.horizontal.3")
                    .font(Stanford.caption(11).weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Edit likely tools for this step.")
        }
    }

    private func stepActionsMenu(index: Int, step: TaskPlanStep) -> some View {
        Menu {
            Button {
                expandedStepID = step.id
            } label: {
                Label("Focus step", systemImage: "rectangle.expand.vertical")
            }

            Divider()

            Button {
                moveStep(index, by: -1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
            }
            .disabled(!canMoveStepUp(index))

            Button {
                moveStep(index, by: 1)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
            .disabled(!canMoveStepDown(index))

            Divider()

            Button(role: .destructive) {
                deleteStep(index)
            } label: {
                Label("Delete step", systemImage: "trash")
            }
            .disabled(!canDeleteStep(index))
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Step actions")
    }

    private func footerOverflowMenu(_ sourcePlan: TaskPlan) -> some View {
        Menu {
            Button("Discard edits") {
                syncDraftIfNeeded(force: true)
            }
            .disabled(currentDraft == sourcePlan)

            Divider()

            Button("Cancel plan", role: .destructive) {
                cancelPlan(sourcePlan)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Stanford.ui(14, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More plan actions")
    }

    private func canvasChip(_ text: String, color: Color = Stanford.coolGrey) -> some View {
        Text(text)
            .font(Stanford.caption(10).weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func syncDraftIfNeeded(force: Bool = false) {
        guard let sourcePlan else {
            draftPlan = nil
            lastPlanSignature = "none"
            return
        }
        guard force || lastPlanSignature != planSignature || draftPlan?.planID != sourcePlan.planID else { return }
        draftPlan = sourcePlan
        lastPlanSignature = planSignature
    }

    private func schedulePlanStateRefresh(force: Bool = false) {
        let requestedSignature = planInputSignature
        guard force || cachedPlanInputSignature != requestedSignature else { return }

        pendingPlanRefreshTask?.cancel()
        pendingPlanRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            let refreshedState = selectedTask.map { TaskPlanService.reconstruct(for: $0) } ?? .empty
            guard !Task.isCancelled, requestedSignature == planInputSignature else { return }

            cachedPlanState = refreshedState
            cachedPlanInputSignature = requestedSignature
            syncDraftIfNeeded(force: true)
        }
    }

    private func saveDraft() {
        guard let selectedTask,
              let draft = currentDraft,
              let sanitized = sanitizedPlan(draft) else {
            return
        }
        TaskPlanService.recordUpdated(sanitized, task: selectedTask, modelContext: modelContext)
        try? modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: selectedTask.workspace, modelContext: modelContext)
        draftPlan = sanitized
        lastPlanSignature = planSignature
    }

    private func cancelPlan(_ plan: TaskPlan) {
        guard let selectedTask else { return }
        TaskPlanService.recordCancelled(
            planID: plan.planID,
            task: selectedTask,
            modelContext: modelContext,
            reason: "Cancelled from shelf."
        )
        try? modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: selectedTask.workspace, modelContext: modelContext)
        isPresented = false
    }

    private func sanitizedPlan(_ plan: TaskPlan) -> TaskPlan? {
        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !goal.isEmpty else { return nil }

        var seenIDs = Set<String>()
        var steps: [TaskPlanStep] = []
        steps.reserveCapacity(plan.steps.count)

        for step in plan.steps {
            let stepTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stepTitle.isEmpty else { return nil }
            var id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || seenIDs.contains(id) {
                id = TaskPlanService.makeUniqueStepID(
                    in: TaskPlan(version: plan.version, planID: plan.planID, title: title, goal: goal, steps: steps),
                    preferredTitle: stepTitle
                )
            }
            seenIDs.insert(id)
            steps.append(TaskPlanStep(
                id: id,
                title: stepTitle,
                detail: step.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                status: step.status,
                risk: step.risk,
                likelyTools: Array(Set(step.likelyTools)).sorted(),
                doneSignal: step.doneSignal.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        guard !steps.isEmpty else { return nil }
        return TaskPlan(version: plan.version, planID: plan.planID, title: title, goal: goal, steps: steps)
    }

    private func isStepEditable(_ step: TaskPlanStep) -> Bool {
        canEditPlan && TaskPlanService.isEditablePlanStep(step)
    }

    private func canMoveStepUp(_ index: Int) -> Bool {
        guard let steps = currentDraft?.steps, steps.indices.contains(index), index > 0 else { return false }
        return isStepEditable(steps[index]) && isStepEditable(steps[index - 1])
    }

    private func canMoveStepDown(_ index: Int) -> Bool {
        guard let steps = currentDraft?.steps, steps.indices.contains(index), steps.indices.contains(index + 1) else { return false }
        return isStepEditable(steps[index]) && isStepEditable(steps[index + 1])
    }

    private func canDeleteStep(_ index: Int) -> Bool {
        guard let steps = currentDraft?.steps, steps.indices.contains(index), steps.count > 1 else { return false }
        return isStepEditable(steps[index])
    }

    private func moveStep(_ index: Int, by offset: Int) {
        guard var plan = currentDraft else { return }
        let destination = index + offset
        guard plan.steps.indices.contains(index), plan.steps.indices.contains(destination) else { return }
        guard isStepEditable(plan.steps[index]), isStepEditable(plan.steps[destination]) else { return }
        plan.steps.swapAt(index, destination)
        draftPlan = plan
    }

    private func deleteStep(_ index: Int) {
        guard var plan = currentDraft, plan.steps.indices.contains(index), canDeleteStep(index) else { return }
        plan.steps.remove(at: index)
        draftPlan = plan
    }

    private func addStep() {
        guard canEditPlan, var plan = currentDraft else { return }
        let title = "New step"
        let stepID = TaskPlanService.makeUniqueStepID(in: plan, preferredTitle: title)
        plan.steps.append(TaskPlanStep(
            id: stepID,
            title: title,
            detail: "",
            status: .pending,
            risk: .low,
            likelyTools: ["Read"],
            doneSignal: ""
        ))
        draftPlan = plan
        expandedStepID = stepID
    }

    private func toggleTool(_ tool: String, at index: Int) {
        guard var plan = currentDraft, plan.steps.indices.contains(index), isStepEditable(plan.steps[index]) else { return }
        if plan.steps[index].likelyTools.contains(tool) {
            plan.steps[index].likelyTools.removeAll { $0 == tool }
        } else {
            plan.steps[index].likelyTools.append(tool)
            plan.steps[index].likelyTools = Array(Set(plan.steps[index].likelyTools)).sorted()
        }
        draftPlan = plan
    }

    private var planTitleBinding: Binding<String> {
        Binding(
            get: { currentDraft?.title ?? "" },
            set: { value in
                guard var plan = currentDraft else { return }
                plan.title = value
                draftPlan = plan
            }
        )
    }

    private var planGoalBinding: Binding<String> {
        Binding(
            get: { currentDraft?.goal ?? "" },
            set: { value in
                guard var plan = currentDraft else { return }
                plan.goal = value
                draftPlan = plan
            }
        )
    }

    private func stepTitleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { currentDraft?.steps[safe: index]?.title ?? "" },
            set: { value in
                updateStep(at: index) { $0.title = value }
            }
        )
    }

    private func stepDetailBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { currentDraft?.steps[safe: index]?.detail ?? "" },
            set: { value in
                updateStep(at: index) { $0.detail = value }
            }
        )
    }

    private func stepDoneSignalBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { currentDraft?.steps[safe: index]?.doneSignal ?? "" },
            set: { value in
                updateStep(at: index) { $0.doneSignal = value }
            }
        )
    }

    private func stepRiskBinding(_ index: Int) -> Binding<TaskPlanRisk> {
        Binding(
            get: { currentDraft?.steps[safe: index]?.risk ?? .low },
            set: { value in
                updateStep(at: index) { $0.risk = value }
            }
        )
    }

    private func updateStep(at index: Int, mutate: (inout TaskPlanStep) -> Void) {
        guard var plan = currentDraft,
              plan.steps.indices.contains(index),
              isStepEditable(plan.steps[index]) else {
            return
        }
        mutate(&plan.steps[index])
        draftPlan = plan
    }

    private func riskColor(_ risk: TaskPlanRisk) -> Color {
        switch risk {
        case .low: Stanford.paloAltoGreen
        case .medium: Stanford.poppy
        case .high: Stanford.cardinalRed
        }
    }

    private func color(for status: TaskPlanStepStatus) -> Color {
        switch status {
        case .pending: Stanford.coolGrey
        case .running: Stanford.lagunita
        case .blocked: Stanford.poppy
        case .done: Stanford.paloAltoGreen
        case .skipped: Stanford.coolGrey
        }
    }

    private func icon(for status: TaskPlanStepStatus) -> String {
        switch status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .skipped: "forward.circle"
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
