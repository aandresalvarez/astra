import Foundation
import ASTRACore

/// Where plugins come from besides the built-ins: a git repository or a
/// local folder holding a marketplace file (Plugins 2.0 R5).
///
/// Everything a source holds is untrusted until a person reviews and
/// approves one digest of one plugin. The rules each type enforces are named
/// by `docs/specs/2026-10-16-plugin-sources-threat-model.md` (T1–T14).
struct PluginSource: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case git
        case folder
    }

    var id: String
    var kind: Kind
    /// A git URL (https or ssh) or an absolute folder path. Never carries a
    /// credential (T1), so it is safe to store and show; logs name the
    /// source by `id`.
    var location: String
    var displayName: String
    var addedAt: Date
    var lastFetchedAt: Date?

    /// Accepts `https://host/path`, `ssh://[user@]host/path`, `git@host:path`,
    /// the GitHub shorthand `owner/repo`, or an absolute folder path (T1).
    /// Refuses a password, query or fragment anywhere, a user in an https
    /// URL, `file://`, `ext::`, plain `http://` and every other scheme, a
    /// leading `-` (T2), a host starting with `-` (an ssh option), and
    /// control characters. Private repositories authenticate through git's
    /// credential helper or the SSH agent only.
    static func make(from input: String, now: Date = Date()) -> PluginSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if trimmed.hasPrefix("/") {
            let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            return PluginSource(
                id: identifier(for: path), kind: .folder, location: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent, addedAt: now
            )
        }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        let location: String
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("ssh://") {
            guard let components = URLComponents(string: trimmed),
                  let host = components.host, !host.isEmpty, !host.hasPrefix("-"),
                  components.password == nil, components.query == nil, components.fragment == nil,
                  trimmed.hasPrefix("ssh://") || components.user == nil,
                  !components.path.isEmpty, components.path != "/"
            else { return nil }
            location = trimmed
        } else if trimmed.hasPrefix("git@") {
            let rest = trimmed.dropFirst("git@".count)
            guard let colon = rest.firstIndex(of: ":"),
                  !rest[..<colon].isEmpty, !rest.hasPrefix("-"),
                  !rest[rest.index(after: colon)...].isEmpty,
                  !trimmed.contains(where: { $0 == "?" || $0 == "#" })
            else { return nil }
            location = trimmed
        } else if trimmed.range(of: #"^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
                  !trimmed.contains("..") {
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

    /// A stable, file-name-safe ID for a location.
    static func identifier(for location: String) -> String {
        let slug = location.lowercased().split { !$0.isLetter && !$0.isNumber }.suffix(3).joined(separator: "-")
        var hash: UInt64 = 1469598103934665603
        for byte in location.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "\(slug.isEmpty ? "source" : slug)-\(String(hash, radix: 36).prefix(6))"
    }

    /// The `sourceMetadata` a plugin listed from this source carries while
    /// it is offered. The library files every installed plugin as local (a
    /// file on disk can't claim a source), so where an installed one came
    /// from is `PluginSourceStore.provenance()`.
    var metadata: CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: "plugin-source:\(id)",
            displayName: displayName,
            kind: Self.metadataKind,
            url: kind == .git ? URL(string: location) : URL(fileURLWithPath: location),
            trustLevel: "unreviewed"
        )
    }

    static let metadataKind = "plugin-source"
}

enum PluginSourceStoreError: Error, Equatable, LocalizedError {
    /// `sources.json` exists but can't be read: it is reported and never
    /// overwritten (T11).
    case listUnreadable

    var errorDescription: String? {
        "The list of plugin sources can't be read, so it was left as it is."
    }
}

/// The list of sources and their clones, under the channel's Application
/// Support: `PluginSources/sources.json` and `PluginSources/<id>/`.
struct PluginSourceStore {
    var root: URL
    var fileManager: FileManager = .default

    init(root: URL = PluginSourceStore.defaultRoot(), fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    static func defaultRoot(for channel: AppChannel = .current) -> URL {
        AppChannelStoragePaths.applicationSupportDirectory(for: channel)
            .appendingPathComponent("PluginSources", isDirectory: true)
    }

    private var listURL: URL { root.appendingPathComponent("sources.json") }

    /// The stored sources; an empty list when there is none yet. Throws when
    /// the file is there but can't be read or decoded.
    func sources() throws -> [PluginSource] {
        guard fileManager.fileExists(atPath: listURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? HostFileAccessBroker(fileManager: fileManager)
            .readData(at: listURL, intent: .astraManagedStorage(root: root)),
              let sources = try? decoder.decode([PluginSource].self, from: data)
        else { throw PluginSourceStoreError.listUnreadable }
        return sources
    }

    /// Writes the list. Refuses when the stored one can't be read, so a
    /// damaged file is never replaced by a partial list.
    func save(_ sources: [PluginSource]) throws {
        _ = try self.sources()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sources).write(to: listURL, options: .atomic)
    }

    /// Where an installed plugin came from: its source and the content
    /// digest of the copy that source installed. A record whose digest no
    /// longer matches the installed copy (a file imported over it) doesn't
    /// count.
    struct Provenance: Codable, Equatable, Sendable {
        var sourceID: String
        var digest: String
    }

    private var provenanceURL: URL { root.appendingPathComponent("provenance.json") }

    /// Plugin ID → provenance. An unreadable record reads as empty: no
    /// installed plugin then counts as a source's own copy, which only
    /// refuses more.
    func provenance() -> [String: Provenance] {
        guard let data = try? HostFileAccessBroker(fileManager: fileManager)
            .readData(at: provenanceURL, intent: .astraManagedStorage(root: root)) else { return [:] }
        return (try? JSONDecoder().decode([String: Provenance].self, from: data)) ?? [:]
    }

    func recordProvenance(pluginID: String, sourceID: String, digest: String) throws {
        var records = provenance()
        records[pluginID] = Provenance(sourceID: sourceID, digest: digest)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: provenanceURL, options: .atomic)
    }

