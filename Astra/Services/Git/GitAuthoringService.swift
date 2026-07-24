import Foundation
import ASTRACore

// MARK: - Suggestion models

struct CommitSuggestion: Codable, Equatable, Sendable {
    var subject: String
    var body: String
    var type: String

    func normalized() -> CommitSuggestion {
        CommitSuggestion(
            subject: Self.limited(subject, maxLen: 72),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var formatted: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty { return subject }
        return "\(subject)\n\n\(trimmedBody)"
    }

    private static func limited(_ value: String, maxLen: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLen else { return trimmed }
        return String(trimmed.prefix(maxLen))
    }
}

struct PRSuggestion: Codable, Equatable, Sendable {
    var title: String
    var body: String

    func normalized() -> PRSuggestion {
        PRSuggestion(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Errors

enum GitAuthoringError: LocalizedError, Equatable {
    case helperModelUnavailable
    case providerFailed(String)
    case invalidOutput(String)
    case emptyDiff

    var errorDescription: String? {
        switch self {
        case .helperModelUnavailable:
            return "No helper model is configured. Configure Claude or Copilot in Settings to enable suggestions."
        case .providerFailed(let message):
            return "Helper model failed: \(message) (diagnostics logged)."
        case .invalidOutput(let message):
            return "Helper model returned data ASTRA could not read: \(message)"
        case .emptyDiff:
            return "There is nothing to summarize yet."
        }
    }
}

// MARK: - Service

protocol GitCommitMessageGenerating {
    func suggestCommitMessage(
        repoPath: String,
        diff: String,
        recentSubjects: [String]
    ) async throws -> CommitSuggestion
}

protocol GitPullRequestGenerating {
    func suggestPullRequest(
        repoPath: String,
        branch: String,
        base: String,
        log: String,
        diffStat: String
    ) async throws -> PRSuggestion
}

protocol GitAuthoringUtilityRunning: Sendable {
    func runPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult
}

struct LiveGitAuthoringUtilityRunner: GitAuthoringUtilityRunning {
    func runPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: configuration,
            toolMode: toolMode
        )
    }
}

struct AgentGitAuthoringService: GitCommitMessageGenerating, GitPullRequestGenerating {
    var utilityRuntime: AgentUtilityRuntimeConfiguration
    // Authoring runs a CLI agent (cold start + model inference). The provider
    // CLIs budget themselves up to 120s, so ASTRA's wrapper must give each call
    // a realistic, operation-appropriate slice of that ceiling rather than a
    // single short deadline. A commit subject is one line; a pull-request body
    // is multi-section markdown over a wider context, so it needs more room.
    var timeoutSeconds: Int = 45
    var pullRequestTimeoutSeconds: Int = 90
    var utilityRunner: any GitAuthoringUtilityRunning = LiveGitAuthoringUtilityRunner()

    init(
        utilityRuntime: AgentUtilityRuntimeConfiguration,
        timeoutSeconds: Int = 45,
        pullRequestTimeoutSeconds: Int = 90,
        utilityRunner: any GitAuthoringUtilityRunning = LiveGitAuthoringUtilityRunner()
    ) {
        self.utilityRuntime = utilityRuntime
        self.timeoutSeconds = timeoutSeconds
        self.pullRequestTimeoutSeconds = pullRequestTimeoutSeconds
        self.utilityRunner = utilityRunner
    }

    private enum Operation: String {
        case commitMessage = "commit_message"
        case pullRequest = "pull_request"
    }

    func suggestCommitMessage(
        repoPath: String,
        diff: String,
        recentSubjects: [String]
    ) async throws -> CommitSuggestion {
        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiff.isEmpty else {
            throw GitAuthoringError.emptyDiff
        }

        let prompt = GitAuthoringPromptBuilder.commitPrompt(
            diff: trimmedDiff,
            recentSubjects: recentSubjects
        )
        let result = await runWithTimeout(
            operation: .commitMessage,
            prompt: prompt,
            repoPath: repoPath,
            timeoutSeconds: timeoutSeconds
        )

        guard result.exitCode == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            logProviderFailure(
                operation: .commitMessage,
                result: result,
                reason: message.isEmpty ? "exit_code_\(result.exitCode)" : message
            )
            throw GitAuthoringError.providerFailed(
                message.isEmpty ? "Exit code \(result.exitCode)" : String(message.prefix(400))
            )
        }

        guard let suggestion = GitAuthoringParser.parseCommit(from: result.output) else {
            logProviderFailure(
                operation: .commitMessage,
                result: result,
                reason: "invalid_output"
            )
            throw GitAuthoringError.invalidOutput(String(result.output.prefix(400)))
        }

        let normalized = suggestion.normalized()
        guard !normalized.subject.isEmpty else {
            throw GitAuthoringError.invalidOutput("Empty subject in suggested commit message.")
        }
        return normalized
    }

