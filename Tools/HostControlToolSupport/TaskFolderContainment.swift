import Foundation

/// Keeps a directory the broker composes under the task folder actually under
/// the task folder.
///
/// The task folder is agent-writable and this broker is **not** sandboxed to
/// it: it runs with the host's access so it can hold credentials the agent must
/// not. That combination is what makes a pre-created symlink dangerous. An
/// agent that creates `redcap-exports` or `connector-mutations` as a link to a
/// git checkout gets a `createDirectory` that succeeds against the link target
/// — `FileManager` has no don't-follow option — and every file the broker
/// writes afterwards lands outside the folder the user granted, one `git add .`
/// from being committed.
///
/// Three rules, and all three are load-bearing:
///
/// - **Reject the link by name, before creating.** `fileExists` follows a link;
///   `attributesOfItem` is `lstat`-backed and reports the link itself.
/// - **Re-resolve afterwards.** The name check cannot see an intermediate
///   component that is a link, or one swapped in between the two calls.
/// - **Resolve the *root* first.** Resolving the child and then comparing it to
///   itself is circular and proves nothing — which is exactly the check
///   `ConnectorMutationStaging.read` used to make.
///
/// Shared by both brokers on purpose. This was fixed once for REDCap exports
/// and the connector-mutation staging directory had the identical hole; two
/// copies of a containment rule is one copy and one hole.
///
/// **Validating a path is not enough for a write.** The three rules above answer
/// "is this directory inside the task folder" at the moment they are asked, and
/// return a *pathname*. A pathname is re-resolved by every later `open`, so an
/// agent that renames the validated directory and drops a symlink in its place
/// wins the race: the checks passed, and the write that follows lands wherever
/// the new link points. Callers that write must take a
/// `TaskFolderDirectoryHandle` and write through it — an open descriptor names
/// an inode, and no amount of renaming afterwards can redirect it.
enum TaskFolderContainment {
    /// The task folder with every symlink resolved. The root of every
    /// containment comparison here.
    static func resolvedRoot(_ taskFolder: String) -> URL {
        URL(fileURLWithPath: taskFolder, isDirectory: true).resolvingSymlinksInPath()
    }

    /// Creates `name` directly beneath `root`, refusing to follow a symlink out
    /// of it. Returns the resolved directory.
    ///
    /// - Parameters:
    ///   - refusal: what this broker will not do through a link, e.g. "write
    ///     subject data". Appears in the error the agent reads.
    ///   - makeError: the caller's own error type, so a containment failure is
    ///     reported in the same vocabulary as the rest of that tool.
    static func createDirectory(
        named name: String,
        beneath root: URL,
        refusal: String,
        fileManager: FileManager = .default,
        makeError: (String) -> Error
    ) throws -> URL {
        try directory(named: name, beneath: root, creating: true, refusal: refusal, fileManager: fileManager, makeError: makeError)
    }

