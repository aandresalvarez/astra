import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

/// Plugin sources on the Plugins surface (Plugins 2.0 R5): the sources this
/// Mac lists plugins from, and what each offers. A plugin is reviewed (its
/// digest shown) and imported from here; adding it to a workspace is then
/// the row's Add, like an imported file. Every row names its source (T14).
///
/// Every side effect goes through `CapabilityCatalogActionService`
/// (`PluginsSurfaceFitnessTests`).
struct PluginSourcesSection: View {
    var workspace: Workspace
    var installed: [PluginPackage]
    var onImported: (CapabilityPackageImportResult) -> Void

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var coordinator = PluginSourceCoordinator.shared
    @State private var location = ""
    @State private var errorMessage: String?
    @State private var confirmingRemoval: String?
    @State private var reviewing: (plugin: SourcedPlugin, review: CapabilityImportReview)?

    private var actions: CapabilityCatalogActionService { CapabilityCatalogActionService() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            HStack(spacing: 8) {
                TextField("Git URL, owner/repo or a folder path", text: $location)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSource)
                Button("Add source", action: addSource)
                    .controlSize(.small)
                    .disabled(location.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem = coordinator.listProblem ?? errorMessage {
                Text(problem)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusError)
            }
            ForEach(coordinator.listings) { listing in
                sourceRow(listing)
                Divider()
            }
        }
        .onAppear { coordinator.reload() }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            if let reviewing {
                CapabilityImportReviewSheet(
                    review: reviewing.review,
                    onCancel: { self.reviewing = nil },
                    onImport: { _ in importReviewed(reviewing.plugin) }
                )
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ listing: PluginSourceListing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: listing.source.kind == .git ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(listing.source.shownName).font(Stanford.ui(13, weight: .semibold))
                    Text(listing.source.shownLocation)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if coordinator.fetching.contains(listing.source.id) {
                    ProgressView().controlSize(.small)
                } else if confirmingRemoval == listing.source.id {
                    Text("Remove this source? Installed plugins stay.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { confirmingRemoval = nil }.controlSize(.small)
                    Button("Remove", role: .destructive) { remove(listing.source) }.controlSize(.small)
                } else {
                    if listing.source.kind == .git {
                        Button("Fetch") { refresh(listing.source) }.controlSize(.small)
                    }
                    Button("Remove") { confirmingRemoval = listing.source.id }.controlSize(.small)
                }
            }
            if let problem = listing.problem {
                Text(problem).font(Stanford.caption(12)).foregroundStyle(.secondary)
            }
            ForEach(listing.plugins) { plugin in
                offeredRow(plugin, listings: coordinator.listings)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func offeredRow(_ plugin: SourcedPlugin, listings: [PluginSourceListing]) -> some View {
        let existing = plugin.package.flatMap { package in installed.first { $0.id == package.id } }
        let update = existing.flatMap { PluginSourceCatalog.update(for: $0, in: listings, provenance: coordinator.provenance) }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.package.map { "\($0.name) \($0.version)" } ?? plugin.entryName)
                    .font(Stanford.ui(13))
                Text(plugin.problem ?? subtitle(plugin))
                    .font(Stanford.caption(11))
                    .foregroundStyle(plugin.problem == nil ? Color.secondary : Stanford.statusError)
                    .lineLimit(2)
            }
            Spacer()
            if plugin.canAdd {
                switch (existing, update) {
                case (nil, _):
                    Button("Review") { review(plugin) }.controlSize(.small)
                case (_, .newer?):
                    Button("Review update") { review(plugin) }.controlSize(.small)
                case (_, .changed?):
                    Button("Changed: review") { review(plugin) }.controlSize(.small)
                default:
                    Text("Installed").font(Stanford.caption(11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 26)
    }

    private func subtitle(_ plugin: SourcedPlugin) -> String {
        let contents = plugin.package?.contentParts.joined(separator: ", ") ?? ""
        let skipped = plugin.unsupported.isEmpty ? "" : " · not brought over: " + plugin.unsupported.joined(separator: ", ")
        return (contents.isEmpty ? "From \(plugin.source.shownName)" : contents) + skipped
    }

    // MARK: - Actions

    private func addSource() {
        let input = location
        errorMessage = nil
        Task {
            do {
                if try await actions.addSource(input) {
                    location = ""
                } else {
                    errorMessage = "That location can't be used. Use an https or ssh git URL without a token, owner/repo, or a folder path; private repositories sign in through git."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh(_ source: PluginSource) {
        errorMessage = nil
        Task {
            do { try await actions.refreshSource(source) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func remove(_ source: PluginSource) {
        confirmingRemoval = nil
        errorMessage = nil
        Task {
            do { try await actions.removeSource(source) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func review(_ plugin: SourcedPlugin) {
        guard let report = actions.review(plugin) else { return }
        reviewing = (plugin, CapabilityImportReview(
            report: report,
            origin: "From \(plugin.source.shownName) · \(plugin.source.shownLocation)",
            digest: plugin.digest,
            unsupported: plugin.unsupported
        ))
    }

    private func importReviewed(_ plugin: SourcedPlugin) {
        reviewing = nil
        errorMessage = nil
        do {
            let result = try actions.importReviewed(plugin, workspace: workspace, modelContext: modelContext)
            onImported(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
