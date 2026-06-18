import SwiftUI

/// Phase 3 of the Studio UX redesign: a read-only "see it" glance embedded in the proposal, so a
/// builder sees the app's dashboard (metric cards + charts) on deterministic sample data without
/// opening the full interactive Preview sheet. Reuses the same surface builder + cards the published
/// app renders, so what you glance here is what you'll get.
struct WorkspaceAppStudioInlinePreview: View {
    let manifest: WorkspaceAppManifest

    var body: some View {
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest)
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: snapshot.manifest, storageTables: snapshot.storageTables
        )
        VStack(alignment: .leading, spacing: 10) {
            if surface.metrics.isEmpty && surface.charts.isEmpty {
                Text("No dashboard to preview — open the full Preview to try this app's actions and data.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Sample data")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                if !surface.metrics.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(surface.metrics) { WorkspaceAppMetricCard(metric: $0) }
                    }
                }
                ForEach(surface.charts) { WorkspaceAppChartCard(chart: $0) }
            }
        }
    }
}
