import SwiftUI

/// Full interactive Preview of a DRAFT Workspace App, presented as a sheet from App Studio's
/// "Preview" button. It renders the exact same `WorkspaceAppSurfaceView` a published app uses, but
/// every action runs through a `WorkspaceAppPreviewRunner` sandbox: storage CRUD mutates an
/// in-memory table store (so Add/Edit/Delete/List really work), while tasks, connector writes,
/// exports, URL/clipboard/notification actions are simulated with a "(preview — …)" summary and
/// touch nothing real. Nothing is published or saved.
struct WorkspaceAppPreviewView: View {
    let manifest: WorkspaceAppManifest
    /// The workspace the draft belongs to. When set, a connector-read app resolves LIVE, READ-ONLY
    /// `astra.read` data (real `gh` PRs, enabled-capability CLI reads) so it can be tested before
    /// publishing. nil (the App Studio Preview SHEET caller) ⇒ connector reads stay simulated.
    var workspace: Workspace?
    var onClose: (() -> Void)?
    /// Minimum width. The sheet uses the roomy default; the docked preview shelf passes a
    /// smaller floor so the chat column beside it isn't crushed on narrower windows.
    var minWidth: CGFloat = 680

    @State private var runner: WorkspaceAppPreviewRunner
    @State private var snapshot: WorkspaceAppDetailDataSnapshot

    init(manifest: WorkspaceAppManifest, workspace: Workspace? = nil, onClose: (() -> Void)? = nil, minWidth: CGFloat = 680) {
        self.manifest = manifest
        self.workspace = workspace
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
            onReload: { snapshot = runner.snapshot() },
            onCapabilityRead: makeCapabilityReadRunner()
        )
    }

    /// Live, READ-ONLY connector read for the preview's `astra.read` bridge — so a connector app (e.g.
    /// a GitHub PR tracker) shows REAL data in the preview instead of "Invalid astra read request".
    ///
    /// It reuses the PUBLISHED read path's full security stack and bypasses ONLY the audit run-record:
    /// the bridge's `resolveRead` allowlist + `WorkspaceAppSurfaceView.htmlManifestValid` fail-closed
    /// gate still front it; bindings are the SAME `.mapped` ones the publish path computes (via
    /// `registry(for: workspace)`, so the preview can resolve nothing a published app with the same
    /// requirements couldn't); and resolution runs the SAME hardened native/CLI clients with the
    /// workspace as cwd. The connector-read rate limiter is preserved here keyed on the runner's STABLE
    /// `sandboxAppID`, so a runaway `setInterval(astra.read)` poller can't flood real `gh`/CLI calls.
    /// The transient `WorkspaceApp`/`WorkspaceAppRun` are never inserted into any `ModelContext`.
    /// Returns nil with no workspace — a live connector read needs one, so reads stay simulated there.
    private func makeCapabilityReadRunner()
    -> ((WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult)? {
        guard let workspace else { return nil }
        let appID = runner.sandboxAppID
        return { action, manifest, input in
            // Rate limit FIRST (mirrors executeAsyncCapabilityRead) — fail closed before any read.
            guard WorkspaceAppConnectorReadRateLimiter.shared.admit(appID: appID) else {
                throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(
                    "\(action.id): connector reads are rate-limited; try again shortly")
            }
            // Transient app — NEVER inserted. Its id MUST equal the synthesized bindings' appID.
            let app = WorkspaceApp(
                id: appID,
                workspaceID: workspace.id,
                logicalID: manifest.app.id,
                name: manifest.app.name,
                manifestRelativePath: "",
                appDirectoryRelativePath: "",
                manifestDigest: ""
            )
            let bindings = WorkspaceAppService().previewDependencyBindings(
                for: manifest.requirements, workspace: workspace, appID: appID, appLogicalID: manifest.app.id)
            // sourceID precedence mirrors executeAsyncCapabilityRead's `normalized(sourceRef, table, table)`.
            let sourceID = [action.sourceRef, input.table, action.table]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? ""
            guard !sourceID.isEmpty else { throw WorkspaceAppActionExecutionError.missingSource }
            let resolved = try await WorkspaceAppSourceResolver().resolveCapabilityReadAsync(
                sourceID: sourceID, app: app, workspace: workspace, manifest: manifest,
                dependencyBindings: bindings,
                input: WorkspaceAppSourceResolutionInput(limit: input.limit, parameters: input.record)
            )
            let run = WorkspaceAppRun(
                workspaceID: workspace.id, appID: appID, appLogicalID: manifest.app.id,
                actionID: action.id, trigger: .test, status: .completed, outputSummary: resolved.outputSummary)
            return WorkspaceAppActionExecutionResult(run: run, rows: resolved.rows, outputSummary: resolved.outputSummary)
        }
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

    /// True when this draft can perform a LIVE connector read here: it's an HTML app (only the HTML
    /// `astra.read` bridge does live reads — a native surface never does), it declares a `capability.read`
    /// action, and a workspace is wired in. Such a preview makes REAL, read-only network calls with the
    /// user's ambient credentials (e.g. `gh`), so the banner must NOT claim "no network".
    private var performsLiveReads: Bool {
        workspace != nil
            && manifest.html != nil
            && manifest.actions.contains { $0.type == "capability.read" }
    }

    private var banner: some View {
        // A dynamic HTML app has no storage/tasks/connectors — the data-sandbox copy is irrelevant,
        // so show interactive-app copy instead of the misleading "storage edits / simulated" text.
        let bannerText: String
        if performsLiveReads {
            // Honest about the live-read trust posture: real read-only connector calls run with your
            // enabled capabilities; writes/storage are still sandboxed and nothing is persisted.
            bannerText = "Live preview — connector reads run live and read-only with your enabled capabilities (e.g. your gh sign-in). Nothing is written or saved."
        } else if manifest.html != nil {
            bannerText = "Live preview of your interactive app — it runs in a sandbox with no network. Nothing is saved."
        } else {
            bannerText = "Sample data — nothing is saved. Storage edits run against an in-memory copy; tasks, connector writes, exports, and links are simulated."
        }
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
