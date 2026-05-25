import Foundation
import SwiftData

enum AgentTaskForkService {
    static func fork(from source: AgentTask, upToRun targetRun: TaskRun, in context: ModelContext) -> AgentTask {
        let forked = AgentTask(
            title: "Fork of \(source.title)",
            goal: source.goal,
            workspace: source.workspace,
            tokenBudget: source.tokenBudget,
            model: source.model,
            runtime: source.resolvedRuntimeID,
            isolationStrategy: source.isolationStrategy,
            validationStrategy: source.validationStrategy
        )
        forked.inputs = source.inputs
        forked.constraints = source.constraints
        forked.acceptanceCriteria = source.acceptanceCriteria
        forked.forkedFromID = source.id
        forked.skills = source.skills
        forked.skillSnapshotsJSON = source.skillSnapshotsJSON
        forked.runtimeID = source.runtimeID

        let sortedRuns = source.runs.sorted { $0.startedAt < $1.startedAt }
        guard let cutoffIndex = sortedRuns.firstIndex(where: { $0.id == targetRun.id }) else {
            context.insert(forked)
            return forked
        }

        forked.forkedAtRunIndex = cutoffIndex
        forked.status = .completed

        let runsToFork = sortedRuns.prefix(through: cutoffIndex)
        var totalTokens = 0
        var totalCost = 0.0

        for sourceRun in runsToFork {
            let newRun = TaskRun(task: forked)
            newRun.status = sourceRun.status
            newRun.startedAt = sourceRun.startedAt
            newRun.completedAt = sourceRun.completedAt
            newRun.tokensUsed = sourceRun.tokensUsed
            newRun.inputTokens = sourceRun.inputTokens
            newRun.outputTokens = sourceRun.outputTokens
            newRun.output = sourceRun.output
            newRun.costUSD = sourceRun.costUSD
            newRun.fileChangesJSON = sourceRun.fileChangesJSON
            newRun.stopReason = sourceRun.stopReason
            newRun.exitCode = sourceRun.exitCode
            context.insert(newRun)
            totalTokens += sourceRun.tokensUsed
            totalCost += sourceRun.costUSD
        }

        forked.tokensUsed = totalTokens
        forked.costUSD = totalCost

        let cutoffDate = targetRun.completedAt ?? targetRun.startedAt
        let eventsToFork = source.events
            .filter { $0.timestamp <= cutoffDate }
            .sorted { $0.timestamp < $1.timestamp }

        for sourceEvent in eventsToFork {
            let newEvent = TaskEvent(
                task: forked,
                type: sourceEvent.type,
                payload: sourceEvent.payload
            )
            newEvent.timestamp = sourceEvent.timestamp
            newEvent.agentName = sourceEvent.agentName
            newEvent.agentId = sourceEvent.agentId
            newEvent.teamName = sourceEvent.teamName
            context.insert(newEvent)
        }

        context.insert(forked)
        return forked
    }
}
