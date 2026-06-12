import Foundation
import ASTRACore

enum AgentRuntimeFailureCategory: String, Sendable {
    case authenticationFailed = "authentication_failed"
    case modelUnavailable = "model_unavailable"
    case quotaExceeded = "quota_exceeded"
    case rateLimited = "rate_limited"
    case providerConfigurationInvalid = "provider_configuration_invalid"
    case permissionDenied = "permission_denied"
    case unsupportedOutputFormat = "unsupported_output_format"
    case networkFailed = "network_failed"
    case runtimeTimedOut = "runtime_timed_out"
    case budgetExceeded = "budget_exceeded"
    case noVisibleOutput = "no_visible_output"
    case providerProcessFailed = "provider_process_failed"
}

struct AgentRuntimeFailureDiagnostic: Equatable, Sendable {
    let runtime: AgentRuntimeID
    let model: String
    let exitCode: Int
    let providerVersion: String?
    let category: AgentRuntimeFailureCategory
    let redactedSummary: String
    let rawErrorCharacterCount: Int
    let userMessage: String
    let stderrWasWarningOnly: Bool

    var hasErrorOutput: Bool {
        rawErrorCharacterCount > 0
    }

    static func classify(
        runtime: AgentRuntimeID,
        model: String,
        exitCode: Int,
        rawError: String?,
        providerVersion: String?,
        stream: AgentRuntimeStreamTelemetrySnapshot?,
        timedOut: Bool = false,
        budgetExceeded: Bool = false,
        maxTurnsExceeded: Bool = false
    ) -> AgentRuntimeFailureDiagnostic {
        let raw = rawError ?? ""
        // Strip benign provider warnings (e.g. deprecation notices) so they never
        // become the surfaced cause or defeat the noVisibleOutput branch below.
        let meaningful = strippingBenignWarnings(raw)
        // "Warning only" requires actual (non-whitespace) stderr that reduced to
        // nothing after stripping benign warnings — a blank line or trailing
        // newline must not count as a warning.
        let hadStderr = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let warningOnly = hadStderr && meaningful.isEmpty
        let redacted = LogSanitizer.sanitize(meaningful, maxLength: 800)
        // Keyword classification (auth/model/quota/...) still inspects the FULL
        // output so a real error embedded alongside a warning is matched first.
        let haystack = "\(raw)\n\(redacted)".lowercased()
        // The noVisibleOutput empty-check uses only the warning-stripped text.
        let meaningfulHaystack = meaningful.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = classifyCategory(
            haystack: haystack,
            meaningfulHaystackEmpty: meaningfulHaystack.isEmpty,
            stream: stream,
            timedOut: timedOut,
            budgetExceeded: budgetExceeded,
            maxTurnsExceeded: maxTurnsExceeded
        )
        let summary = redacted.isEmpty ? fallbackSummary(for: category, runtime: runtime) : redacted
        let resolvedModel = RuntimeModelAvailability.normalizedModel(model, for: runtime)
        return AgentRuntimeFailureDiagnostic(
            runtime: runtime,
            model: resolvedModel,
            exitCode: exitCode,
            providerVersion: providerVersion,
            category: category,
            redactedSummary: summary,
            rawErrorCharacterCount: raw.count,
            userMessage: userMessage(for: category, runtime: runtime, model: resolvedModel),
            stderrWasWarningOnly: warningOnly
        )
    }

    func auditFields(phase: String, stream: AgentRuntimeStreamTelemetrySnapshot?) -> [String: String] {
        var fields: [String: String] = [
            "runtime": runtime.rawValue,
            "phase": phase,
            "model": model,
            "exit_code": String(exitCode),
            "provider_version": providerVersion ?? "unknown",
            "failure_category": category.rawValue,
            "has_error_output": String(hasErrorOutput),
            "raw_error_chars": String(rawErrorCharacterCount),
            "error_summary": redactedSummary,
            "stderr_was_warning_only": String(stderrWasWarningOnly)
        ]
        if let stream {
            fields["raw_lines"] = String(stream.rawLineCount)
            fields["json_lines"] = String(stream.jsonLineCount)
            fields["parsed_events"] = String(stream.parsedEventCount)
            fields["emitted_events"] = String(stream.emittedEventCount)
            fields["text_events"] = String(stream.textEventCount)
            fields["completed_events"] = String(stream.completedEventCount)
            fields["failed_events"] = String(stream.failedEventCount)
            fields["unknown_events"] = String(stream.unknownEventCount)
        }
        return fields
    }

