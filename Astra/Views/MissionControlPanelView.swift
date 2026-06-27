import SwiftUI

struct MissionControlPanelView: View {
    let presentation: MissionControlPresentation
    var onApproveCorrection: ((String) -> Void)?
    var onDismissCorrection: ((String) -> Void)?
    var onCreateCorrectionTask: ((String) -> Void)?

    @State private var showAllAssertions = false

    private let assertionCollapsedLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            if !presentation.assertionRows.isEmpty {
                assertionTable
            }
            if let handoff = presentation.latestHandoffSummary, !handoff.isEmpty {
                summaryRow(icon: "arrowshape.turn.up.right", title: "Latest handoff", detail: handoff)
            }
            if let correction = presentation.correction {
                correctionRow(correction)
            } else if let nextAction = presentation.nextAction, !nextAction.isEmpty {
                summaryRow(icon: "arrow.right.circle", title: "Next action", detail: nextAction)
            }
        }
        .padding(14)
        .background(Stanford.cardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MissionControlPanel")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
                // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
                HStack(alignment: .top, spacing: 8) {
                    Text("Mission Control")
                        .font(Stanford.ui(16, weight: .semibold))
                        .foregroundStyle(Stanford.black)
                    Text(presentation.statusTitle)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(presentation.objective)
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(presentation.statusSummary)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if presentation.isSourceBacked {
                Label("\(presentation.sourcePointerCount)", systemImage: "link")
                    .labelStyle(.titleAndIcon)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)
                    .help("Source pointers backing this mission summary")
            }
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metric("Assertions", "\(presentation.assertionRows.count)")
                metric("Files", "\(presentation.changedFileCount) changed")
                metric("Artifacts", "\(presentation.artifactCount)")
                if let budgetSummary = presentation.budgetSummary {
                    metric("Budget", budgetSummary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                metric("Assertions", "\(presentation.assertionRows.count)")
                HStack(spacing: 10) {
                    metric("Files", "\(presentation.changedFileCount) changed")
                    metric("Artifacts", "\(presentation.artifactCount)")
                }
                if let budgetSummary = presentation.budgetSummary {
                    metric("Budget", budgetSummary)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    private var visibleAssertionRows: [MissionControlAssertionRow] {
        if showAllAssertions {
            return presentation.assertionRows
        }
        return Array(presentation.assertionRows.prefix(assertionCollapsedLimit))
    }

    private var assertionTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Assertions")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(visibleAssertionRows) { assertion in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: assertionIcon(assertion.status))
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(assertionColor(assertion.status))
                        .frame(width: 14)
                        .help(assertion.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assertion.description)
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(Stanford.black)
                            .lineLimit(1)
                        Text("\(assertion.id) · \(assertion.method) · \(assertion.required ? "required" : "optional")")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(assertion.description), \(assertion.status)")
                if assertion.id != visibleAssertionRows.last?.id {
                    Divider().overlay(Color.primary.opacity(0.05))
                }
            }
            if presentation.assertionRows.count > assertionCollapsedLimit {
                Divider().overlay(Color.primary.opacity(0.05))
                Button {
                    showAllAssertions.toggle()
                } label: {
                    Text(showAllAssertions
                        ? "Show fewer"
                        : "Show all (\(presentation.assertionRows.count))")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
        }
    }

    private func correctionRow(_ correction: MissionControlCorrection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow(
                icon: "wrench.and.screwdriver",
                title: "Correction",
                detail: "Assertion \(correction.failedAssertionID): \(correction.suggestedRepair)"
            )
            HStack(spacing: 8) {
                if let onApproveCorrection {
                    Button("Approve") { onApproveCorrection(correction.correctiveStepID) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: correction.status == "proposed", color: Stanford.lagunita))
                        .controlSize(.small)
                }
                if let onCreateCorrectionTask {
                    Button("Create Task") { onCreateCorrectionTask(correction.correctiveStepID) }
                        .buttonStyle(StanfordButtonStyle(isPrimary: false, color: Stanford.lagunita))
                        .controlSize(.small)
                }
                if let onDismissCorrection {
                    Button("Dismiss") { onDismissCorrection(correction.correctiveStepID) }
                        .buttonStyle(.plain)
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summaryRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.black.opacity(0.78))
                    .lineLimit(2)
                    .help(detail)
            }
        }
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .verified: Stanford.paloAltoGreen
        case .attention: Stanford.poppy
        case .failed: Stanford.cardinalRed
        case .running: Stanford.statusInfo
        case .neutral: Stanford.coolGrey
        }
    }

    private var statusIcon: String {
        switch presentation.tone {
        case .verified: "checkmark.seal.fill"
        case .attention: "exclamationmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .neutral: "scope"
        }
    }

    private func assertionIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "passed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "started", "running": "arrow.triangle.2.circlepath"
        default: "circle"
        }
    }

    private func assertionColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "passed": Stanford.paloAltoGreen
        case "failed": Stanford.cardinalRed
        case "started", "running": Stanford.statusInfo
        default: Stanford.coolGrey
        }
    }
}