    func suggestPullRequest(
        repoPath: String,
        branch: String,
        base: String,
        log: String,
        diffStat: String
    ) async throws -> PRSuggestion {
        let prompt = GitAuthoringPromptBuilder.prPrompt(
            branch: branch,
            base: base,
            log: log,
            diffStat: diffStat
        )
        let result = await runWithTimeout(
            operation: .pullRequest,
            prompt: prompt,
            repoPath: repoPath,
            timeoutSeconds: pullRequestTimeoutSeconds
        )

        guard result.exitCode == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            logProviderFailure(
                operation: .pullRequest,
                result: result,
                reason: message.isEmpty ? "exit_code_\(result.exitCode)" : message
            )
            throw GitAuthoringError.providerFailed(
                message.isEmpty ? "Exit code \(result.exitCode)" : String(message.prefix(400))
            )
        }

        guard let suggestion = GitAuthoringParser.parsePR(from: result.output) else {
            logProviderFailure(
                operation: .pullRequest,
                result: result,
                reason: "invalid_output"
            )
            throw GitAuthoringError.invalidOutput(String(result.output.prefix(400)))
        }

        let normalized = suggestion.normalized()
        guard !normalized.title.isEmpty else {
            throw GitAuthoringError.invalidOutput("Empty PR title in suggestion.")
        }
        return normalized
    }

    private func runWithTimeout(
        operation: Operation,
        prompt: String,
        repoPath: String,
        timeoutSeconds: Int
    ) async -> AgentUtilityRunResult {
        let effectiveTimeout = max(1, timeoutSeconds)
        var runtimeConfiguration = utilityRuntime
        // AgentRuntimeProcessRunner is the single watchdog owner: it owns the
        // process, the absolute Dispatch deadline, process-tree termination,
        // and final pipe draining. Git authoring supplies the operation budget
        // instead of racing that runner with a second unstructured timeout.
        runtimeConfiguration.timeoutSeconds = TimeInterval(effectiveTimeout)
        let startedAt = ContinuousClock.now
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        AppLogger.audit(.gitAuthoringStarted, category: "Git", fields: [
            "operation": operation.rawValue,
            "runtime": runtimeConfiguration.runtime.rawValue,
            "model": runtimeConfiguration.model,
            "repo": repoName,
            "timeout_seconds": "\(effectiveTimeout)",
            "prompt_bytes": "\(prompt.utf8.count)",
            "prompt_lines": "\(prompt.split(separator: "\n", omittingEmptySubsequences: false).count)"
        ], level: .info)
        let completed = await utilityRunner.runPrompt(
            prompt,
            workspacePath: repoPath,
            configuration: runtimeConfiguration,
            toolMode: .readOnly
        )
        let completedAt = ContinuousClock.now
        // The process runner is the sole timeout authority. It starts its
        // watchdog only after the child has launched and returns only after
        // process-tree teardown and pipe draining. Reclassifying success from
        // callback-delivery wall time here would charge unrelated scheduler
        // starvation to the child and create a second, contradictory owner.
        let timedOut = Self.isTimeoutResult(completed)
        let result = timedOut
            ? AgentUtilityRunResult(
                exitCode: 124,
                output: "",
                error: "Timed out after \(effectiveTimeout)s"
            )
            : completed
        if timedOut {
            AppLogger.warning("Git authoring timed out after \(effectiveTimeout)s", category: "Git")
        }
        logProviderCompletion(
            operation: operation,
            result: result,
            elapsed: Self.elapsedSeconds(from: startedAt, to: completedAt),
            repoName: repoName,
            timeoutSeconds: effectiveTimeout,
            timedOut: timedOut
        )
        return result
    }

    private static func isTimeoutResult(_ result: AgentUtilityRunResult) -> Bool {
        guard result.exitCode != 0 else { return false }
        return result.error.localizedCaseInsensitiveContains("timed out")
            || result.error.localizedCaseInsensitiveContains("timeout")
    }