    func cloneDirectory(for source: PluginSource) -> URL {
        root.appendingPathComponent(source.id, isDirectory: true)
    }

    /// Where a source's files are read from: its clone, or the folder itself.
    func contentRoot(for source: PluginSource) -> URL {
        source.kind == .folder ? URL(fileURLWithPath: source.location, isDirectory: true) : cloneDirectory(for: source)
    }

    func remove(_ source: PluginSource) throws {
        try save(try sources().filter { $0.id != source.id })
        if source.kind == .git {
            try? fileManager.removeItem(at: cloneDirectory(for: source))
        }
    }
}

enum PluginSourceFetchError: Error, Equatable, LocalizedError {
    case gitNotFound
    case cloneFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .gitNotFound: "git is not installed."
        case .cloneFailed(let detail): "git couldn't fetch the source: \(detail)"
        case .timedOut: "Fetching the source took too long."
        }
    }
}

/// Fetches a git source (T3): a shallow clone, no submodules, hooks, fsmonitor,
/// LFS filters, prompts or transports other than https and ssh, with a
/// minimal environment and a timeout, into a staging folder that replaces
/// the previous clone only once complete (T12). ASTRA only reads files from
/// the checkout.
struct PluginSourceFetcher {
    var runner: any BinaryRunner = ProcessBinaryRunner()
    var gitPath: () -> String = { RuntimePathResolver.detectExecutablePath(named: "git") }
    var timeout: TimeInterval = 300
    /// The only transports git may use. Tests add `file` for a local bare
    /// repository; nothing else changes it.
    var allowedProtocols: [String] = ["https", "ssh"]

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
            args: Self.cloneArguments(location: source.location, into: staging.path, allowedProtocols: allowedProtocols),
            timeout: timeout,
            environment: Self.environment()
        )
        if result.timedOut { throw PluginSourceFetchError.timedOut }
        guard result.exitCode == 0, fileManager.fileExists(atPath: staging.path) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginSourceFetchError.cloneFailed(detail.isEmpty ? "git exited \(result.exitCode ?? -1)" : String(detail.prefix(300)))
        }
        let target = store.cloneDirectory(for: source)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
    }

    static func hardening(allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never"]
            + allowedProtocols.flatMap { ["-c", "protocol.\($0).allow=always"] }
            + [
                "-c", "filter.lfs.smudge=",
                "-c", "filter.lfs.process=",
                "-c", "filter.lfs.required=false",
                "-c", "credential.interactive=never"
            ]
    }

    /// The argument vector, ending `-- <location> <dir>` so the location is
    /// never read as an option (T2).
    static func cloneArguments(location: String, into path: String, allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        hardening(allowedProtocols: allowedProtocols)
            + ["clone", "--depth", "1", "--no-recurse-submodules", "--quiet", "--", location, path]
    }

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": base["PATH"] ?? "/usr/bin:/bin", "HOME": base["HOME"] ?? NSHomeDirectory()]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        if let agent = base["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        return environment
    }
}

/// A source's files through the file-access broker (T4, T11). A path is read
/// only when it resolves, symlinks followed, inside the root; only regular
/// files are read, and only when they are under the caller's size limit.
struct BrokeredPluginDirectory: PluginDirectoryReading {
    let root: URL
    let intent: HostFileAccessIntent
    var broker = HostFileAccessBroker()

    init(root: URL, kind: PluginSource.Kind) {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        self.init(resolvedRoot: resolved, intent: kind == .folder ? .explicitUserSelection : .astraManagedStorage(root: resolved))
    }

    private init(resolvedRoot: URL, intent: HostFileAccessIntent) {
        self.root = resolvedRoot
        self.intent = intent
    }

    func read(_ relativePath: String, limit: Int) -> PluginSourceFileRead {
        guard let url = contained(relativePath) else { return .refused }
        let type: FileAttributeType?
        do {
            type = try broker.itemType(at: url, intent: intent)
        } catch {
            return .refused
        }
        guard let type else { return .missing }
        guard type == .typeRegular else { return .refused }
        guard let size = broker.fileSize(at: url, intent: intent) else { return .refused }
        guard size <= limit else { return .tooLarge }
        guard let data = try? broker.readData(at: url, intent: intent) else { return .refused }
        return data.count <= limit ? .data(data) : .tooLarge
    }

    func entries(in relativeDirectory: String) -> [String] {
        guard let url = contained(relativeDirectory) else { return [] }
        return ((try? broker.contentsOfDirectory(at: url, intent: intent)) ?? []).map(\.lastPathComponent)
    }

    func scoped(to relativeDirectory: String) -> PluginDirectoryReading? {
        guard let url = contained(relativeDirectory) else { return nil }
        return BrokeredPluginDirectory(resolvedRoot: url, intent: intent)
    }

    private func contained(_ relativePath: String) -> URL? {
        let url = (relativePath.isEmpty ? root : root.appendingPathComponent(relativePath))
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath) ? url : nil
    }
}
