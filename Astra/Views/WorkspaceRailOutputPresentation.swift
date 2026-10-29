import Foundation
import ASTRACore
import ASTRAModels

/// Outputs require evidence of production. Inputs remain available in Files.
enum WorkspaceRailOutputPresentation {
    private typealias Rail = WorkspaceRailSectionPresentation

    static func facts(from files: TaskHeaderFilesReader.Facts) -> WorkspaceRailSectionPresentation.OutputFacts {
        let produced = files.items.filter { item in
            guard !item.isDirectory else { return false }
            if let change = item.change {
                return change.kind != .removed
            } else {
                return item.source == "output"
                    && !files.userProvidedPaths.contains(TaskHeaderFilesReader.Facts.pathIdentity(item.path))
            }
        }
        // Compute path identity once per file, never
        // inside the O(n log n) sort comparator.
        let dated = produced.map { item in
            (item: item, date: files.activityDates[TaskHeaderFilesReader.Facts.pathIdentity(item.path)]
                ?? item.change?.timestamp ?? .distantPast)
        }
        return Rail.OutputFacts(files: dated.sorted {
            $0.date == $1.date ? $0.item.path < $1.item.path : $0.date > $1.date
        }.map { entry in
            Rail.OutputFile(path: entry.item.path, destination: destination(entry.item.destination))
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
