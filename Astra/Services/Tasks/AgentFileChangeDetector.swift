import Foundation
import SwiftData
import ASTRACore

enum AgentFileChangeDetector {
    struct FileFingerprint: Equatable {
        let size: UInt64
        let modifiedAt: Date?
        let checksum: UInt64?
    }

    static func gitStatusSnapshot(workspacePath: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", workspacePath, "status", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Set(output.split(separator: "\n").map(String.init))
    }

    @MainActor
    static func appendInferredFileChanges(
        to run: TaskRun,
        task: AgentTask,
        modelContext: ModelContext,
        workspacePath: String,
        beforeGitStatus: Set<String>,
        beforeDirtyFingerprints: [String: FileFingerprint],
        runStart: Date
    ) {
        var paths = Set<String>()
        let hostFileAccess = HostFileAccessBroker()
        let afterGitStatus = gitStatusSnapshot(workspacePath: workspacePath)
        if !afterGitStatus.isEmpty || !beforeGitStatus.isEmpty {
            for line in afterGitStatus.subtracting(beforeGitStatus) {
                if let path = absolutePath(fromGitStatusLine: line, workspacePath: workspacePath) {
                    paths.insert(path)
                }
            }

            let dirtyCandidates = absolutePaths(
                fromGitStatus: afterGitStatus.union(beforeGitStatus),
                workspacePath: workspacePath
            )
            let afterDirtyFingerprints = fileFingerprints(
                for: dirtyCandidates,
                workspacePath: workspacePath,
                hostFileAccess: hostFileAccess
            )
            for path in dirtyCandidates {
                guard let before = beforeDirtyFingerprints[path],
                      afterDirtyFingerprints[path] != before else { continue }
                paths.insert(path)
            }
            paths.formUnion(recentlyModifiedFiles(
                workspacePath: workspacePath,
                since: runStart,
                limitedTo: dirtyCandidates,
                hostFileAccess: hostFileAccess
            ))
        } else {
            paths.formUnion(recentlyModifiedFiles(
                workspacePath: workspacePath,
                since: runStart,
                hostFileAccess: hostFileAccess
            ))
        }

        let userPaths = paths.filter { !isIgnoredRuntimePath($0, workspacePath: workspacePath) }
        let existing = Set(run.fileChanges.map(\.path))
        for path in userPaths.subtracting(existing).sorted().prefix(50) {
            let change = FileChange(
                path: path,
                changeType: .edit,
                content: "Detected after Copilot run",
                oldString: nil,
                newString: nil,
                timestamp: Date()
            )
            let storedChange = StoredFileChange(from: change)
            run.appendFileChange(storedChange)
            TaskArtifactPersistenceService.persistFileChangeArtifact(storedChange, for: task, modelContext: modelContext)
        }
    }

    static func absolutePaths(fromGitStatus lines: Set<String>, workspacePath: String) -> Set<String> {
        Set(lines.compactMap { absolutePath(fromGitStatusLine: $0, workspacePath: workspacePath) })
    }

    static func fileFingerprints(
        for paths: Set<String>,
        workspacePath: String? = nil,
        hostFileAccess: HostFileAccessBroker = HostFileAccessBroker()
    ) -> [String: FileFingerprint] {
        let intent = workspacePath.map {
            HostFileAccessIntent.implicitScan(root: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? .explicitUserSelection
        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            guard let fingerprint = fileFingerprint(
                path: path,
                hostFileAccess: hostFileAccess,
                intent: intent
            ) else { return nil }
            return (path, fingerprint)
        })
    }

    private static func absolutePath(fromGitStatusLine line: String, workspacePath: String) -> String? {
        let pathPart = String(line.dropFirst(min(3, line.count))).trimmingCharacters(in: .whitespaces)
        let normalized = pathPart.components(separatedBy: " -> ").last ?? pathPart
        guard !normalized.isEmpty else { return nil }
        return (workspacePath as NSString).appendingPathComponent(normalized)
    }

    private static func fileFingerprint(
        path: String,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let checksum: UInt64?
        if size <= 5_000_000,
           let data = try? hostFileAccess.readData(at: URL(fileURLWithPath: path), intent: intent) {
            checksum = data.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
                (partial ^ UInt64(byte)) &* 1_099_511_628_211
            }
        } else {
            checksum = nil
        }
        return FileFingerprint(size: size, modifiedAt: modified, checksum: checksum)
    }

    private static func recentlyModifiedFiles(
        workspacePath: String,
        since: Date,
        limitedTo candidates: Set<String>? = nil,
        hostFileAccess: HostFileAccessBroker = HostFileAccessBroker()
    ) -> Set<String> {
        let root = URL(fileURLWithPath: workspacePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let normalizedCandidates = candidates.map { paths in
            Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        }
        let intent = HostFileAccessIntent.implicitScan(root: root)
        guard let enumerator = hostFileAccess.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            intent: intent
        ) else { return [] }

        var result = Set<String>()
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 5000 { break }
            let itemURL = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard itemURL.path.hasPrefix(rootPath) else { continue }
            if hostFileAccess.shouldSkip(itemURL, intent: intent) {
                enumerator.skipDescendants()
                continue
            }
            let rel = String(itemURL.path.dropFirst(rootPath.count))
            if isIgnoredRuntimeRelativePath(rel) {
                continue
            }
            if let normalizedCandidates, !normalizedCandidates.contains(itemURL.path) {
                continue
            }
            guard let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= since else {
                continue
            }
            result.insert(itemURL.path)
            if result.count >= 50 { break }
        }
        return result
    }

    private static func isIgnoredRuntimePath(_ path: String, workspacePath: String) -> Bool {
        let workspaceURL = URL(fileURLWithPath: workspacePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        let normalized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard normalized.hasPrefix(rootPath) else { return false }
        let rel = String(normalized.dropFirst(rootPath.count))
        return isIgnoredRuntimeRelativePath(rel)
    }

    private static func isIgnoredRuntimeRelativePath(_ relativePath: String) -> Bool {
        let rel = relativePath.replacingOccurrences(of: "\\", with: "/")
        return rel.hasPrefix(".git/")
            || rel.hasPrefix(".astra/")
            || rel.hasPrefix(".agentflow/")
            || rel.hasPrefix(".codex/")
            || rel.hasPrefix(".claude/")
            || rel.hasPrefix(".gemini/")
            || rel.hasPrefix("node_modules/")
            || rel.hasPrefix(".build/")
            || rel == "cache/projects.json"
    }
}
