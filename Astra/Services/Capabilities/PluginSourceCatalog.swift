import Foundation
import ASTRACore

/// One entry a source lists: the plugin it reads to, or why it can't be
/// offered. An entry with a problem is shown with it and offers no Add (T11).
struct SourcedPlugin: Identifiable, Equatable {
    var source: PluginSource
    var entryName: String
    var package: PluginPackage?
    /// What the source plugin has that ASTRA does not run.
    var unsupported: [String]
    var problem: String?
    /// The content digest of `package` as the library will hold it
    /// (`PluginSourceCatalog.contentDigest`): what review shows, what import
    /// checks, and what the approval record is keyed by.
    var digest: String

    var id: String { "\(source.id):\(package?.id ?? "entry:\(entryName)")" }
    var canAdd: Bool { package != nil && problem == nil }

    static func == (lhs: SourcedPlugin, rhs: SourcedPlugin) -> Bool {
        lhs.id == rhs.id && lhs.digest == rhs.digest && lhs.problem == rhs.problem && lhs.unsupported == rhs.unsupported
    }
}

/// A source's entries, or why the source itself can't be read.
struct PluginSourceListing: Identifiable, Equatable {
    var source: PluginSource
    var plugins: [SourcedPlugin]
    var problem: String?
    /// The source holds more than one listing reads (T11): it is refused,
    /// and the coordinator keeps the entries it listed before.
    var exceededReadLimit = false

    var id: String { source.id }
}

/// What a source offers for a plugin installed from it (T7).
enum PluginSourceUpdate: Equatable {
    /// A strictly greater version from the plugin's own source.
    case newer(SourcedPlugin)
    /// The same version with other content: shown as changed, it needs review.
    case changed(SourcedPlugin)
}

enum PluginSourceCatalogError: Error, Equatable, LocalizedError {
    case changedSinceReview
    case noLongerOffered
    case notAddable(String)

    var errorDescription: String? {
        switch self {
        case .changedSinceReview: "The plugin changed in its source since you reviewed it. Review it again."
        case .noLongerOffered: "The source no longer offers this plugin."
        case .notAddable(let problem): problem
        }
    }
}

