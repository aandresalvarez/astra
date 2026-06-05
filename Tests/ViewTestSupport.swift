import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - Helper

func makeTask(
    title: String = "Test Task",
    goal: String = "Do something",
    status: TaskStatus = .queued,
    workspace: Workspace? = nil,
    tokensUsed: Int = 0,
    tokenBudget: Int = TaskExecutionDefaults.tokenBudget,
    costUSD: Double = 0,
    model: String = TaskExecutionDefaults.model
) -> AgentTask {
    let task = AgentTask(title: title, goal: goal, workspace: workspace, tokenBudget: tokenBudget, model: model)
    task.status = status
    task.tokensUsed = tokensUsed
    task.costUSD = costUSD
    return task
}

func makeWorkspace(name: String = "Workspace") -> Workspace {
    Workspace(name: name, primaryPath: "/tmp/\(name)")
}

func makeEvent(
    task: AgentTask,
    type: String,
    payload: String,
    timestamp: Date,
    run: TaskRun? = nil
) -> TaskEvent {
    let event = TaskEvent(task: task, type: type, payload: payload, run: run)
    event.timestamp = timestamp
    return event
}

actor QueryStubRunner: StandardInputBinaryRunner {
    var results: [RunResult]
    private(set) var lastPath = ""
    private(set) var lastArgs: [String] = []
    private(set) var lastStandardInput = ""
    private(set) var allPaths: [String] = []
    private(set) var allArgs: [[String]] = []
    private(set) var allStandardInputs: [String] = []

    init(result: RunResult) {
        self.results = [result]
    }

    init(results: [RunResult]) {
        self.results = results
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        lastPath = path
        lastArgs = args
        lastStandardInput = ""
        allPaths.append(path)
        allArgs.append(args)
        allStandardInputs.append("")
        return nextResult()
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        standardInput: String
    ) async -> RunResult {
        lastPath = path
        lastArgs = args
        lastStandardInput = standardInput
        allPaths.append(path)
        allArgs.append(args)
        allStandardInputs.append(standardInput)
        return nextResult()
    }

    private func nextResult() -> RunResult {
        guard !results.isEmpty else {
            return RunResult(outcome: .exited(code: 0), stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}

final class QueryBriefRecordingGenerator: QueryBriefGenerating {
    var result: Result<QueryBrief, Error>
    private(set) var lastRequest: QueryBriefRequest?

    init(result: Result<QueryBrief, Error>) {
        self.result = result
    }

    func generateBrief(_ request: QueryBriefRequest) async throws -> QueryBrief {
        lastRequest = request
        return try result.get()
    }
}

final class QueryRepairRecordingGenerator: QueryRepairGenerating {
    var results: [Result<QueryRepairSuggestion, Error>]
    private(set) var requests: [QueryRepairRequest] = []

    init(results: [Result<QueryRepairSuggestion, Error>]) {
        self.results = results
    }

    func repair(_ request: QueryRepairRequest) async throws -> QueryRepairSuggestion {
        requests.append(request)
        guard !results.isEmpty else {
            return QueryRepairSuggestion(sql: request.failedSQL, summary: "No repair", assumptions: [])
        }
        return try results.removeFirst().get()
    }
}

final class QueryResultExplanationRecordingGenerator: QueryResultExplanationGenerating {
    var result: Result<QueryResultExplanation, Error>
    private(set) var lastRequest: QueryResultExplanationRequest?

    init(result: Result<QueryResultExplanation, Error>) {
        self.result = result
    }

    func explainResult(_ request: QueryResultExplanationRequest) async throws -> QueryResultExplanation {
        lastRequest = request
        return try result.get()
    }
}

