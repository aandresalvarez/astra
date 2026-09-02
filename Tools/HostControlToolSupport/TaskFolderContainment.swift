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
