import Foundation
import ASTRAPersistence

enum ShelfAttachmentRootResolver {
    /// Filesystem metadata can block on remote or file-provider volumes.
    /// Only immutable paths cross the actor boundary, never SwiftData models.
    static func resolve(paths: [String], fileManager: FileManager = .default) async -> [WorkspaceFileRoot] {
        guard !paths.isEmpty else { return [] }
        let resolution = Task.detached(priority: .utility) {
            var roots: [WorkspaceFileRoot] = []
            var seen: Set<String> = []
            for rawPath in paths {
                guard !Task.isCancelled else { break }
                let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let expanded = (trimmed as NSString).expandingTildeInPath
                let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                var directory = ObjCBool(false)
                guard fileManager.fileExists(atPath: path, isDirectory: &directory) else { continue }
                roots.append(WorkspaceFileRoot(id: "input:\(path)", kind: .input,
                    title: "Input \(roots.count + 1)", path: path, isDirectory: directory.boolValue))
            }
            return roots
        }
        return await withTaskCancellationHandler {
            await resolution.value
        } onCancel: {
            resolution.cancel()
        }
    }

    static func merging(_ history: [WorkspaceFileRoot], into base: [WorkspaceFileRoot]) -> [WorkspaceFileRoot] {
        var added: [WorkspaceFileRoot] = []
        var seen = Set(base.map(\.path))
        var inputNumber = base.filter { $0.kind == .input && $0.title.hasPrefix("Input ") }.count + 1
        for root in history where seen.insert(root.path).inserted {
            added.append(WorkspaceFileRoot(id: root.id, kind: .input, title: "Input \(inputNumber)",
                path: root.path, isDirectory: root.isDirectory))
            inputNumber += 1
        }
        let insertion = base.firstIndex { $0.kind == .primary || $0.kind == .additional } ?? base.endIndex
        return Array(base[..<insertion]) + added + Array(base[insertion...])
    }
}
