import Foundation
import ASTRACore
import ASTRAModels

/// The changed-file and artifact references a context state keeps: the last
/// 50 and 30, built from every recorded change, artifact and folder file.
extension TaskContextStateManager {
    /// The keys whose entries survive `suffix(limit)` of a list that gains an
    /// entry at each key's first appearance and only merges into it after.
    ///
    /// The two reference lists below keep their last 50 and 30 entries, but
    /// built a source pointer (a regex pass over its summary) and a merge for
    /// every recorded change, artifact and file in the folder first: 45,000 of
    /// them on one task, to keep 30. Merges never move an entry, so building
    /// only the survivors' entries, from the same items in the same order,
    /// gives the same list. A nil key is an item the list skips.
    private static func survivingKeys(_ keys: [String?], limit: Int) -> Set<String> {
        var seen = Set<String>()
        var order: [String] = []
        for case let key? in keys where seen.insert(key).inserted {
            order.append(key)
        }
        return Set(order.suffix(limit))
    }

    @MainActor
    static func changedFileReferences(
        for task: AgentTask,
        discoveredFiles: [TaskOutputDiscoveredFile],
        outputs: TaskOutputPathResolver
    ) -> [TaskContextState.ChangedFile] {
        let limit = 50
        let sortedRuns = task.runs.sorted { $0.startedAt < $1.startedAt }
        let changes = sortedRuns.flatMap { run in run.fileChanges.map { (run: run, change: $0) } }
        let changeKeys = changes.map { outputs.isUserFacing($0.change.path) ? $0.change.path : nil }
        let kept = survivingKeys(changeKeys + discoveredFiles.map(\.path), limit: limit)
        var output: [TaskContextState.ChangedFile] = []
        var indexByPath: [String: Int] = [:]

        for (item, key) in zip(changes, changeKeys) {
            guard let key, kept.contains(key) else { continue }
            let (run, change) = item
            let pointers = [
                sourcePointer(kind: "run", id: run.id.uuidString, summary: "Provider run"),
                sourcePointer(kind: "file_change", id: change.id.uuidString, path: change.path, summary: "\(change.changeType) file change")
            ]
            if let index = indexByPath[key] {
                output[index].changeType = change.changeType
                output[index].sourcePointers = dedupeSourcePointers(output[index].sourcePointers + pointers)
            } else {
                indexByPath[key] = output.count
                output.append(TaskContextState.ChangedFile(
                    path: change.path,
                    changeType: change.changeType,
                    sourcePointers: pointers
                ))
            }
        }
        for file in discoveredFiles where kept.contains(file.path) {
            let pointer = sourcePointer(
                kind: "task_output_file",
                path: file.path,
                summary: "Discovered task output file \(file.relativePath)"
            )
            if let index = indexByPath[file.path] {
                output[index].sourcePointers = dedupeSourcePointers(output[index].sourcePointers + [pointer])
            } else {
                indexByPath[file.path] = output.count
                output.append(TaskContextState.ChangedFile(
                    path: file.path,
                    changeType: "discovered",
                    sourcePointers: [pointer]
                ))
            }
        }
        return Array(output.suffix(limit))
    }

    @MainActor
    static func artifactReferences(
        for task: AgentTask,
        discoveredFiles: [TaskOutputDiscoveredFile],
        outputs: TaskOutputPathResolver
    ) -> [TaskContextState.ArtifactReference] {
        let limit = 30
        // Each date read once, then sorted on the same comparisons: reading
        // `createdAt` inside the comparator paid a SwiftData getter per
        // comparison on 15,702 artifacts.
        let keyed: [(artifact: Artifact, createdAt: Date)] = task.artifacts.map { ($0, $0.createdAt) }
        let artifacts: [Artifact] = keyed.sorted { $0.createdAt < $1.createdAt }.map(\.artifact)
        let artifactEntries: [(path: String, key: String?)] = artifacts.map { artifact in
            let path = outputs.normalizedPath(artifact.path)
            guard outputs.isUserFacingNormalized(path) else { return (path, nil) }
            let key = artifactReferenceKey(path)
            return (path, key.isEmpty ? nil : key)
        }
        let fileKeys: [String?] = discoveredFiles.map { file in
            let key = artifactReferenceKey(file.path)
            return key.isEmpty ? nil : key
        }
        let kept = survivingKeys(artifactEntries.map(\.key) + fileKeys, limit: limit)
        var references: [TaskContextState.ArtifactReference] = []
        var indexByPath: [String: Int] = [:]

        for (artifact, entry) in zip(artifacts, artifactEntries) {
            guard let key = entry.key, kept.contains(key) else { continue }
            let path = entry.path
            let pointer = sourcePointer(
                kind: "artifact",
                id: artifact.id.uuidString,
                path: path,
                summary: "Generated artifact"
            )
            let incoming = TaskContextState.ArtifactReference(
                type: ArtifactKind(rawValue: artifact.type).rawValue,
                path: path,
                version: artifact.version,
                isStale: !outputs.fileExists(normalizedPath: path),
                sourcePointers: [pointer]
            )

            if let index = indexByPath[key] {
                let mergedSources = dedupeSourcePointers(references[index].sourcePointers + incoming.sourcePointers)
                if incoming.version >= references[index].version {
                    references[index] = TaskContextState.ArtifactReference(
                        type: incoming.type,
                        path: incoming.path,
                        version: incoming.version,
                        isStale: incoming.isStale,
                        sourcePointers: mergedSources
                    )
                } else {
                    references[index].sourcePointers = mergedSources
                }
            } else {
                indexByPath[key] = references.count
                references.append(incoming)
            }
        }

        for (file, key) in zip(discoveredFiles, fileKeys) {
            guard let key, kept.contains(key) else { continue }
            let pointer = sourcePointer(
                kind: "task_output_file",
                path: file.path,
                summary: "Discovered task output artifact \(file.relativePath)"
            )
            if let index = indexByPath[key] {
                references[index].sourcePointers = dedupeSourcePointers(references[index].sourcePointers + [pointer])
            } else {
                indexByPath[key] = references.count
                references.append(TaskContextState.ArtifactReference(
                    type: file.type,
                    path: file.path,
                    version: 1,
                    isStale: false,
                    sourcePointers: [pointer]
                ))
            }
        }
        return Array(references.suffix(limit))
    }

    private static func artifactReferenceKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        // Normalized and walked paths arrive standardized already; the URL
        // round trip was a quarter of the apply on a 30,000-file folder.
        guard !FilePathForm.isStandardizedAbsolute(trimmed) else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
