import CryptoKit
import Foundation
import os
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
            let source = PluginSource(
                id: identifier(for: path), kind: .folder, location: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent, addedAt: now
            )
            // Shown beside every plugin from it, so it must show as typed (T14).
            return source.displayTextChange == nil ? source : nil
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
        let source = PluginSource(id: identifier(for: location), kind: .git, location: location, displayName: name, addedAt: now)
        return source.displayTextChange == nil ? source : nil
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
            displayName: shownName,
            kind: Self.metadataKind,
            url: kind == .git ? URL(string: location) : URL(fileURLWithPath: location),
            trustLevel: "unreviewed"
        )
    }

    static let metadataKind = "plugin-source"
}

/// The mirror's source identity for a plugin's copy, from this channel's
/// plugin source store (`PluginSourceStore.mirrorIdentity`). Registered by
/// `PluginSourceStore.launchedApp` only.
enum PluginSourceMirrorIdentity: PluginSourceIdentityResolving {
    static func mirrorIdentity(pluginID: String, digest: String) -> String? {
        guard let installed = CapabilityLibrary().installedPackage(id: pluginID) else { return nil }
        return PluginSourceStore.mirrorIdentity(recordedDigest: digest, installed: installed, provenance: PluginSourceStore().provenance())
    }

    static func installedCopy(pluginID: String) -> PluginInstalledCopy? {
        PluginSourceStore().installedCopy(of: CapabilityLibrary().installedPackage(id: pluginID))
    }
}

enum PluginSourceStoreError: Error, Equatable, LocalizedError {
    /// `sources.json` exists but can't be read: it is reported and never
    /// overwritten (T11).
    case listUnreadable
    /// Another Add, file import, Create or Remove of the same plugin ID is
    /// running, here or in another ASTRA process (`exclusively`).
    case pluginBusy(String)
    /// Another ASTRA process is writing the library and didn't finish within
    /// the wait, or this one is re-entering a library write (`exclusively`).
    case libraryBusy

