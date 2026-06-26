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
            content
        }
        .frame(minWidth: minWidth, minHeight: 560)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppPreviewView")
    }

    /// A dynamic HTML app owns its whole surface and scrolls INTERNALLY, so it FILLS the pane — an
    /// outer ScrollView would pin the WebView to its minimum height and leave dead space below (the
    /// "preview doesn't use the full space" bug). A native declarative app is a vertical stack of
    /// cards, so it keeps the scrolling, width-capped column.
    @ViewBuilder
    private var content: some View {
        if isHTMLApp {
            VStack(alignment: .leading, spacing: 12) {
                banner
                surface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    banner
                    surface
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
    }

    private var isHTMLApp: Bool {
        !(manifest.html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var surface: some View {
        WorkspaceAppSurfaceView(
            snapshot: snapshot,
            onRunAction: { action, manifest, input in
                try runner.run(action, manifest: manifest, input: input)
            },
            onReload: { snapshot = runner.snapshot() }
        )
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
        // A dynamic HTML app has no storage/tasks/connectors — the data-sandbox copy is irrelevant,
        // so show interactive-app copy instead of the misleading "storage edits / simulated" text.
        let bannerText = manifest.html != nil
            ? "Live preview of your interactive app — it runs in a sandbox with no network. Nothing is saved."
            : "Sample data — nothing is saved. Storage edits run against an in-memory copy; tasks, connector writes, exports, and links are simulated."
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.lagunita)
            Text(bannerText)
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
