import Darwin
import Foundation

public enum RemoteWorkspaceJobProtectedFile {
    public static func read(_ url: URL, maximumBytes: Int = 1_048_576) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unreadable(url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes,
              let data = try handle.readToEnd(), data.count <= maximumBytes else {
            throw RemoteWorkspaceJobStoreError.unsafePath(url.path)
        }
        return data
    }

    public static func write(_ data: Data, to url: URL) throws {
        let root = url.deletingLastPathComponent()
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw RemoteWorkspaceJobStoreError.unsafePath(root.path) }
        defer { close(parent) }
        let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteWorkspaceJobStoreError.unsafePath(url.path) }
        defer { close(fd); unlink(temporary.path) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0, fsync(parent) == 0 else {
            throw RemoteWorkspaceJobStoreError.unreadable(url.path)
        }
    }
}