    var errorDescription: String? {
        switch self {
        case .listUnreadable:
            "The list of plugin sources can't be read, so it was left as it is."
        case .pluginBusy:
            "This plugin is being added, imported or removed already. Try again when that finishes."
        case .libraryBusy:
            "Another plugin is being added, imported or removed. Try again when that finishes."
        }
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

    /// Where a store made without a root lives: the channel's Application
    /// Support once the app's launch path has said so (`launchedApp`), a
    /// scratch folder of this process before that and in every other
    /// process. The test binary resolves Application Support to the
    /// production folder, so no default (this initializer's, the
    /// coordinator's, the action service's, the import verifier's) may reach
    /// it there, not even to read.
    static func defaultRoot(for channel: AppChannel = .current) -> URL {
        launched.withLock { $0 } ? applicationSupportRoot(for: channel) : scratchRoot
    }

    static func applicationSupportRoot(for channel: AppChannel = .current) -> URL {
        AppChannelStoragePaths.applicationSupportDirectory(for: channel)
            .appendingPathComponent("PluginSources", isDirectory: true)
    }

    static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("astra-plugin-sources-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    private static let launched = OSAllocatedUnfairLock(initialState: false)

    /// Called by `ASTRAApp.init` only, before anything reads a store: from
    /// then on the default store is the person's, and the mirror records
    /// sources from it (`PluginSourceIdentitySeam`).
    static func launchedApp() {
        launched.withLock { $0 = true }
        PluginSourceIdentitySeam.register(PluginSourceMirrorIdentity.self)
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
        /// A local install or Remove that will end this record, journaled
        /// before its library write (`forgettingProvenance`). Left behind by
        /// an exit, it is settled by what the library holds (`resolved`).
        var pendingForget: PendingForget?

        enum PendingForget: Codable, Equatable, Sendable {
            /// Remove: the plugin leaves the library.
            case remove
            /// A file import or Create writing the copy with this digest.
            case install(digest: String)
        }

        func names(_ digest: String) -> Bool {
            !digest.isEmpty && (self.digest == digest || pendingDigest == digest)
        }

        /// The record once a pending forget is settled by the digest of the
        /// copy the library holds (nil when there is none): nil when the
        /// forget took effect, that is the plugin is gone after a Remove or
        /// the library holds the local install's copy, byte-identical or
        /// not. It is kept, the intent dropped, only when the library still
        /// holds a copy this record names that the local install would not
        /// have written.
        func resolved(installedDigest: String?) -> Provenance? {
            guard let intent = pendingForget else { return self }
            switch intent {
            case .remove:
                guard installedDigest != nil else { return nil }
            case .install(let local):
                guard let installed = installedDigest, installed != local, names(installed) else { return nil }
            }
            var kept = self
            kept.pendingForget = nil
            return kept
        }
    }

    private var provenanceURL: URL { root.appendingPathComponent("provenance.json") }

    /// What a workspace mirror records as the source of a plugin's copy
    /// (`InstalledPluginRef.source`, T5): `plugin-source:<id>` when the
    /// provenance names the copy with `digest` (a pending forget settled by
    /// it first), nil for a local copy. The mirror's export and the import
    /// check both read it here.
    static func mirrorIdentity(pluginID: String, digest: String, provenance: [String: Provenance]) -> String? {
        guard let record = provenance[pluginID]?.resolved(installedDigest: digest), record.names(digest) else { return nil }
        return "plugin-source:\(record.sourceID)"
    }

    /// The identity for an activation that recorded `recordedDigest`
    /// against `installed`: a content digest (`PluginDefinitionDigest`), or
    /// an approval digest from before content digests. Nil, local, when it
    /// names another copy than the one installed.
    static func mirrorIdentity(
        recordedDigest: String, installed: PluginPackage, provenance: [String: Provenance]
    ) -> String? {
        let digest = PluginSourceCatalog.contentDigest(installed)
        guard recordedDigest == digest || recordedDigest == PluginDefinitionDigest.content(of: installed) else { return nil }
        return mirrorIdentity(pluginID: installed.id, digest: digest, provenance: provenance)
    }

    /// The library's copy (`installed`, nil when there is none) and where
    /// it came from, as the mirror names it.
    func installedCopy(of installed: PluginPackage?) -> PluginInstalledCopy {
        guard let installed else { return .notInstalled }
        return .installed(source: Self.mirrorIdentity(
            pluginID: installed.id, digest: PluginSourceCatalog.contentDigest(installed), provenance: provenance()
        ))
    }

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

    /// Runs a local install or Remove (`libraryWrite`) that ends a plugin's
    /// provenance, journaled like a source import (T5): the intent is
    /// recorded before the write, the record dropped after it, and the
    /// intent cleared, ownership kept, when the write throws. An exit
    /// between the steps leaves the intent for `resolvePendingForgets`.
    /// A plugin with no record runs the write alone. A forget that fails
    /// after a successful write is logged; its intent still settles it.
    func forgettingProvenance<Result>(
        pluginID: String,
        leaving intent: Provenance.PendingForget,
        _ libraryWrite: () throws -> Result
    ) throws -> Result {
        var records = provenance()
        guard records[pluginID] != nil else { return try libraryWrite() }
        records[pluginID]?.pendingForget = intent
        try write(records)
        let result: Result
        do {
            result = try libraryWrite()
        } catch {
            var current = provenance()
            current[pluginID]?.pendingForget = nil
            try? write(current)
            throw error
        }
        do {
            try forgetProvenance(pluginID: pluginID)
        } catch {
            AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
                "source": "plugin_source_provenance", "package_id": pluginID,
                "result": "forget_failed", "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        return result
    }

    /// Settles every intent an exit left (`Provenance.resolved`) against
    /// the digests of the copies the library holds, by plugin ID. Writes
    /// only when one was pending.
    func resolvePendingForgets(installedDigests: [String: String]) throws {
        let records = provenance()
        guard records.values.contains(where: { $0.pendingForget != nil }) else { return }
        var resolved: [String: Provenance] = [:]
        for (id, record) in records {
            resolved[id] = record.resolved(installedDigest: installedDigests[id])
        }
        try write(resolved)
    }

    private func write(_ records: [String: Provenance]) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: provenanceURL, options: .atomic)
    }

    /// How long `exclusively` waits for another process's library write
    /// before refusing (`libraryBusy`); a write is a few file copies.
    var libraryLockWait: TimeInterval = 5

    /// Runs one Add from a source, file import, Create, Remove or staged
    /// approval of a plugin (`body`), with no other for the same ID running
    /// across sources, and no other library write at all (T5, T13): an
    /// install from one source can't pass its conflict check while another
    /// source's install of that ID is between its check and its writes, and
    /// two installs of different IDs can't both pass the library-wide
    /// uniqueness checks (an MCP server ID, a file name) before either
    /// writes, so `body` checks again and writes as one step.
    ///
    /// Two locks, always in this order so they can't deadlock: the plugin's
    /// (IDs keyed as the library names their files, case and separators
    /// folded, so two IDs that would share a file share the key), then the
    /// library's. Each is held in this process (a set of keys, a flag) and
    /// across processes (an exclusive `flock` on `locks/<key digest>.lock`
    /// and `locks/library.lock` under the store). A second operation in
    /// this process is refused, not queued: the paths are synchronous on
    /// the main actor, so one that arrives meanwhile is re-entering from
    /// inside the first. Another process's hold on the plugin is refused
    /// too; its hold on the library is waited for (`libraryLockWait`), as a
    /// write of an unrelated plugin is short and the next check sees it.
    func exclusively<Result>(pluginID: String, _ body: () throws -> Result) throws -> Result {
        let key = CapabilityLibrary.safeFileName(for: pluginID).lowercased()
        guard Self.heldPluginKeys.withLock({ $0.insert(key).inserted }) else {
            throw PluginSourceStoreError.pluginBusy(pluginID)
        }
        defer { _ = Self.heldPluginKeys.withLock { $0.remove(key) } }
        let descriptor = try openLock(pluginLockURL(forKey: key))
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw PluginSourceStoreError.pluginBusy(pluginID) }
        defer { flock(descriptor, LOCK_UN) }
        return try exclusivelyLibrary(body)
    }

