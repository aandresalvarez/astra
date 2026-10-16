import Foundation
import ASTRACore

/// Where plugins come from besides the built-ins: a git repository or a local
/// folder with a marketplace file (Plugins 2.0 spec, Sources).
struct PluginSource: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case git
        case folder
    }

    var id: String
    var kind: Kind
    /// A git URL (https or ssh) or an absolute folder path.
    var location: String
    var displayName: String
    var addedAt: Date
    var lastFetchedAt: Date?

    /// Accepts `https://…`, `ssh://…`, `git@host:owner/repo`, the GitHub
    /// shorthand `owner/repo`, or an absolute folder path. Anything else —
    /// local `file://` URLs, a leading `-` that git would read as an option —
    /// is refused.
    static func make(from input: String, now: Date = Date()) -> PluginSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        if trimmed.hasPrefix("/") {
            return PluginSource(
                id: identifier(for: trimmed), kind: .folder, location: trimmed,
                displayName: URL(fileURLWithPath: trimmed).lastPathComponent, addedAt: now
            )
        }
        let location: String
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("ssh://") || trimmed.hasPrefix("git@") {
            location = trimmed
        } else if trimmed.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil {
            location = "https://github.com/\(trimmed).git"
        } else {
            return nil
        }
        let name = location
            .replacingOccurrences(of: ".git", with: "")
            .split(whereSeparator: { $0 == "/" || $0 == ":" })
            .suffix(2)
            .joined(separator: "/")
        return PluginSource(id: identifier(for: location), kind: .git, location: location, displayName: name, addedAt: now)
    }

    static func identifier(for location: String) -> String {
        let slug = location.lowercased().split { !$0.isLetter && !$0.isNumber }.suffix(3).joined(separator: "-")
        var hash: UInt64 = 1469598103934665603
        for byte in location.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "\(slug)-\(String(hash, radix: 36).prefix(6))"
    }
}

/// The list of sources and their clones, under the channel's Application
/// Support: `PluginSources/sources.json` and `PluginSources/<id>/`.
struct PluginSourceStore {
    var root: URL
    var fileManager: FileManager = .default

    init(root: URL = PluginSourceStore.defaultRoot(), fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultRoot(for channel: AppChannel = .current) -> URL {
        AppChannelStoragePaths.applicationSupportDirectory(for: channel)
            .appendingPathComponent("PluginSources", isDirectory: true)
    }

    private var listURL: URL { root.appendingPathComponent("sources.json") }

    func sources() -> [PluginSource] {
        guard let data = try? HostFileAccessBroker(fileManager: fileManager)
            .readData(at: listURL, intent: .astraManagedStorage(root: root)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PluginSource].self, from: data)) ?? []
    }

    func save(_ sources: [PluginSource]) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sources).write(to: listURL, options: .atomic)
    }

    func cloneDirectory(for source: PluginSource) -> URL {
        root.appendingPathComponent(source.id, isDirectory: true)
    }

    /// Where a source's files are read from: its clone, or the folder itself.
    func contentRoot(for source: PluginSource) -> URL {
        source.kind == .folder ? URL(fileURLWithPath: source.location, isDirectory: true) : cloneDirectory(for: source)
    }

    func remove(_ source: PluginSource) throws {
        try save(sources().filter { $0.id != source.id })
        if source.kind == .git {
            try? fileManager.removeItem(at: cloneDirectory(for: source))
        }
    }
}

enum PluginSourceFetchError: Error, Equatable {
    case gitNotFound
    case cloneFailed(String)
}

/// Fetches a git source: a shallow clone with no submodules, no prompts and
/// local `file:` transport refused, into a temporary folder that replaces the
/// previous clone only once complete.
struct PluginSourceFetcher {
    var runner: any BinaryRunner = ProcessBinaryRunner()
    var gitPath: () -> String = { RuntimePathResolver.detectExecutablePath(named: "git") }
    var timeout: TimeInterval = 300

    func fetch(_ source: PluginSource, store: PluginSourceStore) async throws {
        guard source.kind == .git else { return }
        let git = gitPath()
        guard !git.isEmpty else { throw PluginSourceFetchError.gitNotFound }
        let fileManager = store.fileManager
        try fileManager.createDirectory(at: store.root, withIntermediateDirectories: true)
        let staging = store.root.appendingPathComponent(".\(source.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let result = await runner.run(
            path: git,
            args: Self.cloneArguments(location: source.location, into: staging.path),
            timeout: timeout,
            environment: Self.environment()
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginSourceFetchError.cloneFailed(detail.isEmpty ? "git exited \(result.exitCode ?? -1)" : String(detail.prefix(300)))
        }
        let target = store.cloneDirectory(for: source)
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: staging, to: target)
    }

    static func cloneArguments(location: String, into path: String) -> [String] {
        [
            "-c", "protocol.file.allow=never",
            "clone", "--depth", "1", "--no-recurse-submodules", "--quiet",
            "--", location, path
        ]
    }

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": base["PATH"] ?? "/usr/bin:/bin", "HOME": base["HOME"] ?? NSHomeDirectory()]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        if let agent = base["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        return environment
    }
}

