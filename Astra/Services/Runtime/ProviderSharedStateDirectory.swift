import Darwin
import Foundation

/// A locked file and its ownership pointer must keep the same parent through
/// waits and callbacks. All I/O uses this directory descriptor.
final class ProviderSharedStateDirectory: @unchecked Sendable {
    let url: URL
    let descriptor: Int32

    init(_ url: URL) throws {
        self.url = url
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = open("/", flags)
        guard current >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        do {
            for component in self.url.path.split(separator: "/") {
                let name = String(component)
                guard name != ".", name != ".." else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
                var next = openat(current, name, flags)
                if next < 0, errno == ENOENT {
                    guard mkdirat(current, name, 0o700) == 0 || errno == EEXIST else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
                    next = openat(current, name, flags)
                }
                guard next >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
                close(current)
                current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw RuntimeExecutionOwnerStore.Failure.unsafePath
            }
        } catch { close(current); throw error }
        descriptor = current
    }

    deinit { close(descriptor) }

    func verifyLocation() throws {
        let current = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard current >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
        defer { close(current) }
        var named = stat(), held = stat()
        guard fstat(current, &named) == 0, fstat(descriptor, &held) == 0,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw RuntimeExecutionOwnerStore.Failure.unsafePath }
    }

    func names() throws -> [String] {
        let scan = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scan >= 0 else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        guard let iterator = fdopendir(scan) else { close(scan); throw RuntimeExecutionOwnerStore.Failure.unreadable }
        defer { closedir(iterator) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(iterator) else {
                guard errno == 0 else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
                return result
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            result.append(name)
        }
    }
}