    /// The library-wide half of `exclusively`: taken inside a plugin's lock,
    /// never on its own.
    private func exclusivelyLibrary<Result>(_ body: () throws -> Result) throws -> Result {
        guard Self.heldLibrary.withLock({ held -> Bool in
            if held { return false }
            held = true
            return true
        }) else { throw PluginSourceStoreError.libraryBusy }
        defer { Self.heldLibrary.withLock { $0 = false } }
        let descriptor = try openLock(libraryLockURL)
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(libraryLockWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw PluginSourceStoreError.libraryBusy }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The plugin keys `exclusively` holds in this process, and whether it
    /// holds the library.
    private static let heldPluginKeys = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let heldLibrary = OSAllocatedUnfairLock(initialState: false)

    private func openLock(_ url: URL) throws -> Int32 {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return descriptor
    }

    func pluginLockURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("locks", isDirectory: true).appendingPathComponent("\(digest).lock")
    }

    var libraryLockURL: URL { root.appendingPathComponent("locks", isDirectory: true).appendingPathComponent("library.lock") }

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
    /// The objects a fetched pack may hold, read from its header while git
    /// indexes it (T11). `index-pack` keeps about 80 bytes per object, so a
    /// pack under the download bound made of millions of tiny objects
    /// would otherwise cost hundreds of megabytes before the tree is
    /// measured. A checkout within `maxCheckoutFiles` needs far fewer.
    var maxPackObjects: Int = 100_000

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
        // The watcher may not have seen a pack indexed between two polls.
        guard Self.packObjectCount(in: staging) <= maxPackObjects else { throw PluginSourceFetchError.tooLarge }
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

