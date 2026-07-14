import SwiftUI

struct TaskDecisionDockView<ExtendedDetails: View>: View {
    let presentation: TaskDecisionDockPresentation
    @Binding var isExpanded: Bool
    var onAction: (TaskDecisionDockAction) -> Void
    /// Opens the app-level diagnostics surface from the details footer.
    var onOpenDiagnostics: (() -> Void)?
    /// The full run-activity sections (tools, policy, technical output,
    /// stats, …) injected by the owner. The dock's Details popover is the
    /// single run inspector for the latest finished run — the thread no
    /// longer renders a second "Details" disclosure for it.
    @ViewBuilder var extendedDetails: () -> ExtendedDetails

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

    /// The rail must carry the Details toggle in the compact (wrapped)
    /// layouts: the thread renders no run-details disclosure while the dock
    /// is visible, so this toggle is the only entry point to the inspector
    /// at narrow widths.
    private var actionRail: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                if presentation.showsDetailsToggle {
                    detailsToggle
                }
                if hasUtilityActions {
                    utilityActionsView
                }

                Spacer(minLength: 8)

                if hasDecisionActions {
                    decisionActionsView
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if presentation.showsDetailsToggle {
                    detailsToggle
                }
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

    /// One-line status cluster per the decision-dock spec: title plus compact
    /// evidence inline; the explanatory summary lives in `.help`, VoiceOver,
    /// and the details popover instead of a visible second line.
    private var statusTitleCluster: some View {
        HStack(alignment: .center, spacing: 7) {
            statusIcon
            Text(presentation.title)
                .font(Stanford.body(TaskComposerPresentation.decisionTitleFontSize).weight(.semibold))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
            if TaskComposerPresentation.decisionSummaryVisibleInCompactRow {
                summaryText
            } else if let meta = presentation.compactMeta {
                Text("· \(meta)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(presentation.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(accessibilitySummary)
    }

    private var summaryText: some View {
        Text(presentation.summary)
            .font(Stanford.caption(12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var accessibilitySummary: String {
        guard let meta = presentation.compactMeta, !meta.isEmpty else {
            return presentation.summary
        }
        return "\(meta). \(presentation.summary)"
    }

    private var statusIcon: some View {
        Image(systemName: presentation.icon)
            .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
            .foregroundStyle(statusIconColor)
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
                // No summary line here: for failure states the summary IS the
                // banner text sitting right above the dock — repeating it in
                // the inspector reads as noise. It stays in `.help` and
                // accessibility.
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(presentation.details) { detail in
                        detailRow(detail)
                    }
                    extendedDetails()
                }
                .padding(12)
            }
            .frame(maxHeight: TaskComposerPresentation.decisionDetailsMaxHeight)
            .accessibilityIdentifier("TaskDecisionDockDetails")

            if let onOpenDiagnostics {
                Divider()
                HStack {
                    Spacer(minLength: 12)
                    Button {
                        isExpanded = false
                        onOpenDiagnostics()
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(Stanford.lagunita)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the task's diagnostic files for deep debugging")
                    .accessibilityIdentifier("TaskDecisionDockOpenDiagnostics")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: TaskComposerPresentation.decisionDetailsWidth)
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
                .font(Stanford.caption(12).weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(buttonForeground(action, isPrimary: isPrimary))
                .padding(.horizontal, isPrimary ? 11 : (isQuiet(action) ? 4 : 9))
                .padding(.vertical, 5)
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

    private var toneColor: Color {
        metricColor(presentation.tone)
    }

    /// The leading status glyph is non-tappable, so it never wears the interactive
    /// accent: the running tone drops to the info tint instead of lagunita.
    private var statusIconColor: Color {
        presentation.tone == .running ? Stanford.statusInfo : toneColor
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
        case .closeTask, .closeAnyway, .closeWithoutRunningPlan, .dismissCorrection, .reportProblem:
            true
        case .stop,
             .allowOnce,
             .allowSimilar,
             .reviewGitPublish,
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
             .reopenTask,
             .switchRuntime:
            false
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
        case .success, .verified, .closed:
            Stanford.statusHealthy
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
        case .reviewGitPublish:
            "ReviewGitPublishButton"
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
        case .reportProblem:
            FeedbackReportAccessibilityID.reportProblem
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
        case .switchRuntime:
            "SwitchRuntimeButton"
        }
    }
}
