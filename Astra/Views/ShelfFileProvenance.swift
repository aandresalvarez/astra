import Foundation
import ASTRAModels
import ASTRAPersistence

enum ShelfFileProvenance: String, Hashable, Sendable {
    case taskGenerated
    case userProvided
    case currentTaskOutput
    case otherTaskOutput
    case workspace

    var label: String {
        switch self {
        case .taskGenerated: "Generated"
        case .userProvided: "User provided"
        case .currentTaskOutput: "Current task"
        case .otherTaskOutput: "Other task"
        case .workspace: "Workspace"
        }
    }

    var groupTitle: String {
        switch self {
        case .taskGenerated, .currentTaskOutput: "Task Generated"
        case .userProvided: "User Provided"
        case .otherTaskOutput: "Other Task Outputs"
        case .workspace: "Workspace Files"
        }
    }
}

enum ShelfFileProvenanceResolver {
    static func currentTaskOutputFolderNames(for task: AgentTask?) -> Set<String> {
        guard let task else { return [] }
        return [String(task.id.uuidString.prefix(8))]
    }

    static func provenance(
        for root: WorkspaceFileRoot,
        node: WorkspaceFileNode? = nil,
        currentTaskOutputFolderNames: Set<String> = []
    ) -> ShelfFileProvenance {
        switch root.kind {
        case .taskFolder:
            return .taskGenerated
        case .input:
            return .userProvided
        case .primary, .additional:
            guard let node,
                  let taskFolderName = legacyTaskFolderName(in: node.relativePath) else {
                return .workspace
            }
            return currentTaskOutputFolderNames.contains(taskFolderName) ? .currentTaskOutput : .otherTaskOutput
        }
    }

    private static func legacyTaskFolderName(in relativePath: String) -> String? {
        let components = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2,
              components[0] == "tasks" else {
            return nil
        }
        return components[1]
    }
}
