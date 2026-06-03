import SwiftUI

struct TaskDecisionDockView: View {
    let presentation: TaskDecisionDockPresentation
    @Binding var isExpanded: Bool
    var onAction: (TaskDecisionDockAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 5) {
            summaryRow

            if presentation.hasDetails, isExpanded {
                expandedDetails
            }
        }
        .padding(.horizontal, TaskComposerPresentation.decisionRowHorizontalPadding)
        .padding(.vertical, 8)
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
            HStack(alignment: .top, spacing: TaskComposerPresentation.decisionRowSpacing) {
                leadingStatus
                Spacer(minLength: 12)
                if presentation.hasActions {
                    actionsView
                        .padding(.top, 1)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                leadingStatus
                if presentation.hasActions {
                    HStack {
                        Spacer(minLength: 0)
                        actionsView
                    }
                }
            }
        }
    }

    private var leadingStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon

            VStack(alignment: .leading, spacing: 4) {
                titleAndSummary
                if presentation.hasDetails, !isExpanded {
                    detailsToggle
                        .padding(.top, 1)
                }
            }
            .layoutPriority(1)
        }
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

    private var titleAndSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
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
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailsToggle

            VStack(alignment: .leading, spacing: 6) {
                ForEach(presentation.details) { detail in
                    detailRow(detail)
                }
            }
            .accessibilityIdentifier("TaskDecisionDockDetails")
        }
        .padding(.leading, TaskComposerPresentation.decisionIconFrame + 10)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private var detailsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(10, weight: .semibold))
                    .frame(width: 11)
                Text(isExpanded ? "Hide details" : detailsToggleTitle)
                    .font(Stanford.caption(11).weight(.semibold))
                Text(detailSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isExpanded {
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(toneColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TaskDecisionDockDetailsToggle")
    }

    private var actionsView: some View {
        HStack(spacing: 6) {
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

    @ViewBuilder
    private func actionButton(_ action: TaskDecisionDockAction, isPrimary: Bool) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .font(Stanford.caption(isPrimary ? 13 : 12).weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(buttonForeground(isPrimary: isPrimary, isEnabled: action.isEnabled))
                .padding(.horizontal, isPrimary ? 13 : 10)
                .padding(.vertical, isPrimary ? 7 : 6)
                .background(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .fill(buttonBackground(isPrimary: isPrimary, isEnabled: action.isEnabled))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(buttonStroke(isPrimary: isPrimary, isEnabled: action.isEnabled), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.025)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help("More task decisions")
        .accessibilityLabel("More task decisions")
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

    private var detailsToggleTitle: String {
        "Details"
    }

    private var toneColor: Color {
        metricColor(presentation.tone)
    }

    private func buttonForeground(isPrimary: Bool, isEnabled: Bool) -> Color {
        if !isEnabled {
            return Stanford.coolGrey.opacity(0.7)
        }
        return isPrimary ? .white : Stanford.black.opacity(0.84)
    }

    private func buttonBackground(isPrimary: Bool, isEnabled: Bool) -> Color {
        if !isEnabled {
            return Stanford.fog.opacity(0.8)
        }
        return isPrimary ? toneColor : Color.primary.opacity(0.025)
    }

    private func buttonStroke(isPrimary: Bool, isEnabled: Bool) -> Color {
        if !isEnabled {
            return Color.secondary.opacity(0.12)
        }
        return isPrimary ? toneColor.opacity(0) : Color.secondary.opacity(0.18)
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
        case .addVerification:
            "AddVerificationButton"
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
