import Foundation
import ASTRACore

/// The deliberately small, allowlisted projection that feedback capture may
/// consume from durable runtime records. It cannot carry task output, generic
/// event payloads, stderr, environment values, or file contents.
struct RuntimeFeedbackPersistedEvidence: Codable, Equatable, Sendable {
    let runtimeID: String
    let providerVersion: String?
    let executableFound: Bool?
    let readiness: String?
    let failureCategory: String?
    let sanitizedSummary: String?
    let exitCode: Int?
    let stopReason: String?
    let stream: RuntimeFeedbackPersistedStreamCounters?
    let sandboxState: String?
    let policyState: String?

    init(
        runtimeID: String,
        providerVersion: String? = nil,
        executableFound: Bool? = nil,
        readiness: String? = nil,
        failureCategory: String? = nil,
        sanitizedSummary: String? = nil,
        exitCode: Int? = nil,
        stopReason: String? = nil,
        stream: RuntimeFeedbackPersistedStreamCounters? = nil,
        sandboxState: String? = nil,
        policyState: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.providerVersion = providerVersion
        self.executableFound = executableFound
        self.readiness = readiness
        self.failureCategory = failureCategory
        self.sanitizedSummary = sanitizedSummary
        self.exitCode = exitCode
        self.stopReason = stopReason
        self.stream = stream
        self.sandboxState = sandboxState
        self.policyState = policyState
    }
}

struct RuntimeFeedbackPersistedStreamCounters: Codable, Equatable, Sendable {
    let rawLines: Int
    let parsedEvents: Int
    let textEvents: Int
    let failedEvents: Int
}

/// Persistence-only seam used by report capture. Implementations must read an
/// already-recorded projection and must not call a runtime adapter, readiness
/// service, executable probe, or provider process.
protocol RuntimeFeedbackPersistedEvidenceReading {
    func readPersistedRuntimeEvidence() throws -> RuntimeFeedbackPersistedEvidence?
}

struct RuntimeFeedbackSnapshotBuilder {
    func build(
        reading reader: any RuntimeFeedbackPersistedEvidenceReading
    ) throws -> FeedbackRuntimeSnapshotV1? {
        build(from: try reader.readPersistedRuntimeEvidence())
    }

    func build(
        from evidence: RuntimeFeedbackPersistedEvidence?
    ) -> FeedbackRuntimeSnapshotV1? {
        guard let evidence,
              let runtimeID = boundedIdentifier(evidence.runtimeID)
        else { return nil }

        let providerVersion = sanitizedText(evidence.providerVersion)
        let readiness = sanitizedText(evidence.readiness)
        let stopReason = sanitizedText(evidence.stopReason)
        let failureCategory = mappedFailureCategory(
            evidence.failureCategory,
            stopReason: stopReason,
            executableFound: evidence.executableFound
        )
        var sanitizedSummary = sanitizedText(evidence.sanitizedSummary)
        if sanitizedSummary == nil, isRecordedStall(stopReason) {
            sanitizedSummary = "ASTRA recorded a stalled provider runtime."
        }
        let exitCode = boundedExitCode(evidence.exitCode)
        let stream = streamCounters(evidence.stream)
        let sandboxState = sanitizedText(evidence.sandboxState)
        let policyState = sanitizedText(evidence.policyState)

        let snapshot = FeedbackRuntimeSnapshotV1(
            runtimeID: FeedbackRuntimeIDV1(rawValue: runtimeID),
            providerVersion: providerVersion,
            executableFound: evidence.executableFound,
            readiness: readiness,
            failureCategory: failureCategory,
            unavailableReason: unavailableReason(
                executableFound: evidence.executableFound,
                providerVersion: providerVersion,
                readiness: readiness,
                failureCategory: failureCategory,
                sanitizedSummary: sanitizedSummary,
                exitCode: exitCode,
                stopReason: stopReason,
                stream: stream,
                sandboxState: sandboxState,
                policyState: policyState
            ),
            exitCode: exitCode,
            stopReason: stopReason,
            stream: stream,
            sandboxState: sandboxState,
            policyState: policyState,
            sanitizedSummary: sanitizedSummary
        )
        guard (try? snapshot.validate()) != nil else { return nil }
        return snapshot
    }

