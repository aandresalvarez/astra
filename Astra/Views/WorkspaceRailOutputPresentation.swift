import Foundation
import ASTRACore
import ASTRAModels

/// Outputs require evidence of production. Inputs remain available in Files.
enum WorkspaceRailOutputPresentation {
    private typealias Rail = WorkspaceRailSectionPresentation

    static func facts(from files: TaskHeaderFilesReader.Facts) -> WorkspaceRailSectionPresentation.OutputFacts {
        Rail.OutputFacts(files: files.items.compactMap { item in
            guard !item.isDirectory else { return nil }
            if let change = item.change {
                guard change.kind != .removed else { return nil }
            } else {
                guard item.source == "output",
                      !files.userProvidedPaths.contains(TaskHeaderFilesReader.Facts.pathIdentity(item.path)) else { return nil }
            }
            return Rail.OutputFile(path: item.path, destination: destination(item.destination))
        })
    }

    private static func destination(_ destination: TaskGeneratedFileShelfDestination?) -> Rail.OutputDestination {
        switch destination {
        case .browser?: .browser
        case .query?: .query
        case .files?: .files
        case nil: .none
        }
    }

    /// The read and the cache use the same durable owner, including imported
    /// copies with identical portable UUIDs and timestamps.
    struct ReadKey: Equatable {
        let scope: TaskAttachmentHistoryScope?
        let status: String?
        let updatedAt: Date?
        let refreshTick: Int

        init(task: AgentTask?, refreshTick: Int) {
            scope = task.map(TaskAttachmentHistoryScope.init(task:))
            status = task?.status.rawValue
            updatedAt = task?.updatedAt
            self.refreshTick = refreshTick
        }
    }
}
