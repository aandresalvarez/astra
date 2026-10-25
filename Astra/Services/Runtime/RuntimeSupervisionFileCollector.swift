import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Filesystem calls live in bounded subprocesses. A detached Foundation walk
/// can remain blocked on a mounted filesystem after its Swift task is cancelled.
enum RuntimeSupervisionFileCollector {
    static func captureWorkspace(root: String) async -> RuntimeSupervisionFiles {
        guard root.hasPrefix("/"), root != "/", !Task.isCancelled else { return .init(unavailable: "No authorized workspace.") }
        let prefixResult = await ProcessBinaryRunner().run(path: "/usr/bin/git", args: ["rev-parse", "--show-prefix"],
            timeout: 2, environment: nil, currentDirectory: root, maximumOutputBytes: 4_096, terminateProcessGroup: true)
        guard prefixResult.isSuccess, !prefixResult.stdoutTruncated else { return await capture(root: root) }
        let prefix = prefixResult.stdout.trimmingCharacters(in: .newlines)
        let status = await ProcessBinaryRunner().run(path: "/usr/bin/git",
            args: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                   "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."],
            timeout: 3, environment: nil, currentDirectory: root,
            maximumOutputBytes: 65_536, terminateProcessGroup: true)
        guard status.isSuccess, !status.stdoutTruncated else {
            // A small non-Git workspace still has useful artifact evidence.
            return await capture(root: root)
        }
        var paths: [String] = [], skipRenameSource = false
        for entry in status.stdout.split(separator: "\0") {
            if skipRenameSource { skipRenameSource = false; continue }
            guard entry.count >= 4 else { return .init(unavailable: "Workspace status was incomplete.") }
            let kind = entry.prefix(2)
            skipRenameSource = kind.contains("R") || kind.contains("C")
            if kind.contains("D") { continue } // deletion time is unknown
            let repositoryPath = String(entry.dropFirst(3))
            guard repositoryPath.hasPrefix(prefix) else { continue }
            let relative = String(repositoryPath.dropFirst(prefix.count))
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                return .init(unavailable: "Workspace status contained an invalid path.")
            }
            paths.append((root as NSString).appendingPathComponent(relative))
        }
        guard paths.count <= 200 else { return .init(unavailable: "More than 200 workspace files changed.") }
        return await metadata(paths: paths.sorted(), root: root)
    }

    static func capture(root: String) async -> RuntimeSupervisionFiles {
        guard root.hasPrefix("/"), root != "/", !Task.isCancelled else {
            return .init(unavailable: "No authorized task folder is available.")
        }
        let runner = ProcessBinaryRunner()
        let listing = await runner.run(
            path: "/usr/bin/find", args: ["-P", root, "-name", ".*", "-prune", "-o", "-type", "f", "-print0"],
            timeout: 3, environment: nil, currentDirectory: nil, maximumOutputBytes: 32_768, terminateProcessGroup: true)
        guard listing.isSuccess, !listing.stdoutTruncated, !Task.isCancelled else {
            return .init(unavailable: "Task folder inspection was unavailable, cancelled or exceeded its limit.")
        }
        let paths = listing.stdout.split(separator: "\0").map(String.init)
        guard paths.count <= 200 else { return .init(unavailable: "Task folder exceeds the 200-file inspection limit.") }
        let visible = paths.filter { path in
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return TaskOutputArtifactPathPolicy.displayableUserArtifactRelativePath(relative, context: .taskFolder) != nil
        }.sorted()
        return await metadata(paths: visible, root: root)
    }

    private static func metadata(paths: [String], root: String) async -> RuntimeSupervisionFiles {
        guard !paths.isEmpty else { return .init() }
        let metadata = await ProcessBinaryRunner().run(
            path: "/usr/bin/stat", args: ["-f", "%m|%c|%z|%i"] + paths,
            timeout: 3, environment: nil, currentDirectory: nil, maximumOutputBytes: 32_768, terminateProcessGroup: true)
        let rows = metadata.stdout.split(separator: "\n").map(String.init)
        guard metadata.isSuccess, !metadata.stdoutTruncated, rows.count == paths.count else {
            return .init(unavailable: "File metadata changed during inspection or could not be read.")
        }
        var entries: [String: String] = [:]
        for (path, row) in zip(paths, rows) {
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            entries[relative] = row
        }
        return .init(metadata: entries)
    }
}
