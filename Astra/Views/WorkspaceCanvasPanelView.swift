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
        .background(Stanford.panelBackground)
        .onAppear { syncDraftIfNeeded(force: true) }
        .onChange(of: planSignature) {
            syncDraftIfNeeded(force: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled")
                .font(Stanford.ui(16, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Canvas")
                    .font(Stanford.heading(15))
                Text("Plan")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
            }

            Spacer(minLength: 8)

            if let draft = currentDraft {
                canvasChip("\(draft.steps.count) steps")
                canvasChip("\(TaskPlanService.editableStepCount(in: draft)) editable")
            }

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close canvas")
            .accessibilityIdentifier("WorkspaceCanvasCloseButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func planCanvas(_ sourcePlan: TaskPlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    planHeader
                    stepList
                    if canEditPlan {
                        addStepButton
                    }
                }
                .padding(16)
            }

            Divider()
            footer(sourcePlan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canEditPlan {
                TextField("Plan title", text: planTitleBinding)
                    .textFieldStyle(.plain)
                    .font(Stanford.heading(18))

                TextEditor(text: planGoalBinding)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, maxHeight: 72)
                    .scrollContentBackground(.hidden)
                    .background(Stanford.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
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
                canvasChip(permissionMode, color: Stanford.lagunita)
                if isTaskRunning {
                    canvasChip("Running", color: Stanford.poppy)
                } else {
                    canvasChip(planState.lifecycleStatus.rawValue.capitalized)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: step.status))
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(color(for: step.status))
                    .frame(width: 20, height: 20)
                Text("\(index + 1). \(step.title)")
                    .font(Stanford.caption(13).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                canvasChip(step.status == .running ? "Running" : "Locked", color: color(for: step.status))
            }

            if !step.detail.isEmpty {
                fieldPreview(label: "Details", value: step.detail)
            }

            if !step.doneSignal.isEmpty {
                fieldPreview(label: step.status == .done ? "Completed" : "Done signal", value: step.doneSignal)
            }

            stepMetadataRow(step)
        }
        .padding(12)
        .background(color(for: step.status).opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color(for: step.status).opacity(0.18), lineWidth: 1)
        )
    }

    private func editableStepCard(index: Int, step: TaskPlanStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color(for: step.status).opacity(0.14))
                    Text("\(index + 1)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(color(for: step.status))
                }
                .frame(width: 22, height: 22)

                Text(step.status == .blocked ? "Blocked step" : "Editable step")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

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

            labeledTextField("Title", text: stepTitleBinding(index))
            labeledTextEditor("Details", text: stepDetailBinding(index))
            labeledTextField("Done signal", text: stepDoneSignalBinding(index))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Risk")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Risk", selection: stepRiskBinding(index)) {
                        ForEach(TaskPlanRisk.allCases, id: \.self) { risk in
                            Text(risk.rawValue.capitalized).tag(risk)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 188)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tools")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(knownTools, id: \.self) { tool in
                            toolChip(tool, isSelected: step.likelyTools.contains(tool)) {
                                toggleTool(tool, at: index)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(step.status == .blocked ? Stanford.poppy.opacity(0.28) : Color.secondary.opacity(0.16), lineWidth: 1)
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
        .background(Stanford.lagunita.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Stanford.lagunita.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .disabled(!canEditPlan)
    }

    private func footer(_ sourcePlan: TaskPlan) -> some View {
        HStack(spacing: 10) {
            if canEditPlan {
                Button("Cancel plan") {
                    cancelPlan(sourcePlan)
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .foregroundStyle(Stanford.cardinalRed)

                Spacer(minLength: 8)

                Button("Discard") {
                    syncDraftIfNeeded(force: true)
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .disabled(currentDraft == sourcePlan)

                Button("Save changes") {
                    saveDraft()
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: true))
                .disabled(!canSave)
            } else {
                Text(readOnlyFooterMessage)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
            }
        }
        .controlSize(.small)
        .padding(14)
        .background(Stanford.panelBackground)
    }

    private var readOnlyFooterMessage: String {
        if isTaskRunning {
            return "Canvas is read-only while the task is running."
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

    private var emptyCanvas: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No canvas item")
                .font(Stanford.heading(16))
            Text("Generate or select a plan to open it in the reusable canvas.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(Stanford.caption(12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Stanford.fog.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )
        }
    }

    private func labeledTextEditor(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
                .padding(.top, 7)
            TextEditor(text: text)
                .font(Stanford.caption(12))
                .frame(minHeight: 58)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .background(Stanford.fog.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                )
        }
    }

    private func fieldPreview(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 28)
    }

    private func stepMetadataRow(_ step: TaskPlanStep) -> some View {
        HStack(spacing: 6) {
            Text(step.risk.rawValue.capitalized)
                .foregroundStyle(riskColor(step.risk))
            if !step.likelyTools.isEmpty {
                Text(step.likelyTools.joined(separator: ", "))
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
        .background(Stanford.fog.opacity(isDisabled ? 0 : 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                .background(isSelected ? Stanford.lagunita.opacity(0.14) : Stanford.fog)
                .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Stanford.lagunita.opacity(0.25) : Color.secondary.opacity(0.14), lineWidth: 1)
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
            reason: "Cancelled from canvas."
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
