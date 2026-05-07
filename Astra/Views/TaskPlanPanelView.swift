import SwiftUI

enum TaskPlanPhase: String, Sendable {
    case empty
    case draft
    case approved
    case executing
    case completed
    case failed
    case cancelled
}

struct TaskPlanSnapshot: Sendable {
    var plan: TaskPlan?
    var phase: TaskPlanPhase = .empty
    var latestEventAt: Date?
    var approvedAt: Date?
    var executionStartedAt: Date?
    var executionCompletedAt: Date?
    var executionFailedAt: Date?
    var cancellationReason: String?

    init(state: TaskPlanState) {
        plan = state.plan
        latestEventAt = state.latestEventAt
        approvedAt = state.approvedAt
        executionStartedAt = state.executionStartedAt
        executionCompletedAt = state.executionCompletedAt
        executionFailedAt = state.executionFailedAt
        cancellationReason = state.cancellationReason
        switch state.lifecycleStatus {
        case .none: phase = .empty
        case .draft: phase = .draft
        case .approved: phase = .approved
        case .executing: phase = .executing
        case .completed: phase = .completed
        case .failed: phase = .failed
        case .cancelled: phase = .cancelled
        }
    }
}

struct TaskPlanPanelView: View {
    let snapshot: TaskPlanSnapshot
    let runtimeName: String
    let permissionMode: String
    let pendingPermissionRequest: String?
    let isTaskRunning: Bool
    let onSavePlan: (TaskPlan) -> Void
    let onCancelPlan: (TaskPlan) -> Void

    @State private var isEditing = false
    @State private var editedText = ""

    init(
        state: TaskPlanState,
        runtimeName: String,
        permissionMode: String,
        pendingPermissionRequest: String? = nil,
        isTaskRunning: Bool = false,
        onSavePlan: @escaping (TaskPlan) -> Void,
        onCancelPlan: @escaping (TaskPlan) -> Void
    ) {
        snapshot = TaskPlanSnapshot(state: state)
        self.runtimeName = runtimeName
        self.permissionMode = permissionMode
        self.pendingPermissionRequest = pendingPermissionRequest
        self.isTaskRunning = isTaskRunning
        self.onSavePlan = onSavePlan
        self.onCancelPlan = onCancelPlan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Stanford.railPanelSpacing) {
            if let plan = snapshot.plan {
                if isEditing {
                    editView(plan)
                } else {
                    planContent(plan)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No plan yet")
                        .font(Stanford.body(13).weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Enable Plan mode in the composer, then ask ASTRA to propose steps before running.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Stanford.fog)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .tint(Stanford.lagunita)
    }

    private func planContent(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: Stanford.railPanelSpacing) {
            header(plan)
            executionSummary(plan)
            if let pendingPermissionRequest {
                permissionCallout(pendingPermissionRequest)
            }
            stepList(plan)
            actionRow(plan)
        }
    }

    private func header(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text(plan.title)
                    .font(Stanford.heading(15))
                    .lineLimit(2)
            }
            Text(plan.goal)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func executionSummary(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(runtimeName) · \(permissionMode)", systemImage: "server.rack")
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
            HStack(spacing: 6) {
                ForEach(["Write", "Edit", "Bash"], id: \.self) { tool in
                    if plan.steps.contains(where: { $0.likelyTools.contains(tool) }) {
                        Text(tool)
                            .font(Stanford.caption(10).weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(riskColor(.high).opacity(0.1))
                            .foregroundStyle(riskColor(.high))
                            .clipShape(Capsule())
                    }
                }
            }
            if isTaskRunning {
                Text("Progress updates appear here as the runtime emits plan events.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            } else if snapshot.phase == .executing {
                Text(permissionMode == "Review" ? "Review mode pauses after each step. Approve the next step from the chat composer." : "Plan execution is paused with remaining steps.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            } else if snapshot.phase == .failed {
                Text("Plan execution failed. Review the task output, adjust the plan if needed, then retry.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.cardinalRed)
            }
        }
        .padding(10)
        .background(Stanford.fog)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func stepList(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                planStepRow(index: index, step: step)
            }
        }
    }

    private func planStepRow(index: Int, step: TaskPlanStep) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(for: step.status))
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(color(for: step.status))
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(step.title)")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text(step.risk.rawValue.capitalized)
                        .foregroundStyle(riskColor(step.risk))
                    if !step.likelyTools.isEmpty {
                        Text(step.likelyTools.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(Stanford.caption(10).weight(.medium))
            }
        }
        .padding(9)
        .background(color(for: step.status).opacity(step.status == .pending ? 0.04 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func actionRow(_ plan: TaskPlan) -> some View {
        HStack(spacing: 8) {
            Button("Edit") {
                editedText = plan.steps.map(\.title).joined(separator: "\n")
                isEditing = true
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .disabled(isTaskRunning || snapshot.phase == .executing)

            Button("Cancel") {
                onCancelPlan(plan)
            }
            .buttonStyle(StanfordButtonStyle(isPrimary: false))
            .disabled(isTaskRunning || snapshot.phase == .executing)
        }
        .controlSize(.small)
    }

    private func editView(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit plan")
                .font(Stanford.heading(15))
            TextEditor(text: $editedText)
                .font(Stanford.ui(13))
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .background(Stanford.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel") { isEditing = false }
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                Button("Save") {
                    onSavePlan(makeEditedPlan(from: plan))
                    isEditing = false
                }
                .buttonStyle(StanfordButtonStyle())
            }
            .controlSize(.small)
        }
    }

    private func permissionCallout(_ text: String) -> some View {
        Label(text, systemImage: "hand.raised.fill")
            .font(Stanford.caption(12))
            .foregroundStyle(Stanford.poppy)
            .padding(10)
            .background(Stanford.poppy.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func makeEditedPlan(from plan: TaskPlan) -> TaskPlan {
        let titles = editedText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return plan }
        var next = plan
        next.steps = titles.enumerated().map { index, title in
            if index < plan.steps.count {
                var existing = plan.steps[index]
                existing.title = title
                existing.risk = TaskPlanService.inferRisk(from: title)
                existing.likelyTools = TaskPlanService.inferTools(from: title)
                return existing
            }
            return TaskPlanStep(
                id: "step-\(index + 1)",
                title: title,
                risk: TaskPlanService.inferRisk(from: title),
                likelyTools: TaskPlanService.inferTools(from: title)
            )
        }
        return next
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
