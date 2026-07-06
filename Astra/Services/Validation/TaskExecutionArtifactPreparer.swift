import Foundation
import SwiftData
import ASTRAModels

struct TaskExecutionArtifactExpectation: Sendable, Equatable, Hashable {
    var kind: TaskPlanArtifactKind
    var scope: TaskPlanArtifactScope
    var relativePath: String
    var required: Bool
    var prepareParentDirectories: Bool
    var source: String
    var authoritative: Bool
}

struct TaskExecutionArtifactPreparationResult: Sendable, Equatable {
    var preparedDirectories: [String]
    var skippedPaths: [String]
    var rejectedPaths: [String]
    var errors: [String]

    var succeeded: Bool {
        errors.isEmpty
    }
}

@MainActor
enum TaskExecutionArtifactPreparer {
    static func prepareTaskOutputArtifacts(
        task: AgentTask,
        plan: TaskPlanPayload,
        step approvedStep: TaskPlanPayloadStep?,
        modelContext: ModelContext,
        phase: String
    ) -> Bool {
        do {
            _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        } catch {
            recordPreparationFailure(
                task: task,
                modelContext: modelContext,
                phase: phase,
                reason: "task_folder_create_failed",
                message: "ASTRA could not create this task's output folder before preparing artifacts: \(error.localizedDescription)"
            )
            return false
        }

        let result = prepareTaskOutputArtifacts(task: task, plan: plan, step: approvedStep)
        recordPreparationResult(result, task: task, modelContext: modelContext, phase: phase)
        if result.succeeded {
            return true
        }
        recordPreparationFailure(
            task: task,
            modelContext: modelContext,
            phase: phase,
            reason: "artifact_preflight_failed",
            message: "ASTRA could not prepare expected task artifact directories before launching the provider."
        )
        return false
    }

    static func prepareTaskOutputArtifacts(
        task: AgentTask,
        plan: TaskPlanPayload,
        step approvedStep: TaskPlanPayloadStep?,
        fileManager: FileManager = .default
    ) -> TaskExecutionArtifactPreparationResult {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TaskExecutionArtifactPreparationResult(
                preparedDirectories: [],
                skippedPaths: [],
                rejectedPaths: [],
                errors: ["missing_task_folder"]
            )
        }

        let root = URL(fileURLWithPath: taskFolder, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectations = artifactExpectations(for: plan, step: approvedStep)
        var prepared = Set<String>()
        var skipped: [String] = []
        var rejected: [String] = []
        var errors: [String] = []

        for expectation in expectations {
            guard expectation.scope == .taskOutput else {
                skipped.append(expectation.relativePath)
                continue
            }
            guard let relative = safeTaskOutputRelativePath(expectation.relativePath) else {
                rejected.append(expectation.relativePath)
                continue
            }
            guard let directoryRelative = preparationDirectoryRelativePath(for: expectation, safeRelativePath: relative) else {
                skipped.append(relative)
                continue
            }
            guard let directoryURL = scopedURL(root: root, relativePath: directoryRelative) else {
                rejected.append(relative)
                continue
            }
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                prepared.insert(directoryURL.path)
            } catch {
                errors.append("\(directoryRelative): \(error.localizedDescription)")
            }
        }

