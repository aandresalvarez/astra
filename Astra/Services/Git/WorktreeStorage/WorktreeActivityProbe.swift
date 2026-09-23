import Darwin
import Foundation

/// Why a build-artifact directory must not be touched right now.
enum WorktreeBuildSignal: Equatable, Sendable {
    /// SwiftPM (or sourcekit-lsp's index build) holds its workspace lock.
    case swiftPMLockHeld(lockPath: String)
    /// `.build/.lock` names a live SwiftPM process.
    case swiftPMProcessAlive(pid: Int32)
    /// Something wrote near the top of the directory within the recent window.
    case recentlyModified(Date)

    var summary: String {
        switch self {
        case .swiftPMLockHeld:
            return "build in progress (SwiftPM holds its lock)"
        case let .swiftPMProcessAlive(pid):
            return "build in progress (SwiftPM process \(pid))"
        case .recentlyModified:
            return "build in progress (written in the last 15 minutes)"
        }
    }
}

/// SwiftPM's workspace lock, as verified against Swift 6.4 (see
/// `docs/specs/2026-09-23-worktree-storage-hygiene.md`, "Verification
/// results"). The lock is *not* under `.build`: it is an `flock(2)` on
/// `$TMPDIR/<name>.lock`, where `<name>` is the scratch directory's canonical
/// path with `/` replaced by `_`, trimmed to its last 255 UTF-8 bytes.
/// `.build/.lock` only records the holder's PID; SwiftPM never locks or
/// deletes it, so it is often stale.
enum SwiftPMWorkspaceLock {
    /// Subdirectory sourcekit-lsp uses as its own SwiftPM scratch path for
    /// background indexing. It takes its own workspace lock.
    static let indexBuildDirectoryName = "index-build"
    /// Executables that write `.build/.lock`. `proc_pidpath` resolves the
    /// Xcode toolchain's `swift-build`/`swift-test` symlinks to `swift-package`.
    static let processNames: Set<String> = ["swift-build", "swift-test", "swift-run", "swift-package"]

    private static let maxNameBytes = 255