/// A source's files through the file-access broker, refusing anything whose
/// resolved path (symlinks followed) leaves the source root.
struct BrokeredPluginDirectory: PluginDirectoryReading {
    let root: URL
    let intent: HostFileAccessIntent
    var broker = HostFileAccessBroker()

    init(root: URL, kind: PluginSource.Kind) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.intent = kind == .folder ? .explicitUserSelection : .astraManagedStorage(root: self.root)
    }

    func data(at relativePath: String) -> Data? {
        guard let url = contained(relativePath) else { return nil }
        return try? broker.readData(at: url, intent: intent)
    }

    func entries(in relativeDirectory: String) -> [String] {
        guard let url = contained(relativeDirectory) else { return [] }
        return ((try? broker.contentsOfDirectory(at: url, intent: intent)) ?? []).map(\.lastPathComponent)
    }

    private func contained(_ relativePath: String) -> URL? {
        let url = (relativePath.isEmpty ? root : root.appendingPathComponent(relativePath))
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath) ? url : nil
    }
}

/// One plugin offered by a source, ready for the Plugins surface.
struct SourcedPlugin: Identifiable {
    var source: PluginSource
    var package: PluginPackage
    var unsupported: [String]
    /// Why it cannot be added, when it cannot.
    var problem: String?

    var id: String { "\(source.id):\(package.id)" }
}

/// Lists a source's plugins: every in-repository entry of its marketplace
/// file, or the source root as one plugin when it has no marketplace file.
enum PluginSourceCatalog {
    /// Every plugin also goes through the package validator against what is
    /// installed, as an import does: an ID that differs from an installed one
    /// only by case, or maps to the same library filename, or an unsafe
    /// declaration, makes the plugin un-addable with the reason shown.
    static func plugins(
        in source: PluginSource,
        store: PluginSourceStore = PluginSourceStore(),
        installedPackages: [PluginPackage]? = nil
    ) -> [SourcedPlugin] {
        let installed = installedPackages ?? CapabilityLibrary().installedPackages()
        let directory = BrokeredPluginDirectory(root: store.contentRoot(for: source), kind: source.kind)
        let paths: [(name: String, path: String?)]
        if let marketplace = try? PluginMarketplace.read(from: directory) {
            paths = marketplace.plugins.map { ($0.name, $0.path) }
        } else {
            paths = [(source.displayName, "")]
        }
        return paths.compactMap { entry in
            guard let path = entry.path else { return nil }
            guard let plugin = try? PluginSourcePluginReader.read(at: path, in: directory) else { return nil }
            var package = PluginManifestConverter.package(from: plugin.manifest)
            package.sourceMetadata = CapabilitySourceMetadata(
                id: "plugin-source:\(source.id)",
                displayName: source.displayName,
                kind: "plugin-source",
                url: URL(string: source.location),
                trustLevel: "unreviewed"
            )
            package.governance = .localDraft()
            let problem: String?
            if CapabilityLibrary.trustedBuiltInPackageIDs.contains(where: { $0.lowercased() == package.id.lowercased() }) {
                problem = "Uses the ID of a built-in plugin, so it cannot replace it."
            } else {
                problem = CapabilityPackageValidator.validate(
                    package: package,
                    installedPackages: installed,
                    allowReplacingExistingPackageID: true,
                    checkPrerequisites: false
                ).blockers.first.map { "\($0.title): \($0.message)" }
            }
            return SourcedPlugin(source: source, package: package, unsupported: plugin.unsupported, problem: problem)
        }
    }

    /// The fetched definition of an installed source plugin when the source
    /// now offers a different version that can be added; nil otherwise.
    static func updateCandidate(for installed: PluginPackage, among sourced: [SourcedPlugin]) -> PluginPackage? {
        guard installed.sourceMetadata?.kind == "plugin-source",
              let fetched = sourced.first(where: { $0.package.id == installed.id && $0.problem == nil }),
              fetched.package.version != installed.version
        else { return nil }
        return fetched.package
    }
}