        return TaskExecutionArtifactPreparationResult(
            preparedDirectories: prepared.sorted(),
            skippedPaths: Array(NSOrderedSet(array: skipped)) as? [String] ?? skipped,
            rejectedPaths: Array(NSOrderedSet(array: rejected)) as? [String] ?? rejected,
            errors: errors
        )
    }

    static func artifactExpectations(
        for plan: TaskPlanPayload,
        step approvedStep: TaskPlanPayloadStep?
    ) -> [TaskExecutionArtifactExpectation] {
        let scopedSteps = approvedStep.map { [$0] } ?? plan.steps
        var expectations: [TaskExecutionArtifactExpectation] = []

        for step in scopedSteps {
            expectations += step.outputs.compactMap { output in
                guard let path = output.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else {
                    return nil
                }
                return TaskExecutionArtifactExpectation(
                    kind: output.kind,
                    scope: output.scope,
                    relativePath: path,
                    required: output.required,
                    prepareParentDirectories: output.prepareParentDirectories,
                    source: output.source ?? "step:\(step.id)",
                    authoritative: true
                )
            }

            expectations += inferredLegacyExpectations(from: step)
        }

        expectations += validationExpectations(from: plan.validationContract, approvedStep: approvedStep)
        return unique(expectations)
    }

    private static func validationExpectations(
        from contract: TaskValidationContract?,
        approvedStep: TaskPlanPayloadStep?
    ) -> [TaskExecutionArtifactExpectation] {
        guard let contract else { return [] }
        return contract.assertions.compactMap { assertion in
            if assertion.scope == .step,
               let approvedStep,
               assertion.stepID != approvedStep.id {
                return nil
            }
            guard [.artifact, .browserBehavior, .textContains].contains(assertion.method),
                  let path = assertion.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            let kind: TaskPlanArtifactKind = artifactTypeLooksDirectory(assertion.expectedArtifactType) ? .directory : .file
            return TaskExecutionArtifactExpectation(
                kind: kind,
                scope: .taskOutput,
                relativePath: path,
                required: assertion.required,
                prepareParentDirectories: true,
                source: "validation:\(assertion.id)",
                authoritative: true
            )
        }
    }

    private static func inferredLegacyExpectations(from step: TaskPlanPayloadStep) -> [TaskExecutionArtifactExpectation] {
        let text = [step.title, step.detail, step.doneSignal]
            .joined(separator: " ")
        return inferredRelativeArtifactPaths(from: text).map { inferred in
            TaskExecutionArtifactExpectation(
                kind: inferred.kind,
                scope: .taskOutput,
                relativePath: inferred.path,
                required: true,
                prepareParentDirectories: true,
                source: "legacy_step:\(step.id)",
                authoritative: false
            )
        }
    }

    private static func preparationDirectoryRelativePath(
        for expectation: TaskExecutionArtifactExpectation,
        safeRelativePath: String
    ) -> String? {
        switch expectation.kind {
        case .directory:
            return safeRelativePath
        case .file, .evidence:
            guard expectation.prepareParentDirectories else { return nil }
            let parent = (safeRelativePath as NSString).deletingLastPathComponent
            return parent.isEmpty || parent == "." ? nil : parent
        case .url, .text:
            return nil
        }
    }

    private static func inferredRelativeArtifactPaths(from text: String) -> [(path: String, kind: TaskPlanArtifactKind)] {
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\"'`<>()[]{}")
        )
        return text
            .components(separatedBy: separators)
            .compactMap { rawToken -> (path: String, kind: TaskPlanArtifactKind)? in
                let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                guard !token.isEmpty,
                      token.contains("/") || knownFileExtension(in: token) != nil else {
                    return nil
                }
                if token.hasSuffix("/") {
                    return (token, .directory)
                }
                if knownFileExtension(in: token) != nil {
                    return (token, .file)
                }
                return nil
            }
    }

    private static func knownFileExtension(in path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        let allowed: Set<String> = [
            "css", "csv", "docx", "gif", "go", "html", "jpeg", "jpg", "js", "json",
            "jsx", "kt", "md", "mp4", "parquet", "pdf", "png", "pptx", "py", "rb",
            "rs", "sh", "sql", "svg", "swift", "ts", "tsx", "txt", "webp", "xls",
            "xlsx", "yaml", "yml", "zip"
        ]
        return allowed.contains(ext) ? ext : nil
    }

    private static func safeTaskOutputRelativePath(_ rawPath: String) -> String? {
        var path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.lowercased().contains("://"),
              !path.hasPrefix(".astra/") else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components.contains(where: { $0.contains("\u{0}") }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func scopedURL(root: URL, relativePath: String) -> URL? {
        let candidate = root.appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    private static func artifactTypeLooksDirectory(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["directory", "folder", "dir"].contains(normalized)
    }

    private static func unique(_ expectations: [TaskExecutionArtifactExpectation]) -> [TaskExecutionArtifactExpectation] {
        var seen = Set<String>()
        var result: [TaskExecutionArtifactExpectation] = []
        for expectation in expectations {
            let key = [
                expectation.kind.rawValue,
                expectation.scope.rawValue,
                expectation.relativePath,
                String(expectation.prepareParentDirectories)
            ].joined(separator: "\u{1F}")
            guard seen.insert(key).inserted else { continue }
            result.append(expectation)
        }
        return result
    }

    private static func recordPreparationResult(
        _ result: TaskExecutionArtifactPreparationResult,
        task: AgentTask,
        modelContext: ModelContext,
        phase: String
    ) {
        guard !result.preparedDirectories.isEmpty ||
            !result.skippedPaths.isEmpty ||
            !result.rejectedPaths.isEmpty ||
            !result.errors.isEmpty else {
            return
        }
        let payload = TaskArtifactPreflightEventPayload(
            phase: phase,
            preparedDirectories: result.preparedDirectories,
            skippedPaths: result.skippedPaths,
            rejectedPaths: result.rejectedPaths,
            errors: result.errors
        )
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.System.astraArtifactPreflight,
            payload: payload
        ))
        AppLogger.audit(.taskStarted, category: "Worker", taskID: task.id, fields: [
            "event": "artifact_preflight",
            "phase": phase,
            "prepared_directory_count": String(result.preparedDirectories.count),
            "skipped_path_count": String(result.skippedPaths.count),
            "rejected_path_count": String(result.rejectedPaths.count),
            "error_count": String(result.errors.count)
        ], level: result.succeeded ? .debug : .error)
    }

    private static func recordPreparationFailure(
        task: AgentTask,
        modelContext: ModelContext,
        phase: String,
        reason: String,
        message: String
    ) {
        let now = Date()
        TaskStateMachine.failFromValidation(task, modelContext: modelContext, at: now)
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: message))
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "reason": reason,
            "phase": phase
        ], level: .error)
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "artifact_preparation_failure"]
        )
    }

}

struct TaskArtifactPreflightEventPayload: Codable, Sendable, Equatable {
    var version: Int
    var phase: String
    var preparedDirectories: [String]
    var skippedPaths: [String]
    var rejectedPaths: [String]
    var errors: [String]

    init(
        version: Int = 1,
        phase: String,
        preparedDirectories: [String],
        skippedPaths: [String],
        rejectedPaths: [String],
        errors: [String]
    ) {
        self.version = version
        self.phase = phase
        self.preparedDirectories = preparedDirectories
        self.skippedPaths = skippedPaths
        self.rejectedPaths = rejectedPaths
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case phase
        case preparedDirectories
        case skippedPaths
        case rejectedPaths
        case errors
    }
}