    /// The lock file name SwiftPM derives from a canonical scratch path.
    static func lockFileName(forCanonicalScratchPath path: String) -> String {
        let name = path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_") + ".lock"
        var bytes = Array(name.utf8)
        guard bytes.count > maxNameBytes else { return name }
        bytes = Array(bytes.suffix(maxNameBytes))
        // Back off to a scalar boundary, as SwiftPM does.
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The lock file for a scratch directory. SwiftPM resolves symlinks in the
    /// scratch directory's parent, then appends the directory name.
    static func lockFileURL(forScratchPath scratchPath: String, temporaryDirectory: URL) -> URL {
        let scratch = URL(fileURLWithPath: scratchPath)
        let parent = scratch.deletingLastPathComponent().path
        let canonicalParent = WorktreePath.realPath(parent) ?? parent
        let canonicalScratch = (canonicalParent as NSString).appendingPathComponent(scratch.lastPathComponent)
        return temporaryDirectory.appendingPathComponent(
            lockFileName(forCanonicalScratchPath: canonicalScratch),
            isDirectory: false
        )
    }

    /// The scratch paths whose locks guard an artifact: the artifact itself
    /// and, when present, sourcekit-lsp's index build inside it.
    static func guardedScratchPaths(forArtifactAt artifactPath: String) -> [String] {
        let indexBuild = (artifactPath as NSString).appendingPathComponent(indexBuildDirectoryName)
        return WorktreeFileSystem.isRealDirectory(indexBuild) ? [artifactPath, indexBuild] : [artifactPath]
    }

    /// True when another process holds the lock. Opens read-only and never
    /// creates the file: a missing file means nobody has built with this
    /// temporary directory, so nothing holds it.
    static func isHeld(lockFile: URL) -> Bool {
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Takes the lock the way SwiftPM does (`O_CREAT`, `0666`) without
    /// blocking. Returns nil when another process holds it or the file can't
    /// be opened. While held, a SwiftPM process that starts waits for release.
    static func tryAcquire(lockFile: URL) -> HeldLock? {
        let fd = open(lockFile.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return HeldLock(fileDescriptor: fd)
    }

    /// An acquired lock. Released explicitly; the kernel also drops it if the
    /// process dies.
    final class HeldLock {
        private var fileDescriptor: Int32

        fileprivate init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        func release() {
            guard fileDescriptor >= 0 else { return }
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }

        deinit { release() }
    }
}

/// Read-only probe for "is anything using this build-artifact directory right
/// now" and "when was this worktree last touched". It inspects the file system
/// only; task timestamps and the HEAD commit date come from the caller.
struct WorktreeActivityProbe: Sendable {
    /// A write this recent means a build (or an agent) is working.
    static let recentWriteWindow: TimeInterval = 15 * 60
    /// Depth of the shallow modification-time scan, counted from the artifact.
    static let shallowScanDepth = 3

    /// Where SwiftPM keeps its locks. ASTRA isn't sandboxed and passes `TMPDIR`
    /// through to agents, so this is the directory agents lock in by default.
    var temporaryDirectory: URL
    /// Process name for a live PID, or nil when no such process exists.
    var processName: @Sendable (Int32) -> String?

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processName: @escaping @Sendable (Int32) -> String? = WorktreeActivityProbe.liveProcessName
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.processName = processName
    }

    /// The first reason the artifact is in use, checked cheapest-first except
    /// that the authoritative lock comes before the heuristics.
    func buildSignal(forArtifactAt artifactPath: String, rule: WorktreeArtifactRule, now: Date) -> WorktreeBuildSignal? {
        if rule.ecosystem == .swiftPM {
            for scratch in SwiftPMWorkspaceLock.guardedScratchPaths(forArtifactAt: artifactPath) {
                let lockFile = SwiftPMWorkspaceLock.lockFileURL(
                    forScratchPath: scratch,
                    temporaryDirectory: temporaryDirectory
                )
                if SwiftPMWorkspaceLock.isHeld(lockFile: lockFile) {
                    return .swiftPMLockHeld(lockPath: lockFile.path)
                }
            }
            if let pid = liveSwiftPMProcess(forArtifactAt: artifactPath) {
                return .swiftPMProcessAlive(pid: pid)
            }
        }
        if let modified = WorktreeFileSystem.newestModificationDate(
            under: artifactPath,
            maxDepth: Self.shallowScanDepth
        ), now.timeIntervalSince(modified) < Self.recentWriteWindow {
            return .recentlyModified(modified)
        }
        return nil
    }

    /// Newest shallow modification time of an artifact directory.
    func artifactModificationDate(_ artifactPath: String) -> Date? {
        WorktreeFileSystem.newestModificationDate(under: artifactPath, maxDepth: Self.shallowScanDepth)
    }

    /// Modification time of the worktree's git index, which moves on every
    /// stage, commit, checkout and status refresh that rewrites it.
    func gitIndexModificationDate(worktreePath: String) -> Date? {
        guard let gitDirectory = Self.gitDirectory(forWorktree: worktreePath) else { return nil }
        return WorktreeFileSystem.modificationDate((gitDirectory as NSString).appendingPathComponent("index"))
    }

    /// The PID recorded in `.build/.lock`, when it names a live SwiftPM process.
    private func liveSwiftPMProcess(forArtifactAt artifactPath: String) -> Int32? {
        let breadcrumb = (artifactPath as NSString).appendingPathComponent(".lock")
        guard let data = FileManager.default.contents(atPath: breadcrumb), data.count <= 32,
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let name = processName(pid),
              SwiftPMWorkspaceLock.processNames.contains(name) else { return nil }
        return pid
    }

    /// The worktree's git directory: `.git` itself for a primary checkout, or
    /// the `gitdir:` target of a linked worktree's `.git` file.
    static func gitDirectory(forWorktree worktreePath: String) -> String? {
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")
        if WorktreeFileSystem.isRealDirectory(dotGit) { return dotGit }
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            if target.hasPrefix("/") { return target }
            return ((worktreePath as NSString).appendingPathComponent(target) as NSString).standardizingPath
        }
        return nil
    }

    /// The live process's executable name, or nil when the PID is gone.
    @Sendable static func liveProcessName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