/// Lists a source's plugins and checks each against the rules a person
/// would otherwise have to check themselves (threat model T5–T10, T14).
enum PluginSourceCatalog {
    /// Every in-repository entry of the source's marketplace file, or the
    /// source root as one plugin when it has none.
    static func listing(
        for source: PluginSource,
        store: PluginSourceStore,
        installed: [PluginPackage]
    ) -> PluginSourceListing {
        let root = store.contentRoot(for: source)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return PluginSourceListing(
                source: source, plugins: [],
                problem: source.kind == .git ? "Not fetched yet." : "The folder is not there."
            )
        }
        // One budget for the whole listing, every plugin's scoped reader
        // included (T11): a folder source has no download or checkout bound.
        let budget = PluginSourceReadBudget()
        let directory = BudgetedPluginDirectory(BrokeredPluginDirectory(root: root, kind: source.kind), budget: budget)
        let provenance = store.provenance()
        let entries: [(name: String, path: String?)]
        switch PluginMarketplace.read(from: directory) {
        case .problem(let problem):
            return PluginSourceListing(source: source, plugins: [], problem: problem)
        case .marketplace(let marketplace):
            entries = marketplace.plugins.map { ($0.name, $0.path) }
        case .none:
            entries = [(source.displayName, "")]
        }
        var plugins = entries.map { entry in
            plugin(named: entry.name, at: entry.path, in: source, directory: directory, installed: installed, provenance: provenance)
        }
        guard !budget.exceeded else {
            return PluginSourceListing(source: source, plugins: [], problem: readLimitProblem, exceededReadLimit: true)
        }
        // Two entries with one ID: neither is offered, so a row always means
        // one definition (T6).
        let ids = plugins.compactMap { $0.package?.id.lowercased() }
        let repeated = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        for index in plugins.indices {
            if let id = plugins[index].package?.id.lowercased(), repeated.contains(id), plugins[index].problem == nil {
                plugins[index].problem = "Another entry in this source has the same ID."
            }
        }
        return PluginSourceListing(source: source, plugins: plugins, problem: nil)
    }

    static let readLimitProblem = "This source holds more than ASTRA reads for plugins "
        + "(\(PluginSourceLimits.totalBytes / 1024 / 1024) MB or \(PluginSourceLimits.totalFiles.formatted()) files), so it wasn't listed."

    static func plugin(
        named name: String,
        at path: String?,
        in source: PluginSource,
        directory: PluginDirectoryReading,
        installed: [PluginPackage],
        provenance: [String: PluginSourceStore.Provenance] = [:]
    ) -> SourcedPlugin {
        var plugin = rawPlugin(named: name, at: path, in: source, directory: directory, installed: installed, provenance: provenance)
        // Problems name paths from the source; they are display text too.
        plugin.problem = plugin.problem.map { PluginSourceDisplayText.clean($0, limit: PluginSourceDisplayText.textLimit).text }
        return plugin
    }

    private static func rawPlugin(
        named rawName: String,
        at path: String?,
        in source: PluginSource,
        directory: PluginDirectoryReading,
        installed: [PluginPackage],
        provenance: [String: PluginSourceStore.Provenance]
    ) -> SourcedPlugin {
        // Every display field from the source is cleaned here, once (T14).
        let (name, nameChange) = PluginSourceDisplayText.clean(rawName, limit: PluginSourceDisplayText.nameLimit)
        func problem(_ text: String) -> SourcedPlugin {
            SourcedPlugin(source: source, entryName: name, package: nil, unsupported: [], problem: text, digest: "")
        }
        guard let path else { return problem("Its source is not a folder in this repository.") }
        let read: PluginSourcePlugin
        do {
            read = try PluginSourcePluginReader.read(at: path, in: directory)
        } catch PluginSourceReadError.unsafePath {
            return problem("Its path leaves the source.")
        } catch PluginSourceReadError.noManifest {
            return problem("No plugin manifest at \(path.isEmpty ? "the source root" : path).")
        } catch PluginSourceReadError.tooLarge(let file) {
            return problem("\(file) is too large to read.")
        } catch {
            return problem("Its manifest can't be read.")
        }
        var package = read.package
        var unsupported = read.unsupported
        let displayChange = PluginSourceDisplayText.clean(&package) ?? nameChange
        package.sourceMetadata = source.metadata
        package.governance = .localDraft()
        // A source plugin's checks and repairs run commands; none runs until
        // the read-only rule covers them (T9). It shows as not checked.
        if !package.prerequisites.isEmpty {
            unsupported.append(package.prerequisites.count == 1 ? "1 setup check (not run)" : "\(package.prerequisites.count) setup checks (not run)")
            package.prerequisites = []
        }
        let digest = contentDigest(package)
        var plugin = SourcedPlugin(
            source: source, entryName: name, package: package,
            unsupported: unsupported, problem: read.problems.first ?? displayChange?.problem, digest: digest
        )
        guard plugin.problem == nil else { return plugin }
        if CapabilityLibrary.trustedBuiltInPackageIDs.contains(where: { $0.lowercased() == package.id.lowercased() }) {
            plugin.problem = "Uses the ID of a plugin ASTRA ships, so it can't replace it."
            return plugin
        }
        let sameID = installed.first { $0.id.lowercased() == package.id.lowercased() }
        if let sameID, !isOwnCopy(sameID, of: source, provenance: provenance) {
            plugin.problem = "A plugin with this ID is installed from somewhere else."
            return plugin
        }
        let report = CapabilityPackageValidator.validate(
            package: package,
            installedPackages: installed.filter { $0.id.lowercased() != package.id.lowercased() },
            checkPrerequisites: false
        )
        plugin.problem = report.blockers.first.map { "\($0.title): \($0.message)" }
        return plugin
    }

    /// A package's digest as the library holds it: filed as local, with
    /// draft governance (`CapabilityGovernanceNormalizer`), so a source's copy
    /// and the installed one compare by content only.
    static func contentDigest(_ package: PluginPackage) -> String {
        var stored = package
        stored.sourceMetadata = .localLibrary()
        _ = CapabilityGovernanceNormalizer.clampToLocalDraft(&stored)
        return (try? CapabilityApprovalDigest.digest(for: stored)) ?? ""
    }

    /// Whether `installed` is the copy `source` installed: its provenance
    /// names the source, for exactly this content. A forget an exit left
    /// pending is settled by this copy first (`Provenance.resolved`).
    static func isOwnCopy(
        _ installed: PluginPackage,
        of source: PluginSource,
        provenance: [String: PluginSourceStore.Provenance]
    ) -> Bool {
        let digest = contentDigest(installed)
        guard let record = provenance[installed.id]?.resolved(installedDigest: digest) else { return false }
        return record.sourceID == source.id && record.names(digest)
    }

    /// Plugin ID → `contentDigest` of each installed copy.
    static func installedDigests(_ installed: [PluginPackage]) -> [String: String] {
        Dictionary(installed.map { ($0.id, contentDigest($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Only from the plugin's own source, only a strictly greater version or
    /// the same version with another digest; a lower one is never offered.
    static func update(
        for installed: PluginPackage,
        in listings: [PluginSourceListing],
        provenance: [String: PluginSourceStore.Provenance]
    ) -> PluginSourceUpdate? {
        guard let listing = listings.first(where: { isOwnCopy(installed, of: $0.source, provenance: provenance) }),
              let offered = listing.plugins.first(where: { $0.package?.id == installed.id && $0.canAdd }),
              let package = offered.package,
              let offeredVersion = SemanticVersion(string: package.version),
              let installedVersion = SemanticVersion(string: installed.version)
        else { return nil }
        if offeredVersion > installedVersion { return .newer(offered) }
        guard offeredVersion == installedVersion else { return nil }
        return contentDigest(installed) == offered.digest ? nil : .changed(offered)
    }

    /// The reviewed package, after confirming the source still offers
    /// exactly what was reviewed (T8). The package returned is the reviewed
    /// copy, never a fresh read of the source.
    static func confirmReviewed(
        _ reviewed: SourcedPlugin,
        store: PluginSourceStore,
        installed: [PluginPackage]
    ) throws -> PluginPackage {
        guard let package = reviewed.package else { throw PluginSourceCatalogError.noLongerOffered }
        let now = listing(for: reviewed.source, store: store, installed: installed)
        if let problem = now.problem { throw PluginSourceCatalogError.notAddable(problem) }
        guard let current = now.plugins.first(where: { $0.package?.id == package.id }) else {
            throw PluginSourceCatalogError.noLongerOffered
        }
        guard current.digest == reviewed.digest else { throw PluginSourceCatalogError.changedSinceReview }
        // What the library holds now may have changed since the listing (an
        // ID installed from elsewhere meanwhile): the rules are checked again.
        if let problem = current.problem { throw PluginSourceCatalogError.notAddable(problem) }
        return package
    }
}

/// The owner of the source list and its fetches. Operations on one source
/// run one after another (T13): a second fetch waits for the first, and
/// Remove cancels a running fetch and waits for it before deleting anything.
@MainActor
final class PluginSourceCoordinator: ObservableObject {
    static let shared = PluginSourceCoordinator()

    @Published private(set) var listings: [PluginSourceListing] = []
    @Published private(set) var fetching: Set<String> = []
    /// Why the source list can't be read, when it can't.
    @Published private(set) var listProblem: String?
    @Published private(set) var provenance: [String: PluginSourceStore.Provenance] = [:]

    let store: PluginSourceStore
    let fetcher: PluginSourceFetcher
    let installedPackages: () -> [PluginPackage]
    private var operations: [String: Task<Void, Error>] = [:]

    init(
        store: PluginSourceStore = PluginSourceStore(),
        fetcher: PluginSourceFetcher = PluginSourceFetcher(),
        installedPackages: @escaping () -> [PluginPackage] = { CapabilityLibrary().installedPackages() }
    ) {
        self.store = store
        self.fetcher = fetcher
        self.installedPackages = installedPackages
    }

    /// Re-reads every source from disk; no network.
    func reload() {
        do {
            let sources = try store.sources()
            let installed = installedPackages()
            // A forget an exit left pending is settled against the library
            // before anything reads the records (T5).
            try? store.resolvePendingForgets(installedDigests: PluginSourceCatalog.installedDigests(installed))
            let previous = listings
            listings = sources.map { source in
                let listing = PluginSourceCatalog.listing(for: source, store: store, installed: installed)
                // A source over the read limit keeps what it listed before,
                // with the problem shown (T11); importing from it is refused.
                guard listing.exceededReadLimit, let kept = previous.first(where: { $0.id == source.id }) else { return listing }
                return PluginSourceListing(source: source, plugins: kept.plugins, problem: listing.problem, exceededReadLimit: true)
            }
            provenance = store.provenance()
            listProblem = nil
        } catch {
            listings = []
            listProblem = error.localizedDescription
        }
    }

    /// The name of the source an installed plugin came from, when it did.
    func origin(of package: PluginPackage) -> String? {
        listings.first { PluginSourceCatalog.isOwnCopy(package, of: $0.source, provenance: provenance) }?
            .source.displayName
    }

    /// Records that `package` (as the library now holds it) came from
    /// `source`.
    func recordInstalled(_ package: PluginPackage, from source: PluginSource) throws {
        try store.recordProvenance(pluginID: package.id, sourceID: source.id, digest: PluginSourceCatalog.contentDigest(package))
        reload()
    }

    /// Adds a source and fetches it. Returns nil when the location is refused.
    @discardableResult
    func add(_ input: String) async throws -> PluginSource? {
        guard let source = PluginSource.make(from: input) else { return nil }
        var sources = try store.sources()
        if !sources.contains(where: { $0.id == source.id }) {
            sources.append(source)
            try store.save(sources)
        }
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
            "operation": "plugin_source_added", "source_id": source.id, "kind": source.kind.rawValue
        ])
        try await refresh(source)
        return source
    }

    /// Fetches a git source again (a folder is just re-read).
    func refresh(_ source: PluginSource) async throws {
        try await serialized(source.id) { [store, fetcher] in
            try await fetcher.fetch(source, store: store)
            var sources = try store.sources()
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].lastFetchedAt = Date()
                try store.save(sources)
            }
        }
        reload()
    }

    func remove(_ source: PluginSource) async throws {
        operations[source.id]?.cancel()
        _ = try? await operations[source.id]?.value
        try await serialized(source.id) { [store] in
            try store.remove(source)
        }
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "operation": "plugin_source_removed", "source_id": source.id
        ])
        reload()
    }

    /// Runs `body` after any operation already running on the same source.
    private func serialized(_ id: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = operations[id]
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            fetching.insert(id)
            defer { fetching.remove(id) }
            try await body()
        }
        operations[id] = task
        defer { if operations[id] == task { operations[id] = nil } }
        try await task.value
    }
}