    /// Runs git while watching how much `directory` holds and how many
    /// objects its packs declare; past `maxDownloadBytes` or
    /// `maxPackObjects` the run is cancelled and the fetch refused.
    private func runBounded(
        _ git: String,
        _ args: [String],
        watching directory: URL,
        environment: [String: String],
        fileManager: FileManager
    ) async throws -> RunResult {
        let (limit, objectLimit) = (maxDownloadBytes, maxPackObjects)
        let (runner, timeout) = (self.runner, self.timeout)
        return try await withThrowingTaskGroup(of: RunResult?.self) { group in
            group.addTask {
                await runner.run(path: git, args: args, timeout: timeout, environment: environment)
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Self.size(of: directory) > limit || Self.packObjectCount(in: directory) > objectLimit {
                        throw PluginSourceFetchError.tooLarge
                    }
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

    /// The objects the packs under a clone's `.git/objects/pack` declare,
    /// finished (`*.pack`) or still being indexed (`tmp_pack_*`): bytes 8–11
    /// of a pack, big-endian, after the `PACK` signature and version. Git
    /// writes the header first and indexes exactly that many objects, so
    /// the count is known as soon as the first bytes arrive.
    static func packObjectCount(in clone: URL) -> Int {
        let packs = clone.appendingPathComponent(".git/objects/pack", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: packs.path)) ?? []
        return names.filter { $0.hasSuffix(".pack") || $0.hasPrefix("tmp_pack_") }.reduce(0) { total, name in
            guard let handle = FileHandle(forReadingAtPath: packs.appendingPathComponent(name).path) else { return total }
            defer { try? handle.close() }
            let header = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
            guard header.count == 12, header.prefix(4) == [0x50, 0x41, 0x43, 0x4B] else { return total }
            return total + header[8..<12].reduce(0) { $0 << 8 | Int($1) }
        }
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

/// A source's files, read through directory descriptors (T4, T11). The
/// root is opened once, after the file-access broker allows it, without
/// following a link (`O_NOFOLLOW`) and only when the descriptor is the very
/// directory the broker was asked about (its device and inode, taken
/// before the check), so a root swapped for a symlink or another directory
/// between the check and the open is refused. Every path below it is
/// opened one component at a time with `openat` and `O_NOFOLLOW`, from the
/// descriptor of the directory above, so a symlink anywhere inside the
/// source is refused, never followed, and a directory swapped for a symlink
/// after it was opened can't redirect a read: the read goes through the
/// descriptor already held. Only regular files are read (`fstat` on the
/// open descriptor), opened non-blocking so a FIFO can't hang a listing,
/// and no more than the caller's limit.
struct BrokeredPluginDirectory: PluginDirectoryReading {
    let root: URL
    private let directory: OpenDirectory?
    /// Called with each relative path after its directories are open and
    /// before the file itself is: tests swap things in here.
    var willOpen: ((String) -> Void)?

    /// `willOpenRoot` runs after the broker check and before the root is
    /// opened: tests swap things in there.
    init(
        root: URL,
        kind: PluginSource.Kind,
        broker: HostFileAccessBroker = HostFileAccessBroker(),
        willOpenRoot: (() -> Void)? = nil
    ) {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let intent: HostFileAccessIntent = kind == .folder ? .explicitUserSelection : .astraManagedStorage(root: resolved)
        self.root = resolved
        // The directory the broker is asked about, as it is now; a symlink
        // there is no directory and is refused.
        let checked = OpenDirectory.identity(atPath: resolved.path)
        let allowed = checked != nil && !broker.shouldSkip(resolved, intent: intent)
        willOpenRoot?()
        self.directory = allowed ? checked.flatMap { OpenDirectory(root: resolved.path, identity: $0) } : nil
    }

    private init(root: URL, directory: OpenDirectory?, willOpen: ((String) -> Void)?) {
        self.root = root
        self.directory = directory
        self.willOpen = willOpen
    }

    func read(_ relativePath: String, limit: Int) -> PluginSourceFileRead {
        guard let directory, let components = Self.components(relativePath), let name = components.last else { return .refused }
        let parent: OpenDirectory
        switch directory.descend(components.dropLast()) {
        case .opened(let opened): parent = opened
        case .missing: return .missing
        case .refused: return .refused
        }
        willOpen?(relativePath)
        let descriptor = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return parent.failure(opening: name, errno: errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .refused }
        guard Int(info.st_size) <= limit else { return .tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { return .refused }
            if count == 0 { break }
            data.append(buffer, count: count)
            // A file grown since the `fstat` is still read only to its limit.
            if data.count > limit { return .tooLarge }
        }
        return .data(data)
    }

    func entries(in relativeDirectory: String) -> [String] {
        guard let directory, let components = Self.components(relativeDirectory),
              case .opened(let opened) = directory.descend(components[...]) else { return [] }
        return opened.names()
    }

    func scoped(to relativeDirectory: String) -> PluginDirectoryReading? {
        guard let directory, let components = Self.components(relativeDirectory),
              case .opened(let opened) = directory.descend(components[...]) else { return nil }
        return BrokeredPluginDirectory(
            root: components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) },
            directory: opened,
            willOpen: willOpen
        )
    }

    /// The path's components: no `..`, nothing absolute; "" and "." are the
    /// directory itself.
    private static func components(_ relativePath: String) -> [String]? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let parts = relativePath.split(separator: "/").map(String.init).filter { $0 != "." }
        return parts.contains("..") ? nil : parts
    }
}

/// An open directory descriptor, closed with its last reference.
private final class OpenDirectory {
    enum Descent {
        case opened(OpenDirectory)
        case missing
        case refused
    }

    /// Which directory a descriptor or path names.
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    let descriptor: Int32

    /// The directory at `path` now, its last component not followed: nil
    /// when that is a symlink or anything but a directory.
    static func identity(atPath path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Opens the root without following a link at its last component, and
    /// keeps it only when it is still the directory `identity` names: one
    /// swapped for a symlink fails the open, and one swapped for another
    /// directory (or reached through a swapped parent) fails the match.
    init?(root path: String, identity: Identity) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              Identity(device: info.st_dev, inode: info.st_ino) == identity else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// Opens each component below this one without following a symlink.
    func descend(_ components: ArraySlice<String>) -> Descent {
        var current = self
        for name in components {
            let next = name.withCString { openat(current.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                switch current.failure(opening: name, errno: errno) {
                case .missing: return .missing
                default: return .refused
                }
            }
            current = OpenDirectory(descriptor: next)
        }
        return .opened(current)
    }

    /// Why `name` here could not be opened: missing only when nothing is
    /// there (or a file stands where a directory was named); a symlink or
    /// anything else is refused.
    func failure(opening name: String, errno code: Int32) -> PluginSourceFileRead {
        var info = stat()
        let found = name.withCString { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0
        if !found { return code == ENOENT || code == ENOTDIR ? .missing : .refused }
        if info.st_mode & S_IFMT == S_IFLNK { return .refused }
        return code == ENOTDIR && info.st_mode & S_IFMT == S_IFREG ? .missing : .refused
    }

    func names() -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
