import SwiftUI
import UniformTypeIdentifiers

/// Slice 7: review-before-install UI for an exported `.astra-app` package. Picks a package,
/// builds a `WorkspaceAppPackageImportReview` (validation + trust + dependency mapping + storage),
/// and installs through the governed `WorkspaceAppPackageService` only when the review clears
/// (no blockers, all required dependencies resolvable). Self-contained: takes the target workspace
/// and reads `modelContext` from the environment, so it needs no ContentView wiring.
struct WorkspaceAppImportReviewView: View {
    let workspace: Workspace
    /// When set (e.g. from the package library), the review loads this package on appear
    /// instead of starting at the picker — so library → review → install is one flow.
    var initialPackageURL: URL? = nil
    var onInstalled: (WorkspaceApp) -> Void
    var onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var review: WorkspaceAppPackageImportReview?
    @State private var pickerPresented = false
    @State private var accessingURL: URL?
    @State private var statusMessage = ""
    @State private var didLoadInitial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let review {
                        reviewBody(review)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppImportReviewView")
        .fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.directory], allowsMultipleSelection: false, onCompletion: handlePick)
        .onAppear {
            guard !didLoadInitial, let initialPackageURL else { return }
            didLoadInitial = true
            loadReview(packageURL: initialPackageURL)
        }
        .onDisappear { stopAccessing() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import App").font(Stanford.heading(20)).foregroundStyle(.primary)
                Text(workspace.name).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !statusMessage.isEmpty {
                Text(statusMessage).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            Button("Cancel") { stopAccessing(); onCancel() }.buttonStyle(.borderless)
            Button(action: install) { Label("Install", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled(review?.canInstall != true)
                .help(review?.canInstall == true ? "Install into \(workspace.name)" : "Resolve blockers and required dependencies first")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a .astra-app package to review before installing it into this workspace.")
                .font(Stanford.ui(14)).foregroundStyle(.secondary)
            Button(action: { pickerPresented = true }) { Label("Choose Package…", systemImage: "folder") }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func reviewBody(_ review: WorkspaceAppPackageImportReview) -> some View {
        section("Package") {
            infoRow("Name", review.packageName)
            infoRow("Version", review.version)
            infoRow("Requires ASTRA", "≥ \(review.minimumASTRAVersion)")
            infoRow("Permission mode", review.permissionMode.rawValue)
            infoRow("Storage tables", review.storageTables.isEmpty ? "None" : review.storageTables.map(\.name).joined(separator: ", "))
        }

        if let trust = review.trustSummary {
            section("Trust") {
                infoRow("Signer", trust.signerIdentity)
                infoRow("Status", trust.statusLabel)
            }
        }

        if review.report.issues.isEmpty {
            WorkspaceAppDetailNotice(title: "Ready to install", message: "The package validated cleanly. It installs as a draft until you enable it.", systemImage: "checkmark.seal")
        } else {
            section("Validation — \(review.report.blockers.count) blockers, \(review.report.warnings.count) warnings") {
                ForEach(Array(review.report.issues.enumerated()), id: \.offset) { _, issue in
                    WorkspaceAppDetailNotice(
                        title: issue.severity.rawValue.capitalized,
                        message: "\(issue.path): \(issue.message)",
                        systemImage: issue.severity == .blocker ? "xmark.octagon" : "exclamationmark.triangle"
                    )
                }
            }
        }

        if !review.dependencyMappings.isEmpty {
            section("Dependencies") {
                ForEach(review.dependencyMappings) { dep in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: dep.isMapped ? "checkmark.circle" : (dep.isRequired ? "exclamationmark.triangle" : "circle"))
                            .font(Stanford.caption(12))
                            .foregroundStyle(dep.isMapped ? Stanford.paloAltoGreen : (dep.isRequired ? Color.red : Color.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dep.familyName).font(Stanford.caption(12).weight(.medium)).foregroundStyle(.primary)
                            Text(dep.operationSummary).font(Stanford.caption(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(dep.statusLabel).font(Stanford.caption(11)).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Button("Choose a different package…") { stopAccessing(); self.review = nil; pickerPresented = true }
            .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadReview(packageURL: url)
        case .failure(let error):
            statusMessage = "Couldn't open package: \(error.localizedDescription)"
        }
    }

    private func loadReview(packageURL url: URL) {
        stopAccessing()
        accessingURL = url.startAccessingSecurityScopedResource() ? url : nil
        let built = WorkspaceAppPackageImportReviewer.review(packageURL: url)
        review = built
        statusMessage = built.canInstall ? "Ready to install." : "Resolve the issues below before installing."
    }

    private func install() {
        guard let review, review.canInstall else { return }
        do {
            let result = try WorkspaceAppPackageService().importPackage(at: review.packageURL, into: workspace, modelContext: modelContext)
            stopAccessing()
            onInstalled(result.app)
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func stopAccessing() {
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Stanford.caption(13).weight(.semibold)).foregroundStyle(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Stanford.caption(12).weight(.medium)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(Stanford.caption(12)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
