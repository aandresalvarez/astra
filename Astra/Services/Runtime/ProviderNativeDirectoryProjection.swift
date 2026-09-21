import Foundation
import ASTRACore

/// Projects a mixed list of granted resource paths onto the directory-only
/// `--add-dir` interface the native CLI providers expose.
///
/// `TaskWorkspaceAccess.runtimeReadOnlyInputPaths` deliberately carries single
/// files alongside directories so Docker mounts and the Seatbelt launch plan
/// cover exactly what the user attached. Provider argv cannot: Copilot and
/// Codex both reject a non-directory `--add-dir` value outright, so a task
/// whose input is an attached file dies in argument parsing before the
/// provider emits a single token.
///
/// Widening a file grant to its parent is not a safe substitute — `--add-dir`
/// confers WRITE access, so the parent would authorize sibling writes the user
/// never granted. A file already inside an authorized root is therefore
/// dropped as redundant, and a file outside every root is reported so the
/// caller can surface it instead of failing closed inside the provider.
enum ProviderNativeDirectoryProjection {
    struct Result: Equatable {
        let additionalDirectories: [String]
        let unreachableFiles: [String]

        static let empty = Result(additionalDirectories: [], unreachableFiles: [])
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func project(
        resourcePaths: [String],
        alreadyReachableDirectories: [String],
        fileManager: FileManager = .default
    ) -> Result {
        var reachableIdentities = alreadyReachableDirectories.compactMap(ExecutionSandbox.canonicalize)
        var seenDirectories = Set(reachableIdentities)
        var additionalDirectories: [String] = []
        var files: [(path: String, identity: String)] = []
        for rawPath in resourcePaths {
            let path = WorkspacePathPresentation.standardizedPath(rawPath)
            guard !path.isEmpty else { continue }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                continue
            }
            let identity = ExecutionSandbox.canonicalize(path) ?? path
            if isDirectory.boolValue {
                if !reachableIdentities.contains(where: { isSameOrDescendant(identity, of: $0) }),
                   seenDirectories.insert(identity).inserted {
                    additionalDirectories.append(path)
                    reachableIdentities.append(identity)
                }
            } else {
                files.append((path, identity))
            }
        }
        let unreachableFiles = files.compactMap { file in
            reachableIdentities.contains(where: { isSameOrDescendant(file.identity, of: $0) })
                ? nil
                : file.path
        }
        return Result(
            additionalDirectories: additionalDirectories,
            unreachableFiles: unreachableFiles
        )
    }

    /// Defensive filter for a launch builder that receives an already-planned
    /// path list. A path that exists and is not a directory can never be a
    /// valid `--add-dir` value, so it is dropped here even if a caller skipped
    /// `project(resourcePaths:alreadyReachableDirectories:)`. Paths that do not
    /// exist yet are left alone: a workspace root created during the run is
    /// still a legitimate grant, and launch plans are built before the task
    /// folder exists.
    static func directoryCandidates(
        _ paths: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        paths.filter { path in
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return true }
            return isDirectory.boolValue
        }
    }
}
