import SwiftData
import SwiftUI

struct WorkspaceCanvasPanelView: View {
    let selectedTask: AgentTask?
    @Binding var isPresented: Bool

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @State private var draftPlan: TaskPlan?
    @State private var lastPlanSignature = ""

    private let knownTools = ["Read", "Grep", "Write", "Edit", "Bash"]

    private var planState: TaskPlanState {
        guard let selectedTask else { return .empty }
        return TaskPlanService.reconstruct(for: selectedTask)
    }

    private var sourcePlan: TaskPlan? {
        planState.plan
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
        skipPermissions ? "Auto mode" : "Review mode"
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
            header
            Divider()
            if let sourcePlan {
                planCanvas(sourcePlan)
            } else {
                emptyCanvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No background — parent paints .bar material that extends behind toolbar.
        .onAppear { syncDraftIfNeeded(force: true) }
        .onChange(of: planSignature) {
            syncDraftIfNeeded(force: true)
        }
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

            // Footer only appears in edit mode where Cancel/Discard/Save are real
            // primary actions. Read-only states inline their status text under the
            // plan header chips so the bottom bar isn't just informational chrome.
            if canEditPlan {
                Divider()
                footer(sourcePlan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            if canEditPlan {
                TextField("Plan title", text: planTitleBinding)
                    .textFieldStyle(.plain)
                    .font(Stanford.heading(18))
                    .lineLimit(2)

                TextEditor(text: planGoalBinding)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 42, maxHeight: 64)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .background(Stanford.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                            .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
                    )
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

            HStack(spacing: 6) {
                permissionModePill
                if isTaskRunning {
                    canvasChip("Running", color: Stanford.poppy)
                } else {
                    canvasChip(planState.lifecycleStatus.rawValue.capitalized)
                }
                if isReadOnlyAndTerminal, !readOnlyFooterMessage.isEmpty {
                    Text(readOnlyFooterMessage)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
                Label("Auto mode — run steps without pausing", systemImage: "bolt.fill")
            }
            Button {
                skipPermissions = false
            } label: {
                Label("Review mode — pause before each step", systemImage: "checkmark.shield")
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Stanford.lagunita)
            .background(Stanford.lagunita.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Stanford.lagunita.opacity(Stanford.strokeRest), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose whether the plan runs automatically or pauses for review.")
    }

    // True when the plan is in a state where the old footer's read-only message used to
    // appear. Used to inline that message under the status chip instead of taking a
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
                .font(Stanford.ui(14, weight: .semibold))
                .foregroundStyle(Stanford.paloAltoGreen)
                .frame(width: 18, height: 18)

            Text(text)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(10)
        .liquidSurface(
            cornerRadius: Stanford.radiusMedium,
            fallbackFill: Stanford.paloAltoGreen.opacity(0.08),
            fallbackStrokeOpacity: 0
        )
        .overlay(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous).stroke(Stanford.paloAltoGreen.opacity(Stanford.strokeActive), lineWidth: 1))
    }

    private var stepList: some View {
        VStack(spacing: 10) {
            ForEach(Array((currentDraft?.steps ?? []).enumerated()), id: \.element.id) { index, step in
                if isStepEditable(step) {
                    editableStepCard(index: index, step: step)
                } else {
                    lockedStepCard(index: index, step: step)
                }
            }
        }
    }

    private func lockedStepCard(index: Int, step: TaskPlanStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: step.status))
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(color(for: step.status))
                    .frame(width: 20, height: 20)
                Text("\(index + 1). \(step.title)")
                    .font(Stanford.caption(13).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if step.status == .running {
                    canvasChip("Running", color: color(for: step.status))
                }
            }

            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }

            if !step.doneSignal.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: step.status == .done ? "checkmark.circle.fill" : "arrow.turn.down.right")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(step.status == .done ? Stanford.statusHealthy : .secondary)
                        .frame(width: 14)
                    Text(step.doneSignal)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }

            stepMetadataRow(step)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidSurface(
            cornerRadius: Stanford.radiusMedium,
            fallbackFill: color(for: step.status).opacity(0.07),
            fallbackStrokeOpacity: 0
        )
        .overlay(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous).stroke(color(for: step.status).opacity(Stanford.strokeActive), lineWidth: 1))
    }

    private func editableStepCard(index: Int, step: TaskPlanStep) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color(for: step.status).opacity(0.14))
                    Text("\(index + 1)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(color(for: step.status))
                }
                .frame(width: 22, height: 22)

                TextField("Step title", text: stepTitleBinding(index))
                    .textFieldStyle(.plain)
                    .font(Stanford.caption(13).weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 8)

                if step.status == .blocked {
                    canvasChip("Blocked", color: Stanford.poppy)
                }

                moveButton(systemImage: "arrow.up", isDisabled: !canMoveStepUp(index)) {
                    moveStep(index, by: -1)
                }
                moveButton(systemImage: "arrow.down", isDisabled: !canMoveStepDown(index)) {
                    moveStep(index, by: 1)
                }
                moveButton(systemImage: "trash", isDisabled: !canDeleteStep(index), role: .destructive) {
                    deleteStep(index)
                }
            }

            placeholderEditor(
                icon: "text.alignleft",
                placeholder: "What this step does…",
                text: stepDetailBinding(index)
            )
            placeholderField(
                icon: "checkmark.circle",
                placeholder: "Done when…",
                text: stepDoneSignalBinding(index)
            )

            HStack(alignment: .center, spacing: 10) {
                Picker("Risk", selection: stepRiskBinding(index)) {
                    ForEach(TaskPlanRisk.allCases, id: \.self) { risk in
                        Text(risk.rawValue.capitalized).tag(risk)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
                .labelsHidden()
                .help("Risk level")

                FlowLayout(spacing: 5) {
                    ForEach(knownTools, id: \.self) { tool in
                        toolChip(tool, isSelected: step.likelyTools.contains(tool)) {
                            toggleTool(tool, at: index)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidSurface(
            cornerRadius: Stanford.radiusMedium,
            interactive: true,
            fallbackFill: Stanford.cardBackground,
            fallbackStrokeOpacity: 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(step.status == .blocked ? Stanford.poppy.opacity(Stanford.strokeActive) : Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private var addStepButton: some View {
        Button {
            addStep()
        } label: {
            Label("Add step", systemImage: "plus")
                .font(Stanford.caption(12).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
        .liquidSurface(
            cornerRadius: Stanford.radiusMedium,
            interactive: true,
            fallbackFill: Stanford.lagunita.opacity(0.06),
            fallbackStrokeOpacity: 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Stanford.lagunita.opacity(Stanford.strokeActive), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .disabled(!canEditPlan)
    }

    private func footer(_ sourcePlan: TaskPlan) -> some View {
        HStack(spacing: 10) {
            Button("Cancel plan") {
                cancelPlan(sourcePlan)
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .foregroundStyle(Stanford.cardinalRed)
            .help("Cancel this plan and stop using it for the task.")

            Spacer(minLength: 8)

            Button("Discard") {
                syncDraftIfNeeded(force: true)
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .disabled(currentDraft == sourcePlan)
            .help(currentDraft == sourcePlan ? "There are no local plan edits to discard." : "Discard local plan edits.")

            Button("Save changes") {
                saveDraft()
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: true))
            .disabled(!canSave)
            .help(saveButtonHelp)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
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
                Image(systemName: "rectangle.inset.filled")
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

    private func placeholderField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Stanford.caption(12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private func placeholderEditor(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 6)
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
                    .frame(minHeight: 44)
                    .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
        )
    }

    private func stepMetadataRow(_ step: TaskPlanStep) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(riskColor(step.risk))
                .frame(width: 5, height: 5)
            Text(step.risk.rawValue.capitalized)
                .foregroundStyle(riskColor(step.risk))
            if !step.likelyTools.isEmpty {
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(step.likelyTools.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
        .font(Stanford.caption(10).weight(.semibold))
        .padding(.leading, 28)
    }

    private func moveButton(
        systemImage: String,
        isDisabled: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(Stanford.ui(11, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Stanford.cardinalRed : .secondary)
        .background(Stanford.cardBackground.opacity(isDisabled ? 0 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
        .disabled(isDisabled)
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

    private func toolChip(_ tool: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(tool)
                .font(Stanford.caption(10).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Stanford.lagunita.opacity(0.14) : Stanford.cardBackground)
                .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(isSelected ? Stanford.lagunita.opacity(Stanford.strokeActive) : Color.primary.opacity(Stanford.strokeRest), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
        plan.steps.append(TaskPlanStep(
            id: TaskPlanService.makeUniqueStepID(in: plan, preferredTitle: title),
            title: title,
            detail: "",
            status: .pending,
            risk: .low,
            likelyTools: ["Read"],
            doneSignal: ""
        ))
        draftPlan = plan
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
