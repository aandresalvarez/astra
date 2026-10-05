import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct ValidationArtifactAccess {
    let scope: TaskExecutionResourceScope?
    let taskFolder: String
    let workspacePath: String

    @MainActor
    init(task: AgentTask, workspacePath: String, scope: TaskExecutionResourceScope?) {
        self.scope = scope
        self.workspacePath = workspacePath.isEmpty ? "" : TaskExecutionResourceScope.canonicalPath(workspacePath)
        if let scope {
            taskFolder = scope.resources.first { $0.role == .taskStorage }?.canonicalPath ?? ""
        } else {
            let folder = TaskWorkspaceAccess(task: task).taskFolder
            taskFolder = folder.isEmpty ? "" : TaskExecutionResourceScope.canonicalPath(folder)
        }
    }

    var isValid: Bool {
        guard let scope else { return true }
        let acceptedPath = scope.workingDirectory.isEmpty ? "" : TaskExecutionResourceScope.canonicalPath(scope.workingDirectory)
        return scope.isValid && workspacePath == acceptedPath
    }

    func candidates(for path: String) -> [String] {
        roots.map { ($0 as NSString).appendingPathComponent(path) }
    }

    func root(containing path: String) -> String? {
        guard isValid, scope?.coversRead(to: path) != false else { return nil }
        let resolved = TaskExecutionResourceScope.canonicalPath(path)
        return roots.first { TaskExecutionResourceScope.contains($0, resolved) }
    }

    func readText(at path: String) -> String? {
        guard let root = root(containing: path) else { return nil }
        return try? HostFileAccessBroker().readString(
            at: URL(fileURLWithPath: path), encoding: .utf8,
            intent: .astraManagedStorage(root: URL(fileURLWithPath: root, isDirectory: true))
        )
    }

    func writeEvidence(_ data: Data, filename: String) throws -> String {
        let base = taskFolder.isEmpty && scope == nil ? workspacePath : taskFolder
        let directory = (base as NSString).appendingPathComponent("validation-evidence")
        let path = (directory as NSString).appendingPathComponent(filename)
        guard !base.isEmpty, isValid,
              TaskExecutionResourceScope.contains(base, TaskExecutionResourceScope.canonicalPath(directory)),
              TaskExecutionResourceScope.contains(base, TaskExecutionResourceScope.canonicalPath(path)),
              scope?.coversWrite(to: directory) != false, scope?.coversWrite(to: path) != false else {
            throw EvidenceError.outsideAcceptedStorage
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    private var roots: [String] {
        var result = [String]()
        for root in [taskFolder, workspacePath] where !root.isEmpty && !result.contains(root) {
            result.append(root)
        }
        return result
    }

    private enum EvidenceError: LocalizedError {
        case outsideAcceptedStorage

        var errorDescription: String? {
            "Validation evidence cannot be written outside the accepted task-storage scope."
        }
    }
}
