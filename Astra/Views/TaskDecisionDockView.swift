import SwiftUI

struct TaskDecisionDockView: View {
    let presentation: TaskDecisionDockPresentation
    @Binding var isExpanded: Bool
    var onAction: (TaskDecisionDockAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if !presentation.metrics.isEmpty {
                metricsRow
            }

            if presentation.hasDetails {
                detailsDisclosure
            }
        }
        .padding(.horizontal, TaskComposerPresentation.decisionRowHorizontalPadding)
        .padding(.vertical, TaskComposerPresentation.decisionRowVerticalPadding)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            Capsule()
                .fill(toneColor.opacity(0.76))
                .frame(width: TaskComposerPresentation.decisionAccentWidth)
                .padding(.vertical, TaskComposerPresentation.decisionAccentVerticalInset)
                .padding(.leading, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TaskDecisionDock")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: TaskComposerPresentation.decisionRowSpacing) {
                headerText
                Spacer(minLength: 8)
                actionsView
            }

            VStack(alignment: .leading, spacing: 10) {
                headerText
                HStack {
                    Spacer(minLength: 0)
                    actionsView
                }
            }
        }
    }

    private var headerText: some View {
        HStack(alignment: .top, spacing: TaskComposerPresentation.decisionRowSpacing) {
            Image(systemName: presentation.icon)
                .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
                .foregroundStyle(toneColor)
                .frame(
                    width: TaskComposerPresentation.decisionIconFrame,
                    height: TaskComposerPresentation.decisionIconFrame
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(Stanford.body(TaskComposerPresentation.decisionTitleFontSize).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .lineLimit(1)
                Text(presentation.summary)
                    .font(Stanford.caption(TaskComposerPresentation.decisionDetailFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
        }
    }

    private var actionsView: some View {
        HStack(spacing: 8) {
            ForEach(presentation.secondaryActions) { action in
                actionButton(action, isPrimary: false)
            }

            if let primary = presentation.primaryAction {
                actionButton(primary, isPrimary: true)
            }

            if !presentation.overflowActions.isEmpty {
                overflowMenu
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metricsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presentation.metrics) { metric in
                    metricView(metric)
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("TaskDecisionDockMetrics")
    }

    private func metricView(_ metric: TaskDecisionDockMetric) -> some View {
        HStack(spacing: 5) {
            Text(metric.title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(metric.value)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(metricColor(metric.tone))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(metricColor(metric.tone).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var detailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10, weight: .semibold))
                        .frame(width: 12)
                    Text(isExpanded ? "Hide details" : detailsToggleTitle)
                        .font(Stanford.caption(11).weight(.semibold))
                    Text(detailSummary)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(toneColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TaskDecisionDockDetailsToggle")

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(presentation.details) { detail in
                        detailRow(detail)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
                .accessibilityIdentifier("TaskDecisionDockDetails")
            }
        }
    }

    private func detailRow(_ detail: TaskDecisionDockDetail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: detail.systemImage)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(metricColor(detail.tone))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail.summary)
                    .font(detail.isMonospaced ? Stanford.caption(11).monospaced() : Stanford.caption(12))
                    .foregroundStyle(Stanford.black.opacity(0.78))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionButton(_ action: TaskDecisionDockAction, isPrimary: Bool) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: isPrimary, color: isPrimary ? toneColor : Stanford.lagunita))
        .controlSize(.small)
        .disabled(!action.isEnabled)
        .help(action.help ?? action.title)
        .accessibilityIdentifier(accessibilityIdentifier(for: action))
        .accessibilityLabel(action.title)
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(presentation.overflowActions) { action in
                Button {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!action.isEnabled)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(Stanford.coolGrey)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.035)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("More task decisions")
        .accessibilityLabel("More task decisions")
    }

    private var detailSummary: String {
        let titles = presentation.details.reduce(into: [String]()) { output, detail in
            guard !output.contains(detail.title) else { return }
            output.append(detail.title)
        }
        guard !titles.isEmpty else { return "" }
        let visible = Array(titles.prefix(2))
        let hiddenCount = titles.count - visible.count
        if hiddenCount > 0 {
            return visible.joined(separator: " · ") + " · +\(hiddenCount)"
        }
        return visible.joined(separator: " · ")
    }

    private var detailsToggleTitle: String {
        if presentation.details.contains(where: { ["mission-control", "task-status"].contains($0.id) }) {
            return "Mission & status"
        }
        return "Review details"
    }

    private var toneColor: Color {
        metricColor(presentation.tone)
    }

    private func metricColor(_ tone: TaskDecisionDockTone) -> Color {
        switch tone {
        case .neutral:
            Stanford.coolGrey
        case .running:
            Stanford.lagunita
        case .attention:
            Stanford.poppy
        case .failed:
            Stanford.failed
        case .verified, .closed:
            Stanford.paloAltoGreen
        }
    }

    private func accessibilityIdentifier(for action: TaskDecisionDockAction) -> String {
        switch action.kind {
        case .stop:
            "CancelTaskButton"
        case .allowOnce, .approveResult, .dismissReview:
            "ApproveTaskButton"
        case .allowSimilar:
            "ApproveSimilarTaskButton"
        case .openPlan:
            "OpenPlanButton"
        case .runApprovedPlan:
            action.title == "Run remaining plan" ? "RunRemainingPlanButton" : "ApproveNextPlanStepButton"
        case .runTask:
            "RunTaskButton"
        case .retry:
            "RetryTaskButton"
        case .resume:
            "ResumeTaskButton"
        case .openArtifact:
            "OpenArtifactButton"
        case .closeTask, .closeAnyway, .closeWithoutRunningPlan:
            "CloseTaskButton"
        case .reopenTask:
            "ReopenTaskButton"
        case .approveCorrection:
            "ApproveCorrectionButton"
        case .createCorrectionTask:
            "CreateCorrectionTaskButton"
        case .dismissCorrection:
            "DismissCorrectionButton"
        }
    }
}
