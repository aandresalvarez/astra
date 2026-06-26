import SwiftUI

/// Published-view visualization of a workflow action's ordered steps (pipeline.run / loop.run).
/// Previously the published surface rendered workflows as a single flat button — the step flow only
/// existed in the Studio preview. This card surfaces the same ordered, icon-per-step layout in the
/// live app so a builder can see what a workflow does without opening the Studio.
struct WorkspaceAppWorkflowCard: View {
    let workflow: WorkspaceAppActionSpec
    let manifest: WorkspaceAppManifest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: workflow.type == "loop.run" ? "arrow.triangle.2.circlepath" : "arrow.right.circle")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.lagunita)
                Text(workflow.label ?? workflow.id)
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(workflow.type == "loop.run" ? "loop ·\u{00a0}\(workflow.maxIterations ?? 0)×" : "pipeline")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, stepID in
                let step = manifest?.actions.first { $0.id == stepID }
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Image(systemName: Self.stepIcon(step?.type))
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.lagunita)
                    Text(step?.label ?? stepID)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if step?.inputBinding != nil {
                        Image(systemName: "arrow.down.to.line")
                            .font(Stanford.caption(9))
                            .foregroundStyle(.secondary)
                            .help("Reads app data")
                    }
                    if step?.outputBinding != nil {
                        Image(systemName: "arrow.up.to.line")
                            .font(Stanford.caption(9))
                            .foregroundStyle(.secondary)
                            .help("Captures its output")
                    }
                    Spacer(minLength: 4)
                    Text(step?.type ?? "unknown")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    static func stepIcon(_ type: String?) -> String {
        switch type {
        case "task.createAndRun", "task.createDraft": return "cpu"
        case "task.fanOut": return "rectangle.split.3x1"
        case "rows.reduce": return "arrow.triangle.merge"
        case "gate.humanApproval": return "hand.raised"
        case "gate.agentRecommendation", "gate.expression", "gate.branch": return "checkmark.shield"
        case .some(let value) where value.hasPrefix("appStorage"): return "externaldrive"
        case .some(let value) where value.hasPrefix("capability"): return "antenna.radiowaves.left.and.right"
        default: return "circle"
        }
    }
}
