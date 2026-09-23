import Foundation

/// A regenerable build-artifact directory: a directory with a known name whose
/// *sibling* is the ecosystem's manifest. The manifest anchor is what makes a
/// match safe to delete — a stray `.build` or `target` folder without its
/// `Package.swift` or `Cargo.toml` next to it is somebody's data, not a cache.
///
/// Rules are data, so a new ecosystem is one more entry in `all`; the policy
/// and the reclaimer never switch on a rule.
struct WorktreeArtifactRule: Hashable, Sendable {
    enum Ecosystem: String, Hashable, Sendable {
        case swiftPM
        case cargo
        case node
    }

    let ecosystem: Ecosystem
    /// The artifact directory's exact name, e.g. `.build`.
    let directoryName: String
    /// The file that must sit next to the directory, e.g. `Package.swift`.
    let manifestName: String

    static let swiftPM = WorktreeArtifactRule(
        ecosystem: .swiftPM,
        directoryName: ".build",
        manifestName: "Package.swift"
    )
    static let cargo = WorktreeArtifactRule(
        ecosystem: .cargo,
        directoryName: "target",
        manifestName: "Cargo.toml"
    )
    static let node = WorktreeArtifactRule(
        ecosystem: .node,
        directoryName: "node_modules",
        manifestName: "package.json"
    )

    /// The v1 rule set.
    static let all: [WorktreeArtifactRule] = [.swiftPM, .cargo, .node]

    /// True when `path` is a real directory (never a symlink) named
    /// `directoryName` whose parent holds `manifestName`.
    func matches(directoryAtPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == directoryName,
              WorktreeFileSystem.isRealDirectory(path) else { return false }
        let manifest = url.deletingLastPathComponent().appendingPathComponent(manifestName).path
        return WorktreeFileSystem.isFile(manifest)
    }

    /// The first rule the directory at `path` satisfies, if any.
    static func rule(
        matchingDirectoryAtPath path: String,
        in rules: [WorktreeArtifactRule]
    ) -> WorktreeArtifactRule? {
        rules.first { $0.matches(directoryAtPath: path) }
    }

    /// The rule whose interrupted reclaim left `path` behind
    /// (`<directoryName>.astra-reclaiming-<uuid>`): a real directory that is
    /// still next to that rule's manifest. A look-alike without the manifest
    /// is somebody's data, never swept.
    static func rule(
        matchingLeftoverAtPath path: String,
        in rules: [WorktreeArtifactRule]
    ) -> WorktreeArtifactRule? {
        let url = URL(fileURLWithPath: path)
        guard let base = WorktreeFileSystem.reclaimLeftoverBaseName(url.lastPathComponent),
              let rule = rules.first(where: { $0.directoryName == base }),
              WorktreeFileSystem.isRealDirectory(path) else { return nil }
        let manifest = url.deletingLastPathComponent().appendingPathComponent(rule.manifestName).path
        return WorktreeFileSystem.isFile(manifest) ? rule : nil
    }
}

/// `lstat`-based checks shared by the worktree storage services. None of them
/// follow a symlink: a link is never a directory, never an artifact, and never
/// something to measure or delete through.
enum WorktreeFileSystem {
    /// Suffix the reclaimer appends when it renames an artifact aside before
    /// deleting it, so a concurrent build sees a clean tree, never a half-deleted
    /// one. Leftovers carrying it are finished off on the next pass.
    static let reclaimingMarker = ".astra-reclaiming-"

    static func isRealDirectory(_ path: String) -> Bool {
        guard let mode = lstatMode(path) else { return false }
        return mode & S_IFMT == S_IFDIR
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        guard let mode = lstatMode(path) else { return false }
        return mode & S_IFMT == S_IFLNK
    }

    /// True for anything that exists and is not a directory. A manifest that is
    /// itself a symlink to a file still counts: the manifest only anchors the
    /// match, and nothing ever reads or deletes through it.
    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The entry's own modification time; a symlink reports the link, not its
    /// target.
    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    /// Newest modification time among `path` and its entries down to
    /// `maxDepth` levels, without following symlinks. Shallow on purpose: a
    /// build touches the top of its scratch directory constantly, and walking a
    /// multi-gigabyte tree to learn that is too slow.
    static func newestModificationDate(under path: String, maxDepth: Int) -> Date? {
        var newest = modificationDate(path)
        guard maxDepth > 0, isRealDirectory(path),
              let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return newest
        }
        for child in children {
            let childPath = (path as NSString).appendingPathComponent(child)
            if let date = newestModificationDate(under: childPath, maxDepth: maxDepth - 1),
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }

    /// The artifact directory name a reclaim leftover was renamed from, when
    /// `name` has the `<directoryName>.astra-reclaiming-<uuid>` shape.
    static func reclaimLeftoverBaseName(_ name: String) -> String? {
        guard let range = name.range(of: reclaimingMarker) else { return nil }
        let base = String(name[..<range.lowerBound])
        let suffix = String(name[range.upperBound...])
        guard !base.isEmpty, UUID(uuidString: suffix) != nil else { return nil }
        return base
    }

    private static func lstatMode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }
}
