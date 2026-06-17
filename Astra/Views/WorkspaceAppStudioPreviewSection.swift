import SwiftUI

/// Slice 3: a live preview of the DRAFT app inside the Studio, rendered through the SAME
/// presentation builders a published app uses (via WorkspaceAppDraftPreviewBuilder's deterministic
/// sample data). Shows the dashboard surface (metrics/charts) and any form fields so a builder can
/// see what they're about to publish before committing.
struct WorkspaceAppStudioPreviewSection: View {
    let manifest: WorkspaceAppManifest

    var body: some View {
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest)
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: snapshot.manifest, storageTables: snapshot.storageTables
        )
        let formViews = manifest.views.filter { $0.type == "form" && !$0.formFields.isEmpty }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Preview")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("sample data")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if surface.metrics.isEmpty && surface.charts.isEmpty && formViews.isEmpty {
                Text("No dashboard or form surface to preview yet.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            if !surface.metrics.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(surface.metrics) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.value)
                                .font(Stanford.ui(18, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(metric.label)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
                    }
                }
            }

            ForEach(surface.charts) { chart in
                previewRow(icon: "chart.bar", title: chart.label, detail: "chart")
            }

            ForEach(formViews, id: \.id) { view in
                VStack(alignment: .leading, spacing: 4) {
                    previewRow(icon: "square.and.pencil", title: view.title ?? view.id, detail: "\(view.formFields.count) fields")
                    ForEach(view.formFields, id: \.name) { field in
                        Text("• \(field.label) — \(field.fieldType)\(field.required ? " (required)" : "")")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Slice 6: pipeline / loop / gate visual flow.
            let workflows = manifest.actions.filter { $0.type == "pipeline.run" || $0.type == "loop.run" }
            ForEach(workflows, id: \.id) { workflow in
                VStack(alignment: .leading, spacing: 4) {
                    previewRow(
                        icon: workflow.type == "loop.run" ? "arrow.triangle.2.circlepath" : "arrow.right.circle",
                        title: workflow.label ?? workflow.id,
                        detail: workflow.type == "loop.run" ? "loop ·\u{00a0}\(workflow.maxIterations ?? 0)×" : "pipeline"
                    )
                    ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, stepID in
                        let step = manifest.actions.first { $0.id == stepID }
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(Stanford.caption(10).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Image(systemName: stepIcon(step?.type))
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.lagunita)
                            Text(step?.label ?? stepID)
                                .font(Stanford.caption(11))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(step?.type ?? "unknown")
                                .font(Stanford.caption(10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 6)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func stepIcon(_ type: String?) -> String {
        switch type {
        case "task.createAndRun", "task.createDraft": return "cpu"
        case "task.fanOut": return "rectangle.split.3x1"
        case "rows.reduce": return "arrow.triangle.merge"
        case "gate.humanApproval": return "hand.raised"
        case "gate.agentRecommendation", "gate.expression", "gate.branch": return "checkmark.shield"
        case "appStorage.insert", "appStorage.update", "appStorage.query", "appStorage.delete": return "externaldrive"
        case .some(let value) where value.hasPrefix("capability"): return "antenna.radiowaves.left.and.right"
        default: return "circle"
        }
    }

    private func previewRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.lagunita)
            Text(title)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Text(detail)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
        }
    }
}