    private func mappedFailureCategory(
        _ rawCategory: String?,
        stopReason: String?,
        executableFound: Bool?
    ) -> FeedbackRuntimeFailureCategoryV1? {
        if executableFound == false {
            return .missing
        }
        if isRecordedStall(stopReason) || stopReason == "timeout" {
            return .timedOut
        }
        guard let category = boundedIdentifier(rawCategory) else { return nil }

        let mapped: FeedbackRuntimeFailureCategoryV1
        switch category.lowercased() {
        case "missing", "missing_executable", "runtime_missing", "docker_provider_executable_missing":
            mapped = .missing
        case "authentication_failed", "auth_required", "unauthenticated":
            mapped = .unauthenticated
        case "model_unavailable", "provider_configuration_invalid", "malformed_mcp_config", "unsupported_output_format", "misconfigured":
            mapped = .misconfigured
        case "permission_denied", "sandbox_credential_access_blocked":
            mapped = .permissionDenied
        case "runtime_timed_out", "timed_out":
            mapped = .timedOut
        case "rate_limited":
            mapped = .rateLimited
        case "quota_exceeded", "quota_exhausted", "quota_limited":
            mapped = .quotaLimited
        case "network_failed", "no_visible_output", "provider_process_failed", "process_failed":
            mapped = .processFailed
        case "not_recorded":
            mapped = .notRecorded
        default:
            // The frozen V1 contract intentionally permits additive categories.
            mapped = FeedbackRuntimeFailureCategoryV1(rawValue: category)
        }
        return mapped
    }

    private func unavailableReason(
        executableFound: Bool?,
        providerVersion: String?,
        readiness: String?,
        failureCategory: FeedbackRuntimeFailureCategoryV1?,
        sanitizedSummary: String?,
        exitCode: Int?,
        stopReason: String?,
        stream: FeedbackRuntimeStreamCountersV1?,
        sandboxState: String?,
        policyState: String?
    ) -> FeedbackEvidenceReasonV1? {
        if executableFound == false {
            return .unavailable
        }
        let hasRecordedDetail = providerVersion != nil
            || executableFound != nil
            || readiness != nil
            || failureCategory != nil
            || sanitizedSummary != nil
            || exitCode != nil
            || stopReason != nil
            || stream != nil
            || sandboxState != nil
            || policyState != nil
        return hasRecordedDetail ? nil : .notRecorded
    }

    private func streamCounters(
        _ counters: RuntimeFeedbackPersistedStreamCounters?
    ) -> FeedbackRuntimeStreamCountersV1? {
        guard let counters else { return nil }
        return FeedbackRuntimeStreamCountersV1(
            rawLines: boundedCounter(counters.rawLines),
            parsedEvents: boundedCounter(counters.parsedEvents),
            textEvents: boundedCounter(counters.textEvents),
            failedEvents: boundedCounter(counters.failedEvents)
        )
    }

    private func boundedCounter(_ value: Int) -> Int {
        min(max(0, value), FeedbackContractLimitsV1.maximumRuntimeCounter)
    }

    private func boundedExitCode(_ value: Int?) -> Int? {
        guard let value, (Int(Int32.min)...Int(Int32.max)).contains(value) else { return nil }
        return value
    }

    private func boundedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = FeedbackEvidenceSanitizer.sanitize(
            value,
            maximumBytes: FeedbackContractLimitsV1.identifierLength * 4
        )
        guard sanitized.redaction.replacements == 0, !sanitized.wasTruncated else { return nil }
        let normalized = FeedbackContractNormalizationV1.text(sanitized.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count <= FeedbackContractLimitsV1.identifierLength else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard normalized.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return normalized
    }

    private func sanitizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = FeedbackEvidenceSanitizer.sanitize(
            value,
            maximumBytes: FeedbackContractLimitsV1.shortTextLength
        )
        let sanitized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, !isRedactionOnly(sanitized) else { return nil }
        return sanitized
    }

    private func isRedactionOnly(_ value: String) -> Bool {
        let pattern = #"(?i)(?:\b(?:authorization|bearer|token|api[_-]?key|secret|password|credential)\s*[:=]\s*)?\[redacted-[A-Z-]+\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard expression.firstMatch(in: value, range: range) != nil else { return false }

        let remainder = expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: " "
        )
        return !remainder.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    private func isRecordedStall(_ stopReason: String?) -> Bool {
        guard let stopReason else { return false }
        return [
            "provider_no_actionable_progress",
            "provider_no_semantic_progress",
            "provider_semantic_progress_stalled",
            "provider_active_tool_stalled",
            "provider_workspace_job_stalled"
        ].contains(stopReason.lowercased())
    }
}
