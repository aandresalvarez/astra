import SwiftUI

/// Read-only "Inspect manifest" sheet for App Studio — the detail behind the live preview:
/// identity, sources, storage, actions, automations, permissions. Reuses
/// `WorkspaceAppManifestInspectorPresentationBuilder` (the same presentation the old form's
/// Advanced disclosure used). Power-user surface; nothing here mutates the draft.
struct WorkspaceAppManifestInspectorView: View {
    let manifest: WorkspaceAppManifest
    let validationReport: WorkspaceAppManifestValidationReport
    var onDismiss: () -> Void

    var body: some View {
        let inspector = WorkspaceAppManifestInspectorPresentationBuilder.presentation(
            manifest: manifest,
            validationReport: validationReport
        )
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("Identity", rows: inspector.identity)
                    group("Sources", rows: inspector.sources)
                    group("Storage", rows: inspector.storage)
                    group("Actions", rows: inspector.actions)
                    group("Automations", rows: inspector.automations)
                    group("Permissions", rows: inspector.permissions)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppManifestInspectorView")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.app.name)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Manifest")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Done", action: onDismiss).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Stanford.cardBackground)
    }

    private func group(_ title: String, rows: [WorkspaceAppInspectorRowPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Stanford.caption(12).weight(.semibold)).foregroundStyle(.primary)
                Text("\(rows.count)").font(Stanford.caption(11).weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            if rows.isEmpty {
                Text("None").font(Stanford.caption(12)).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.title)
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.detail)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
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
}