    func userFacingPayload(prefix: String) -> String {
        var sections = ["\(prefix) \(userMessage)"]
        if !redactedSummary.isEmpty {
            sections.append("Provider error:\n\(redactedSummary)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func classifyCategory(
        haystack: String,
        meaningfulHaystackEmpty: Bool,
        stream: AgentRuntimeStreamTelemetrySnapshot?,
        timedOut: Bool,
        budgetExceeded: Bool,
        maxTurnsExceeded: Bool
    ) -> AgentRuntimeFailureCategory {
        if timedOut {
            return .runtimeTimedOut
        }
        if budgetExceeded || maxTurnsExceeded {
            return .budgetExceeded
        }
        if containsAny(haystack, [
            "rate limit", "rate_limit", "too many requests", "http 429", "status 429", " 429 "
        ]) {
            return .rateLimited
        }
        if containsAny(haystack, [
            "quota", "insufficient_quota", "premium request", "billing", "usage limit", "exceeded your usage"
        ]) {
            return .quotaExceeded
        }
        if containsAny(haystack, [
            "unauthorized", "not authenticated", "authentication", "auth failed", "login required",
            "oauth", "invalid token", "bad credentials", "http 401", "status 401"
        ]) {
            return .authenticationFailed
        }
        if containsAny(haystack, [
            "unknown model", "invalid model", "model_not_found", "model not found",
            "unsupported model", "model unavailable", "model is unavailable",
            "model is not available", "model access", "does not have access to model"
        ]) || (haystack.contains("model") && containsAny(haystack, ["not found", "not available", "unsupported", "unavailable"])) {
            return .modelUnavailable
        }
        if containsAny(haystack, [
            "api key", "apikey", "base url", "base_url", "endpoint", "deployment",
            "byok", "provider config", "provider configuration", "openai-compatible",
            "azure openai", "missing provider", "invalid provider"
        ]) {
            return .providerConfigurationInvalid
        }
        if containsAny(haystack, [
            "forbidden", "http 403", "status 403", "disabled by organization",
            "not enabled for this organization", "policy", "permission denied", "access denied",
            "permission approval", "approval prompt", "allow access to these paths",
            "outside the allowed directories"
        ]) {
            return .permissionDenied
        }
        if containsAny(haystack, [
            "output-format", "output format", "jsonl", "json line", "--stream", "streaming"
        ]) && containsAny(haystack, ["unsupported", "invalid", "unknown option", "unrecognized option"]) {
            return .unsupportedOutputFormat
        }
        if containsAny(haystack, [
            "network", "connection refused", "connection reset", "timed out",
            "timeout", "enotfound", "econnreset", "econnrefused", "tls", "ssl"
        ]) {
            return .networkFailed
        }
        if let stream,
           stream.rawLineCount > 0,
           stream.textEventCount == 0,
           stream.completedEventCount == 0,
           meaningfulHaystackEmpty {
            // A benign warning (e.g. a deprecation notice) leaves no meaningful
            // stderr, so it no longer defeats this branch. Genuine unmatched
            // errors still fall through to providerProcessFailed below.
            return .noVisibleOutput
        }
        return .providerProcessFailed
    }

    /// Drops lines that are only provider warnings (deprecation notices, etc.)
    /// so they never surface as the failure cause. Substantive lines survive.
    private static func strippingBenignWarnings(_ raw: String) -> String {
        // Deprecation notices may appear mid-line, but a generic "warning:" is only
        // treated as benign at the start of a line so a substantive error that merely
        // mentions the word is never dropped.
        let benignSubstrings = ["is deprecated", "deprecated. use"]
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let lowered = line.lowercased()
                if lowered.trimmingCharacters(in: .whitespaces).hasPrefix("warning:") { return false }
                return !benignSubstrings.contains { lowered.contains($0) }
            }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userMessage(for category: AgentRuntimeFailureCategory, runtime: AgentRuntimeID, model: String) -> String {
        switch category {
        case .authenticationFailed:
            // Same remediation source as the onboarding Runtime step, so a
            // task-time auth failure points at the exact sign-in command
            // instead of a generic re-authenticate hint.
            let provider = ClaudeProvider(
                rawValue: UserDefaults.standard.string(forKey: AppStorageKeys.claudeProvider) ?? ""
            ) ?? .anthropic
            let auth = RuntimeRemediationCatalog.remediation(for: runtime, claudeProvider: provider).auth
            var message = "\(runtime.displayName) could not authenticate. Run `\(auth.displayCommand)` in Terminal, or verify the token/provider credentials configured for this model."
            if let instruction = auth.instruction {
                message += " \(instruction)"
            }
            return message
        case .modelUnavailable:
            return "\(runtime.displayName) could not use model `\(model)`. The model may be unavailable for this account, organization policy, CLI version, quota tier, or provider configuration."
        case .quotaExceeded:
            return "\(runtime.displayName) was blocked by quota or billing limits for the selected model."
        case .rateLimited:
            return "\(runtime.displayName) was rate limited by the provider for the selected model."
        case .providerConfigurationInvalid:
            return "\(runtime.displayName) has an invalid or incomplete provider configuration for model `\(model)`."
        case .permissionDenied:
            return "\(runtime.displayName) was denied access by account, organization, runtime policy, or a CLI approval prompt ASTRA could not answer."
        case .unsupportedOutputFormat:
            return "\(runtime.displayName) did not accept ASTRA's streaming/output-format arguments. Update the CLI or use a supported runtime version."
        case .networkFailed:
            return "\(runtime.displayName) could not reach the provider or lost the network connection."
        case .runtimeTimedOut:
            return "\(runtime.displayName) stopped after no output was received before the timeout."
        case .budgetExceeded:
            return "\(runtime.displayName) stopped because the configured task budget was reached."
        case .noVisibleOutput:
            if runtime == .claudeCode {
                let hint = CommonCLIPrerequisites.claude.authHint ?? "Run `claude /login` or set `ANTHROPIC_API_KEY`."
                return "\(runtime.displayName) returned no output. It is usually not logged in (\(hint)) or a SessionStart hook failed before any response was produced."
            }
            return "\(runtime.displayName) exited before returning a visible assistant response."
        case .providerProcessFailed:
            return "\(runtime.displayName) failed before ASTRA received a visible assistant response."
        }
    }

    private static func fallbackSummary(for category: AgentRuntimeFailureCategory, runtime: AgentRuntimeID) -> String {
        switch category {
        case .noVisibleOutput:
            return "\(runtime.displayName) produced provider events but no visible assistant text."
        default:
            return ""
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
