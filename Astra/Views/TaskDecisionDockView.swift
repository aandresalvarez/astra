import SwiftUI

struct TaskDecisionDockView: View {
    let presentation: TaskDecisionDockPresentation
    @Binding var isExpanded: Bool
    var onAction: (TaskDecisionDockAction) -> Void

    var body: some View {
        summaryRow
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

    private var summaryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: TaskComposerPresentation.decisionRowSpacing) {
                leadingStatus(includeUtilities: true)
                Spacer(minLength: 12)
                if hasDecisionActions {
                    decisionActionsView
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                leadingStatus(includeUtilities: false)
                actionRail
            }
        }
    }

    private var actionRail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                if hasUtilityActions {
                    utilityActionsView
                }

                Spacer(minLength: 8)

                if hasDecisionActions {
                    decisionActionsView
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if hasUtilityActions {
                    utilityActionsView
                }
                if hasDecisionActions {
                    decisionActionsView
                }
            }
        }
    }

    private func leadingStatus(includeUtilities: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            statusTitleCluster

            if includeUtilities, presentation.showsDetailsToggle {
                detailsToggle
            }

            if includeUtilities, hasUtilityActions {
                utilityActionsView
            }
        }
        .layoutPriority(1)
    }

    private var statusTitleCluster: some View {
        HStack(alignment: .center, spacing: 7) {
            statusIcon
            Text(presentation.title)
                .font(Stanford.body(TaskComposerPresentation.decisionTitleFontSize).weight(.semibold))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
        }
        .help(presentation.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.summary)
    }

    private var statusIcon: some View {
        Image(systemName: presentation.icon)
            .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
            .foregroundStyle(toneColor)
            .frame(
                width: TaskComposerPresentation.decisionIconFrame,
                height: TaskComposerPresentation.decisionIconFrame
            )
    }

    private var hasUtilityActions: Bool {
        !presentation.utilityActions.isEmpty
    }

    private var hasDecisionActions: Bool {
        presentation.primaryAction != nil || !presentation.secondaryDecisionActions.isEmpty
    }

    private var utilityActionsView: some View {
        HStack(spacing: 8) {
            ForEach(presentation.utilityActions) { action in
                utilityActionButton(action)
            }
        }
    }

    private var decisionActionsView: some View {
        HStack(spacing: 6) {
            ForEach(presentation.secondaryDecisionActions) { action in
                actionButton(action, isPrimary: false)
            }

            if let primary = presentation.primaryAction {
                actionButton(primary, isPrimary: true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var detailsToggle: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle")
                    .font(Stanford.ui(10, weight: .semibold))
                    .frame(width: 11)
                Text("Details")
                    .font(Stanford.caption(11).weight(.semibold))
                Text(detailSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(toneColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isExpanded, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            detailsPopover
        }
        .accessibilityIdentifier("TaskDecisionDockDetailsToggle")
        .accessibilityLabel("Show run details")
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Run details")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Spacer(minLength: 12)
                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Stanford.fog.opacity(0.36))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(presentation.details) { detail in
                        detailRow(detail)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260)
            .accessibilityIdentifier("TaskDecisionDockDetails")
        }
        .frame(width: 360)
        .accessibilityIdentifier("TaskDecisionDockDetailsPopover")
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
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func utilityActionButton(_ action: TaskDecisionDockAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .font(Stanford.caption(11).weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Stanford.coolGrey)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .help(action.help ?? action.title)
        .accessibilityIdentifier(accessibilityIdentifier(for: action))
        .accessibilityLabel(action.title)
    }

    @ViewBuilder
    private func actionButton(_ action: TaskDecisionDockAction, isPrimary: Bool) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .font(Stanford.caption(isPrimary ? 13 : 12).weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(buttonForeground(action, isPrimary: isPrimary))
                .padding(.horizontal, isPrimary ? 13 : (isQuiet(action) ? 4 : 10))
                .padding(.vertical, isPrimary ? 7 : 6)
                .background(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .fill(buttonBackground(action, isPrimary: isPrimary))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(buttonStroke(action, isPrimary: isPrimary), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .help(action.help ?? action.title)
        .accessibilityIdentifier(accessibilityIdentifier(for: action))
        .accessibilityLabel(action.title)
    }

    private var detailSummary: String {
        let titles = presentation.details.reduce(into: [String]()) { output, detail in
            let title = compactDetailTitle(detail.title)
            guard !output.contains(title) else { return }
            output.append(title)
        }
        guard !titles.isEmpty else { return "" }
        let visible = Array(titles.prefix(2))
        let hiddenCount = titles.count - visible.count
        if hiddenCount > 0 {
            return visible.joined(separator: " · ") + " · +\(hiddenCount)"
        }
        return visible.joined(separator: " · ")
    }

    private var toneColor: Color {
        metricColor(presentation.tone)
    }

    private func buttonForeground(_ action: TaskDecisionDockAction, isPrimary: Bool) -> Color {
        if !action.isEnabled {
            return Stanford.coolGrey.opacity(0.7)
        }
        if isQuiet(action) {
            return action.kind == .dismissCorrection ? Stanford.failed : Stanford.coolGrey
        }
        return isPrimary ? .white : Stanford.black.opacity(0.84)
    }

    private func buttonBackground(_ action: TaskDecisionDockAction, isPrimary: Bool) -> Color {
        if !action.isEnabled {
            return Stanford.fog.opacity(0.8)
        }
        if isQuiet(action) {
            return .clear
        }
        return isPrimary ? toneColor : Color.primary.opacity(0.025)
    }

    private func buttonStroke(_ action: TaskDecisionDockAction, isPrimary: Bool) -> Color {
        if !action.isEnabled {
            return Color.secondary.opacity(0.12)
        }
        if isQuiet(action) {
            return .clear
        }
        return isPrimary ? toneColor.opacity(0) : Color.secondary.opacity(0.18)
    }

    private func isQuiet(_ action: TaskDecisionDockAction) -> Bool {
        switch action.kind {
        case .closeTask, .closeAnyway, .closeWithoutRunningPlan, .dismissCorrection:
            true
        case .stop,
             .allowOnce,
             .allowSimilar,
             .approveResult,
             .dismissReview,
             .approveCorrection,
             .createCorrectionTask,
             .openPlan,
             .runApprovedPlan,
             .runTask,
             .retry,
             .resume,
             .openArtifact,
             .reopenTask:
            false
        }
    }

    private func compactDetailTitle(_ title: String) -> String {
        switch title {
        case "Active step":
            "Step"
        case "Permission scope":
            "Scope"
        default:
            title
        }
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
