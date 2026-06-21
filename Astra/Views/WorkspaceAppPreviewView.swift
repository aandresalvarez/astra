import SwiftUI

/// Full interactive Preview of a DRAFT Workspace App, presented as a sheet from App Studio's
/// "Preview" button. It renders the exact same `WorkspaceAppSurfaceView` a published app uses, but
/// every action runs through a `WorkspaceAppPreviewRunner` sandbox: storage CRUD mutates an
/// in-memory table store (so Add/Edit/Delete/List really work), while tasks, connector writes,
/// exports, URL/clipboard/notification actions are simulated with a "(preview — …)" summary and
/// touch nothing real. Nothing is published or saved.
struct WorkspaceAppPreviewView: View {
    let manifest: WorkspaceAppManifest
    var onClose: (() -> Void)?
    /// Minimum width. The sheet uses the roomy default; the docked preview shelf passes a
    /// smaller floor so the chat column beside it isn't crushed on narrower windows.
    var minWidth: CGFloat = 680

    @State private var runner: WorkspaceAppPreviewRunner
    @State private var snapshot: WorkspaceAppDetailDataSnapshot

    init(manifest: WorkspaceAppManifest, onClose: (() -> Void)? = nil, minWidth: CGFloat = 680) {
        self.manifest = manifest
        self.onClose = onClose
        self.minWidth = minWidth
        let runner = WorkspaceAppPreviewRunner(manifest: manifest)
        _runner = State(initialValue: runner)
        _snapshot = State(initialValue: runner.snapshot())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    banner
                    WorkspaceAppSurfaceView(
                        snapshot: snapshot,
                        onRunAction: { action, manifest, input in
                            try runner.run(action, manifest: manifest, input: input)
                        },
                        onReload: { snapshot = runner.snapshot() }
                    )
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: minWidth, minHeight: 560)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppPreviewView")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(Stanford.ui(18, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.app.name)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Preview · sandbox")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button(action: resetSampleData) {
                Label("Reset sample data", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Restore the preview's sample rows")

            Button("Done") { onClose?() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Stanford.cardBackground)
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.lagunita)
            Text("Sample data — nothing is saved. Storage edits run against an in-memory copy; tasks, connector writes, exports, and links are simulated.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.lagunita.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resetSampleData() {
        runner.reset()
        snapshot = runner.snapshot()
    }
}
