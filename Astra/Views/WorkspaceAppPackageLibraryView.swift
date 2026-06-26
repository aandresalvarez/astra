import SwiftUI
import UniformTypeIdentifiers

/// Team library: browse a shared folder of `.astra-app` packages, see each one's install
/// state at a glance, and route a chosen package into the import review (full
/// dependency/permission governance) before it installs. The discovery service already
/// existed and is tested; this is its UI.
///
/// Package SIGNING is intentionally deferred (spec §18.15/§25.7: only if remote/team
/// distribution is in scope) — discovery + a governed install is the local team-library
/// workflow. ASTRA is not App-Sandboxed, so a remembered folder path re-reads across
/// launches without a security-scoped bookmark.
struct WorkspaceAppPackageLibraryView: View {
    let workspace: Workspace
    var onInstalled: (WorkspaceApp) -> Void
    var onCancel: () -> Void

    @AppStorage("astra.workspaceApp.libraryPath") private var libraryPath = ""
    @State private var entries: [WorkspaceAppPackageLibraryEntry] = []
    @State private var pickerPresented = false
    @State private var selection: LibrarySelection?
    @State private var statusMessage = ""

    private struct LibrarySelection: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    folderRow
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(entries, id: \.packageURL) { entry in
                            entryCard(entry)
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppPackageLibraryView")
        .fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: handlePickFolder)
        .sheet(item: $selection) { selection in
            WorkspaceAppImportReviewView(
                workspace: workspace,
                initialPackageURL: selection.url,
                onInstalled: { app in self.selection = nil; refresh(); onInstalled(app) },
                onCancel: { self.selection = nil }
            )
        }
        .onAppear { refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "books.vertical")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Library").font(Stanford.heading(20)).foregroundStyle(.primary)
                Text(workspace.name).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !statusMessage.isEmpty {
                Text(statusMessage).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            Button("Done", action: onCancel).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(libraryPath.isEmpty ? "No shared folder chosen" : libraryPath)
                .font(Stanford.caption(12))
                .foregroundStyle(libraryPath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose folder…") { pickerPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(libraryPath.isEmpty ? "Pick a shared folder of ASTRA app packages." : "No ASTRA app packages found in this folder.")
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.primary)
            Text("Apps are shared as .astra-app packages. Choose a folder your team syncs to discover them here.")
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func entryCard(_ entry: WorkspaceAppPackageLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.appName ?? entry.packageURL.lastPathComponent)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let version = entry.version {
                    Text("v\(version)").font(Stanford.caption(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(installStateLabel(entry.installState))
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let first = entry.blockerMessages.first {
                Text(first).font(Stanford.caption(11)).foregroundStyle(Stanford.statusWarn).lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Review & install") { selection = LibrarySelection(url: entry.packageURL) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func installStateLabel(_ state: WorkspaceAppPackageInstallState) -> String {
        switch state {
        case .decoded, .validated: return "Available"
        case .needsDependencyMapping: return "Needs setup"
        case .needsPermissionReview: return "Needs review"
        case .readyToInstall: return "Ready"
        case .installedDisabled: return "Installed (disabled)"
        case .installedReady: return "Installed"
        case .blocked: return "Blocked"
        }
    }

    // MARK: - Actions

    private func handlePickFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            libraryPath = url.path
            refresh()
        case .failure(let error):
            statusMessage = "Couldn't open folder: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        guard !libraryPath.isEmpty else { entries = []; return }
        let url = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        entries = WorkspaceAppPackageLibraryService().discoverPackages(in: url)
        statusMessage = entries.isEmpty ? "" : "\(entries.count) package\(entries.count == 1 ? "" : "s")"
    }
}
