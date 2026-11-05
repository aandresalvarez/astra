import Darwin
import Foundation
import ASTRACore

/// Bind a cleanup publication to the physical recovery folder registered
/// before capture. A lexical workspace path (or its .astra folder) can be a
/// symlink, and can change without making a SQLite commit.
struct WorkspaceCleanupMirrorDestination: Sendable {
    private struct Directory: Equatable, Sendable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int

        init(_ url: URL) throws {
            path = url.standardizedFileURL.resolvingSymlinksInPath().path
            var info = stat()
            guard stat(path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnknown) }
            device = info.st_dev
            inode = info.st_ino
            createdSeconds = info.st_birthtimespec.tv_sec
            createdNanoseconds = info.st_birthtimespec.tv_nsec
        }

        func matches(_ descriptor: Int32) -> Bool {
            var info = stat()
            return fstat(descriptor, &info) == 0 && info.st_dev == device && info.st_ino == inode
                && info.st_birthtimespec.tv_sec == createdSeconds && info.st_birthtimespec.tv_nsec == createdNanoseconds
        }
    }

    private let workspaceURL: URL
    private let supportURL: URL
    private let workspace: Directory
    private let support: Directory
    let url: URL
    var registeredWorkspacePath: String { workspace.path }

    init(workspacePath: String) throws {
        workspaceURL = URL(fileURLWithPath: WorkspacePathPresentation.standardizedPath(workspacePath))
        workspace = try Directory(workspaceURL)
        guard let target = WorkspaceConfigManager.autoExportTarget(for: workspacePath).url else {
            throw CocoaError(.fileWriteUnknown)
        }
        supportURL = target.deletingLastPathComponent()
        support = try Directory(supportURL)
        // Resolve only the directory. Atomic replacement must replace a
        // mirror symlink itself, never follow it to another file.
        url = URL(fileURLWithPath: support.path, isDirectory: true).appendingPathComponent(target.lastPathComponent)
    }

    var isCurrent: Bool {
        (try? Directory(workspaceURL)) == workspace && (try? Directory(supportURL)) == support
    }

    /// Hold just one directory descriptor during this write, not one per
    /// workspace for the whole batch. Relative staging, rename and unlink
    /// keep a retarget after the last check from writing into another folder.
    func withDirectory<T>(_ write: (Int32) throws -> T?) throws -> T? {
        guard isCurrent else { return nil }
        let descriptor = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard support.matches(descriptor), isCurrent else { return nil }
        return try write(descriptor)
    }
}
