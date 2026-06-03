import Foundation
import SwiftData

struct TaskInferredValidationSuggestion: Equatable {
    var plan: TaskPlanPayload
    var artifactCount: Int
}

enum TaskInferredValidationService {
    @MainActor
    static func suggestion(for task: AgentTask) -> TaskInferredValidationSuggestion? {
        let files = TaskOutputDiscovery.files(for: task)
        guard !files.isEmpty else { return nil }

        let primaryFile = preferredFile(from: files)
        let expectedText = inferredExpectedText(for: task)
        var assertions: [TaskValidationAssertion] = []

        for (index, file) in files.prefix(8).enumerated() {
            assertions.append(TaskValidationAssertion(
                id: uniqueAssertionID(prefix: "artifact", path: file.relativePath, index: index),
                description: "\(file.relativePath) exists",
                method: .artifact,
                required: true,
                path: file.relativePath
            ))
        }

        if let expectedText,
           isTextInspectable(primaryFile) {
            assertions.append(TaskValidationAssertion(
                id: uniqueAssertionID(prefix: "text", path: primaryFile.relativePath, index: assertions.count),
                description: "\(primaryFile.relativePath) contains expected task text",
                method: .textContains,
                required: false,
                path: primaryFile.relativePath,
                evidenceQuery: expectedText
            ))
        }

        if let expectedText,
           primaryFile.type == "html" {
            assertions.append(TaskValidationAssertion(
                id: uniqueAssertionID(prefix: "browser", path: primaryFile.relativePath, index: assertions.count),
                description: "\(primaryFile.relativePath) exposes expected visible text",
                method: .browserBehavior,
                required: false,
                path: primaryFile.relativePath,
                evidenceQuery: expectedText
            ))
        }

        guard !assertions.isEmpty else { return nil }
        let plan = TaskPlanPayload(
            title: "Verify result",
            goal: firstNonEmpty(task.goal, task.title, "Verify task result"),
            steps: [
                TaskPlanPayloadStep(
                    id: "verify-result",
                    title: "Verify result",
                    detail: "Run inferred deterministic proof rules against current task output.",
                    risk: .low,
                    likelyTools: ["Read"],
                    doneSignal: "Required inferred proof rules pass."
                )
            ],
            validationContract: TaskValidationContract(assertions: assertions)
        )
        return TaskInferredValidationSuggestion(plan: plan, artifactCount: files.count)
    }

    @MainActor
    static func hasSuggestion(for task: AgentTask) -> Bool {
        suggestion(for: task) != nil
    }

    @MainActor
    @discardableResult
    static func run(task: AgentTask, modelContext: ModelContext) async -> TaskValidationContractEvaluation {
        guard let suggestion = suggestion(for: task) else {
            return .notRequired
        }
        recordDefinitionSnapshot(plan: suggestion.plan, task: task, modelContext: modelContext)
        let result = await ValidationService.runContract(
            task: task,
            plan: suggestion.plan,
            run: latestRun(for: task),
            modelContext: modelContext
        )
        task.updatedAt = Date()
        TaskContextStateManager.refresh(task: task)
        return result
    }

    private static func preferredFile(from files: [TaskOutputDiscoveredFile]) -> TaskOutputDiscoveredFile {
        files.first { $0.relativePath == "index.html" } ??
            files.first { $0.type == "html" } ??
            files.first { isTextInspectable($0) } ??
            files[0]
    }

    private static func isTextInspectable(_ file: TaskOutputDiscoveredFile) -> Bool {
        let textTypes: Set<String> = [
            "html", "markdown", "md", "txt", "text", "json", "js", "css",
            "csv", "xml", "sql", "py", "swift", "ts", "tsx", "jsx", "yaml", "yml"
        ]
        return textTypes.contains(file.type.lowercased())
    }

    private static func inferredExpectedText(for task: AgentTask) -> String? {
        let sources = [task.title, task.goal]
        for source in sources {
            if let token = significantTokens(in: source).first {
                return token
            }
        }
        return nil
    }

    private static func significantTokens(in value: String) -> [String] {
        let stopWords: Set<String> = [
            "about", "add", "agent", "artifact", "ball", "build", "create", "deliver",
            "demo", "file", "html", "javascript", "page", "puzzle", "responsive",
            "result", "site", "solver", "static", "task", "test", "that", "this",
            "using", "with", "work", "write"
        ]
        return value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                let normalized = token.lowercased()
                return normalized.count >= 4 && !stopWords.contains(normalized)
            }
    }

    private static func uniqueAssertionID(prefix: String, path: String, index: Int) -> String {
        let pathID = path
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let compact = String(pathID)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let suffix = compact.isEmpty ? "artifact" : String(compact.prefix(48))
        return "\(prefix)-\(index + 1)-\(suffix)"
    }

    @MainActor
    private static func latestRun(for task: AgentTask) -> TaskRun? {
        task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    @MainActor
    private static func recordDefinitionSnapshot(
        plan: TaskPlanPayload,
        task: AgentTask,
        modelContext: ModelContext
    ) {
        guard let contract = plan.validationContract, !contract.assertions.isEmpty else { return }

        let requiredTotal = contract.assertions.filter(\.required).count
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractCreated,
            payload: encode(TaskValidationContractEventPayload(
                version: 1,
                planID: plan.planID,
                status: "defined",
                requiredPassed: 0,
                requiredTotal: requiredTotal,
                failedRequiredAssertionIDs: [],
                summary: "Inferred validation contract from current task artifacts."
            ))
        ))

        for assertion in contract.assertions {
            modelContext.insert(TaskEvent(
                task: task,
                type: TaskValidationEventTypes.assertionDefined,
                payload: encode(TaskValidationAssertionEventPayload(
                    version: 1,
                    planID: plan.planID,
                    assertionID: assertion.id,
                    scope: assertion.scope,
                    stepID: assertion.stepID,
                    method: assertion.method,
                    required: assertion.required,
                    status: "defined",
                    summary: assertion.description,
                    command: assertion.command,
                    exitCode: nil,
                    path: assertion.path,
                    evidence: nil,
                    reason: nil
                ))
            ))
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