    /// Creates `name` beneath `root` and returns an **open descriptor** for it.
    ///
    /// This is the API a write path must use. `createDirectory` above answers a
    /// question about a pathname and then hands the pathname back; between that
    /// answer and the `open` inside the write, the agent owns the directory
    /// entry and can replace it with a link. Everything the caller does through
    /// this handle is `openat`/`linkat` relative to a descriptor, so it is
    /// pinned to the inode that was validated and a later rename is inert.
    ///
    /// The descriptor is opened `O_NOFOLLOW` so the final component cannot be a
    /// link even at the instant it is opened, and containment is re-checked
    /// against `F_GETPATH` — the kernel's own answer for where this descriptor
    /// actually is, which is the only check that cannot be raced.
    static func openDirectory(
        named name: String,
        beneath root: URL,
        refusal: String,
        fileManager: FileManager = .default,
        makeError: (String) -> Error
    ) throws -> TaskFolderDirectoryHandle {
        let resolved = try directory(
            named: name,
            beneath: root,
            creating: true,
            refusal: refusal,
            fileManager: fileManager,
            makeError: makeError
        )
        let descriptor = resolved.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw makeError(
                "ASTRA could not open the \(name) directory in this task folder: "
                    + String(cString: strerror(errno))
            )
        }
        // Asked of the descriptor, not of the name. If the entry was swapped
        // between the checks above and this `open`, the descriptor points at
        // wherever the swap led and this is what notices.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else {
            close(descriptor)
            throw makeError("ASTRA could not confirm where the \(name) directory is. Refusing to \(refusal).")
        }
        //
        // Normalised the same way the root was, because `F_GETPATH` answers with
        // the kernel's canonical path — `/private/var/...` on macOS — while every
        // other path in the app has been through `resolvingSymlinksInPath()`,
        // which strips the `/private` prefix back off. Comparing the two forms
        // directly says a directory is outside a root that is its own parent, and
        // handing the unnormalised form back as a receipt would make the staged
        // path the app records differ from the one a later scan of the same
        // directory produces — the same file, under two names, reviewed twice.
        let actual = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .resolvingSymlinksInPath()
        guard contains(actual, root: root) else {
            close(descriptor)
            throw makeError(
                "The \(name) directory in this task folder resolves to \(actual.path), which is outside "
                    + "the task folder. Refusing to \(refusal) there."
            )
        }
        return TaskFolderDirectoryHandle(descriptor: descriptor, path: actual.path)
    }

    /// The same guarantees for a directory that is only being read.
    ///
    /// Read paths need this as much as write paths: the reader is what decides
    /// whether a path in an authorization is inside the task folder, so a
    /// symlinked directory there turns a staged-file read into an arbitrary-file
    /// read.
    static func existingDirectory(
        named name: String,
        beneath root: URL,
        refusal: String,
        fileManager: FileManager = .default,
        makeError: (String) -> Error
    ) throws -> URL {
        try directory(named: name, beneath: root, creating: false, refusal: refusal, fileManager: fileManager, makeError: makeError)
    }

    /// Component-wise containment.
    ///
    /// Not a string prefix: `/tmp/task` does not contain `/tmp/task-other`, and
    /// a prefix comparison says it does.
    static func contains(_ url: URL, root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= rootParts.count else { return false }
        return Array(parts.prefix(rootParts.count)) == rootParts
    }

    private static func directory(
        named name: String,
        beneath root: URL,
        creating: Bool,
        refusal: String,
        fileManager: FileManager,
        makeError: (String) -> Error
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        if let type = try? fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw makeError(
                "The \(name) directory in this task folder is a symbolic link. ASTRA will not \(refusal) "
                    + "through it, because it can point outside the task folder. Remove the link and let "
                    + "ASTRA create a real directory."
            )
        }
        if creating {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw makeError(
                    "ASTRA could not create the \(name) directory in this task folder: "
                        + error.localizedDescription
                )
            }
        }
        let resolved = directory.resolvingSymlinksInPath()
        guard contains(resolved, root: root) else {
            throw makeError(
                "The \(name) directory in this task folder resolves to \(resolved.path), which is outside "
                    + "the task folder. Refusing to \(refusal) there."
            )
        }
        return resolved
    }
}

/// An open descriptor for a directory that has been proven to be inside the
/// task folder, and the only way a broker should write into one.
///
/// The whole value is that every operation here is relative to `descriptor`
/// rather than to a path. A descriptor refers to the inode it was opened on, so
/// once containment has been established it stays established: renaming the
/// directory, replacing it with a symlink, or swapping a parent component
/// afterwards changes nothing about where these writes go. Path-based writes
/// re-resolve on every call and give that guarantee back.
///
/// `path` is carried for receipts and error text only. Nothing in here uses it
/// to reach the filesystem.
final class TaskFolderDirectoryHandle {
    let descriptor: Int32
    let path: String

    init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit { close(descriptor) }

    /// Creates `name` inside this directory and writes `data`, failing if the
    /// name is taken.
    ///
    /// `O_EXCL` so an existing entry — including a symlink the agent planted
    /// under the name the broker is about to use — is a failure rather than a
    /// target, and `O_NOFOLLOW` so the same is true in the race where it appears
    /// between the two. Returns the path for the receipt.
    @discardableResult
    func writeExclusively(_ data: Data, named name: String) throws -> String {
        let fd = name.withCString {
            openat(descriptor, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw TaskFolderDirectoryHandle.posixError(errno, while: "create \(name)") }
        do {
            try TaskFolderDirectoryHandle.writeAll(fd, data)
            guard fsync(fd) == 0 else { throw TaskFolderDirectoryHandle.posixError(errno, while: "flush \(name)") }
        } catch {
            close(fd)
            name.withCString { _ = unlinkat(descriptor, $0, 0) }
            throw error
        }
        close(fd)
        return (path as NSString).appendingPathComponent(name)
    }

    /// Hard-links `temporary` to `name`, reporting whether the name was free.
    ///
    /// `linkat` refuses when the new name exists, which is what makes probing
    /// for a free name safe: the filesystem decides, not a prior `stat` whose
    /// answer the agent can invalidate.
    func link(temporary: String, to name: String) -> Int32 {
        temporary.withCString { old in
            name.withCString { new in
                linkat(descriptor, old, descriptor, new, 0) == 0 ? 0 : errno
            }
        }
    }

    func removeFile(named name: String) {
        name.withCString { _ = unlinkat(descriptor, $0, 0) }
    }

    /// Flushes the directory itself, so the entries created above survive a
    /// crash rather than just the bytes inside them.
    func synchronize() {
        _ = fsync(descriptor)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno, while: "write")
                }
                offset += written
            }
        }
    }

    private static func posixError(_ code: Int32, while action: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(action): \(String(cString: strerror(code)))"]
        )
    }
}
