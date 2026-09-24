import Foundation
import SwiftData
import ASTRAModels

/// Reads a task's whole history into `TaskFileTurnsInput`: every run, not the
/// thread's window of recent ones, because turn numbers count the whole task.
enum TaskFileTurnsReader {
    static func input(
        taskID: UUID,
        taskFolder: String,
        workspacePath: String,
        modelContext: ModelContext
    ) throws -> TaskFileTurnsInput? {
        var taskDescriptor = FetchDescriptor<AgentTask>(predicate: #Predicate<AgentTask> { $0.id == taskID })
        taskDescriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(taskDescriptor).first else { return nil }

        let runs = try modelContext.fetch(FetchDescriptor<TaskRun>(
            predicate: #Predicate<TaskRun> { $0.task?.id == taskID }
        ))
        let userMessage = TaskEventTypes.Conversation.userMessage.rawValue
        let planUserMessage = TaskPlanConversationEventTypes.userMessage
        let messages = try modelContext.fetch(FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> {
                $0.task?.id == taskID && ($0.type == userMessage || $0.type == planUserMessage)
            }
        ))
        var artifactDescriptor = FetchDescriptor<Artifact>(
            predicate: #Predicate<Artifact> { $0.task?.id == taskID }
        )
        // A tool write stores the file's whole content on its row; only the
        // path and time are needed, and one task has over 13,000 rows.
        artifactDescriptor.propertiesToFetch = [\.path, \.createdAt]
        let artifacts = try modelContext.fetch(artifactDescriptor)

        return TaskFileTurnsInput(
            goal: task.goal,
            createdAt: task.createdAt,
            requests: messages.map {
                TaskFileTurnsInput.Request(text: $0.payload, requestedAt: $0.timestamp, runID: $0.run?.id)
            },
            runs: runs.map { run in
                TaskFileTurnsInput.Run(
                    id: run.id,
                    startedAt: run.startedAt,
                    completedAt: run.completedAt,
                    isRunning: run.status == .running,
                    changes: run.allFileChanges.map {
                        TaskFileTurnsInput.Change(path: $0.path, kind: $0.kind, timestamp: $0.timestamp)
                    }
                )
            },
            indexedFiles: artifacts.map { TaskFileTurnsInput.IndexedFile(path: $0.path, indexedAt: $0.createdAt) },
            taskFolder: taskFolder,
            workspacePath: workspacePath
        )
    }
}