    private static func elapsedSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> TimeInterval {
        let components = start.duration(to: end).components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func logProviderCompletion(
        operation: Operation,
        result: AgentUtilityRunResult,
        elapsed: TimeInterval,
        repoName: String,
        timeoutSeconds: Int,
        timedOut: Bool = false
    ) {
        let event: AuditEvent = result.exitCode == 0 && !timedOut
            ? .gitAuthoringCompleted
            : .gitAuthoringFailed
        AppLogger.audit(event, category: "Git", fields: [
            "operation": operation.rawValue,
            "runtime": utilityRuntime.runtime.rawValue,
            "model": utilityRuntime.model,
            "repo": repoName,
            "exit_code": "\(result.exitCode)",
            "elapsed_ms": "\(Int(elapsed * 1000))",
            "timeout_seconds": "\(timeoutSeconds)",
            "timed_out": timedOut ? "true" : "false",
            "stdout_bytes": "\(result.output.utf8.count)",
            "stderr_bytes": "\(result.error.utf8.count)"
        ], level: result.exitCode == 0 && !timedOut ? .info : .warning)
    }

    private func logProviderFailure(
        operation: Operation,
        result: AgentUtilityRunResult,
        reason: String
    ) {
        AppLogger.audit(.gitAuthoringFailed, category: "Git", fields: [
            "operation": operation.rawValue,
            "runtime": utilityRuntime.runtime.rawValue,
            "model": utilityRuntime.model,
            "exit_code": "\(result.exitCode)",
            "reason": reason,
            "stdout_sample": String(result.output.prefix(300)),
            "stderr_sample": String(result.error.prefix(300))
        ], level: .error, fieldMaxLength: 300)
    }
}

// MARK: - Prompt builders

enum GitAuthoringPromptBuilder {
    static func commitPrompt(diff: String, recentSubjects: [String]) -> String {
        let recent = recentSubjects.isEmpty
            ? "(no recent commits)"
            : recentSubjects.map { "- \($0)" }.joined(separator: "\n")

        return """
        You are ASTRA's git commit author. Using ONLY the staged diff included below, propose a single, concise commit message. Everything you need is already in this message.

        Return exactly one line using this prefix and no markdown fences:
        ASTRA_COMMIT_SUGGESTION {"subject":"...","body":"...","type":"feat|fix|chore|refactor|docs|test|perf|build|ci|style"}

        Rules:
        - Use ONLY the diff text in this message. Do NOT use any tools, read files, run commands, or explore the repository. Answer immediately from the text below.
        - subject is at most 72 characters, imperative mood, no trailing period.
        - body is optional. When present, wrap manually at ~72 chars and explain the WHY succinctly.
        - type is the single best conventional-commit type from the list above.
        - Match the tone of the recent commits below; prefer the same prefix style if used.
        - Do not invent changes that are not in the diff.

        Recent commit subjects (for tone):
        \(recent)

        Staged diff:
        \(diff)
        """
    }

    static func prPrompt(branch: String, base: String, log: String, diffStat: String) -> String {
        return """
        You are ASTRA's pull-request author. Using ONLY the commit log and diffstat included below, draft a clean PR title and body for the changes between \(base) and \(branch).

        Return exactly one line using this prefix and no markdown fences:
        ASTRA_PR_SUGGESTION {"title":"...","body":"...markdown..."}

        Rules:
        - Use ONLY the information in this message. Do NOT use any tools, read files, run commands, or explore the repository. Answer immediately from the text below.
        - title is concise, imperative, at most 80 characters, no trailing period.
        - body is GitHub-flavored markdown. Use these sections in order, omitting any that are empty:
          ## Summary
          ## Changes
          ## Notes
        - Use bullet points under ## Changes derived from the commit log.
        - Do not invent changes not represented in the log or diffstat.
        - Do not include a "Test plan" section unless tests are visible in the diffstat.

        Branch: \(branch)
        Base: \(base)

        Commit log (\(base)..\(branch)):
        \(log.isEmpty ? "(empty)" : log)

        Diffstat (\(base)...\(branch)):
        \(diffStat.isEmpty ? "(empty)" : diffStat)
        """
    }
}

// MARK: - Parser

enum GitAuthoringParser {
    static func parseCommit(from output: String) -> CommitSuggestion? {
        if let payload = prefixedPayload(in: output, prefix: "ASTRA_COMMIT_SUGGESTION"),
           let suggestion = decode(payload, as: CommitSuggestion.self) {
            return suggestion
        }
        if let json = firstJSONObject(in: output),
           let suggestion = decode(json, as: CommitSuggestion.self) {
            return suggestion
        }
        return nil
    }

    static func parsePR(from output: String) -> PRSuggestion? {
        if let payload = prefixedPayload(in: output, prefix: "ASTRA_PR_SUGGESTION"),
           let suggestion = decode(payload, as: PRSuggestion.self) {
            return suggestion
        }
        if let json = firstJSONObject(in: output),
           let suggestion = decode(json, as: PRSuggestion.self) {
            return suggestion
        }
        return nil
    }

    private static func prefixedPayload(in output: String, prefix: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed
                .replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func firstJSONObject(in output: String) -> String? {
        let characters = Array(output)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in start..<characters.endIndex {
            let character = characters[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }
            if character == "\"" {
                isInString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }
        return nil
    }

    private static func decode<T: Decodable>(_ payload: String, as: T.Type) -> T? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Helper-model availability

enum GitAuthoringAvailability {
    /// Returns true when at least one helper model is cached (i.e. a runtime has been configured).
    static func isAvailable(
        runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> Bool {
        RuntimeModelAvailability.hasCachedModels(for: runtime, cache: cache)
    }
}
