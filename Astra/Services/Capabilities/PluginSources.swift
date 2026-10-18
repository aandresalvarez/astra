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

    /// Host keys of the SSH sources ASTRA has fetched, first seen on first
    /// use (`PluginSourceFetcher.sshCommand`).
    var knownHostsFile: URL { root.appendingPathComponent("known_hosts") }

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
    /// count. `pendingDigest` is the copy an import from the same source is
    /// writing: it is recorded before the library write, so an exit between
    /// the two leaves either copy recognised as the source's own.
    struct Provenance: Codable, Equatable, Sendable {
        var sourceID: String
        var digest: String
        var pendingDigest: String?

        func names(_ digest: String) -> Bool {
            !digest.isEmpty && (self.digest == digest || pendingDigest == digest)
        }
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
        try write(records)
    }

    /// Records the copy an import from `sourceID` is about to write, before
    /// the library write. A record for the same source keeps the copy it
    /// names until `recordProvenance` settles on the new one.
    func beginProvenance(pluginID: String, sourceID: String, digest: String) throws {
        var records = provenance()
        if var record = records[pluginID], record.sourceID == sourceID {
            record.pendingDigest = digest
            records[pluginID] = record
        } else {
            records[pluginID] = Provenance(sourceID: sourceID, digest: digest)
        }
        try write(records)
    }

    /// Drops a plugin's provenance: it was removed, or a file or Create
    /// installed it, so no source owns the copy in the library any more.
    /// Writes nothing when there is no record.
    func forgetProvenance(pluginID: String) throws {
        var records = provenance()
        guard records.removeValue(forKey: pluginID) != nil else { return }
        try write(records)
    }

    private func write(_ records: [String: Provenance]) throws {
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
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .gitNotFound: "git is not installed."
        case .cloneFailed(let detail): "git couldn't fetch the source: \(detail)"
        case .timedOut: "Fetching the source took too long."
        case .tooLarge: "The source is larger than ASTRA reads for plugins."
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
    /// What a source may take on disk while it downloads, and what its
    /// checkout may hold (T11): a repository over either is refused before
    /// any file is checked out.
    var maxDownloadBytes: Int = 64 * 1024 * 1024
    var maxCheckoutBytes: Int = 64 * 1024 * 1024
    var maxCheckoutFiles: Int = 10_000

    func fetch(_ source: PluginSource, store: PluginSourceStore) async throws {
        guard source.kind == .git else { return }
        let git = gitPath()
        guard !git.isEmpty else { throw PluginSourceFetchError.gitNotFound }
        let fileManager = store.fileManager
        try fileManager.createDirectory(at: store.root, withIntermediateDirectories: true)
        let staging = store.root.appendingPathComponent(".\(source.id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let environment = Self.environment(knownHostsFile: store.knownHostsFile.path)

        // 1. Download without a checkout, stopped if it grows past the bound.
        let result = try await runBounded(
            git, Self.cloneArguments(location: source.location, into: staging.path, allowedProtocols: allowedProtocols),
            watching: staging, environment: environment, fileManager: fileManager
        )
        if result.timedOut { throw PluginSourceFetchError.timedOut }
        guard result.exitCode == 0, fileManager.fileExists(atPath: staging.path) else {
            throw PluginSourceFetchError.cloneFailed(Self.detail(result))
        }
        // 2. Measure what a checkout would write, from the tree, first.
        let tree = await runner.run(
            path: git,
            args: Self.treeArguments(in: staging.path, allowedProtocols: allowedProtocols),
            timeout: timeout,
            environment: environment
        )
        guard tree.exitCode == 0 else { throw PluginSourceFetchError.cloneFailed(Self.detail(tree)) }
        let sizes = Self.blobSizes(tree.stdout)
        guard sizes.count <= maxCheckoutFiles, sizes.reduce(0, +) <= maxCheckoutBytes else {
            throw PluginSourceFetchError.tooLarge
        }
        // 3. Check out under the same isolated configuration, with every
        // attribute that changes the bytes written unset first.
        try Self.writeAttributeOverride(gitDirectory: staging.appendingPathComponent(".git", isDirectory: true), fileManager: fileManager)
        let checkout = await runner.run(
            path: git,
            args: Self.checkoutArguments(in: staging.path, allowedProtocols: allowedProtocols),
            timeout: timeout,
            environment: environment
        )
        guard checkout.exitCode == 0 else { throw PluginSourceFetchError.cloneFailed(Self.detail(checkout)) }

        let target = store.cloneDirectory(for: source)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
    }

    /// Runs git while watching how much `directory` holds; past
    /// `maxDownloadBytes` the run is cancelled and the fetch refused.
    private func runBounded(
        _ git: String,
        _ args: [String],
        watching directory: URL,
        environment: [String: String],
        fileManager: FileManager
    ) async throws -> RunResult {
        let limit = maxDownloadBytes
        let (runner, timeout) = (self.runner, self.timeout)
        return try await withThrowingTaskGroup(of: RunResult?.self) { group in
            group.addTask {
                await runner.run(path: git, args: args, timeout: timeout, environment: environment)
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Self.size(of: directory) > limit { throw PluginSourceFetchError.tooLarge }
                }
                return nil
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let result = next { return result }
            }
            throw PluginSourceFetchError.cloneFailed("git did not finish")
        }
    }

    static func size(of directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    /// Blob sizes from `git ls-tree -r -l`: `<mode> blob <sha> <size>\t<path>`.
    static func blobSizes(_ listing: String) -> [Int] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
            guard fields.count >= 4, fields[1] == "blob" else { return nil }
            return Int(fields[3])
        }
    }

    private static func detail(_ result: RunResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git exited \(result.exitCode ?? -1)" : String(text.prefix(300))
    }

    /// `-c` settings every git call of a fetch gets. With the user's own git
    /// configuration not read at all (`environment`), nothing it names (a
    /// filter driver, a hooks path, an fsmonitor) runs; credentials come only
    /// from the system keychain helper or the SSH agent.
    static func hardening(allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never",
         // The person's own attributes file (~/.config/git/attributes) is
         // read even with no global config; an `ident` there would inflate
         // the checkout too.
         "-c", "core.attributesFile=/dev/null",
         // Objects over 1 MB are streamed, not inflated in memory: a tiny
         // pack of one huge zero blob otherwise costs its full size in RAM
         // before the tree can be measured (T11).
         "-c", "core.bigFileThreshold=1m"]
            + allowedProtocols.flatMap { ["-c", "protocol.\($0).allow=always"] }
            + [
                "-c", "filter.lfs.smudge=",
                "-c", "filter.lfs.process=",
                "-c", "filter.lfs.required=false",
                "-c", "credential.helper=osxkeychain",
                // Git before 2.47 ignores this key; `GIT_TERMINAL_PROMPT=0`
                // with no askpass in the environment still keeps it silent.
                "-c", "credential.interactive=never"
            ]
    }

    /// The argument vector, ending `-- <location> <dir>` so the location is
    /// never read as an option (T2). No checkout: files are written only
    /// after the tree is measured.
    static func cloneArguments(location: String, into path: String, allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        hardening(allowedProtocols: allowedProtocols)
            + ["clone", "--depth", "1", "--no-checkout", "--no-recurse-submodules", "--quiet", "--", location, path]
    }

    /// Lists what a checkout would write, with each blob's size.
    static func treeArguments(in path: String, allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        hardening(allowedProtocols: allowedProtocols) + ["-C", path, "ls-tree", "-r", "-l", "--full-tree", "HEAD"]
    }

    /// Checks out the measured tree. Every option here, in `cloneArguments`
    /// and in `treeArguments` exists in Git 2.39, the oldest Apple git a
    /// supported macOS ships; `--attr-source` (2.41) is not used.
    static func checkoutArguments(in path: String, allowedProtocols: [String] = ["https", "ssh"]) -> [String] {
        hardening(allowedProtocols: allowedProtocols) + ["-C", path, "checkout", "--quiet", "HEAD", "--", "."]
    }

    /// What `$GIT_DIR/info/attributes` holds before the checkout. That file
    /// outranks every `.gitattributes` in the tree, whatever its pattern,
    /// nesting or `[attr]` macro, and every git reads it, so `ident`,
    /// end-of-line conversion, `working-tree-encoding` or a filter in the
    /// repository can't make the files written differ from the blobs
    /// measured (T11).
    static let attributeOverride = "* -text -eol -crlf -ident -filter -working-tree-encoding\n"

    static func writeAttributeOverride(gitDirectory: URL, fileManager: FileManager = .default) throws {
        let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: info, withIntermediateDirectories: true)
        try Data(attributeOverride.utf8).write(to: info.appendingPathComponent("attributes"), options: .atomic)
    }

    static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        knownHostsFile: String
    ) -> [String: String] {
        var environment = ["PATH": base["PATH"] ?? "/usr/bin:/bin", "HOME": base["HOME"] ?? NSHomeDirectory()]
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        // Neither ~/.gitconfig nor the XDG one: a global filter driver,
        // hook path or alias never applies to an untrusted checkout.
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_ATTR_NOSYSTEM"] = "1"
        environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        // ssh reads no config file either: a `ProxyCommand`, `Match exec` or
        // `LocalCommand` in ~/.ssh/config or the system one would run a shell
        // command. Only the agent authenticates.
        environment["GIT_SSH_COMMAND"] = sshCommand(knownHostsFile: knownHostsFile)
        environment["GIT_SSH_VARIANT"] = "ssh"
        if let agent = base["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        return environment
    }

    /// The ssh a fetch runs: no config file, nothing that executes a command
    /// or forwards anything, never a prompt, and no key file from disk
    /// (`IdentityFile=none`): only the agent's keys are offered. A host seen
    /// for the first time is accepted and its key kept in ASTRA's own
    /// known-hosts file (`accept-new`); a known host whose key changed is refused, so the
    /// key is still verified on every later fetch. The person's
    /// `~/.ssh/known_hosts` is read, never written.
    static func sshCommand(knownHostsFile: String) -> String {
        let knownHosts = "UserKnownHostsFile=\"\(knownHostsFile)\" ~/.ssh/known_hosts"
        return [
            "/usr/bin/ssh", "-F", "/dev/null",
            "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-o", "BatchMode=yes", "-o", "IdentityFile=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", shellQuoted(knownHosts)
        ].joined(separator: " ")
    }

    private static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
