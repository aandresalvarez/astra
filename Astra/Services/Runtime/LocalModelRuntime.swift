import Darwin
import Foundation
import SwiftData
import ASTRACore

enum LocalMLXRuntime {
    static let executableName = "astra-local-model"
    static let protocolFileDescriptor: Int32 = 3
    static let controlFileDescriptor: Int32 = 4
    static let defaultModel = "Qwen/Qwen3-4B-MLX-4bit"
    static let recommendedModelRepository = "Qwen/Qwen3-4B-MLX-4bit"
    static let defaultModels = [
        "Qwen/Qwen3-4B-MLX-4bit",
        "Qwen/Qwen3-8B-MLX-4bit",
        "mlx-community/Llama-3.2-3B-Instruct-4bit"
    ]
    static let localAgentExecutionCapabilities = AgentRuntimeExecutionCapabilities.astraBrokeredTools

    static var recommendedModelsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppChannel.current.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("LocalModels", isDirectory: true)
            .path
    }

    static var recommendedModelDirectory: String {
        recommendedModelDirectory(for: recommendedModelRepository)
    }

    static func recommendedModelDirectory(for repository: String) -> String {
        (recommendedModelsRoot as NSString)
            .appendingPathComponent(repository.split(separator: "/").last.map(String.init) ?? repository)
    }

    static var recommendedDownloadCommand: String {
        downloadCommand(
            repository: recommendedModelRepository,
            localDirectory: recommendedModelDirectory
        )
    }

    static var executableCandidates: [String] {
        [
            "\(RuntimePathResolver.astraToolsPath)/\(executableName)",
            "\(RuntimePathResolver.userLocalBin)/\(executableName)",
            "\(RuntimePathResolver.homebrewBin)/\(executableName)",
            "\(RuntimePathResolver.usrLocalBin)/\(executableName)",
            "\(RuntimePathResolver.npmGlobalBin)/\(executableName)",
            "\(RuntimePathResolver.usrBin)/\(executableName)"
        ]
    }

    static func detectPath(fileManager: FileManager = .default) -> String {
        RuntimePathResolver.detectExecutablePath(
            named: executableName,
            candidates: executableCandidates,
            fileManager: fileManager
        )
    }

    static func downloadCommand(repository: String, localDirectory: String) -> String {
        """
        mkdir -p "\(recommendedModelsRoot)"
        python3 - <<'PY'
        import importlib.util
        import os
        import subprocess
        import sys

        repo_id = "\(repository)"
        local_dir = "\(localDirectory)"
        os.makedirs(os.path.dirname(local_dir), exist_ok=True)
        if importlib.util.find_spec("huggingface_hub") is None:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "-U", "huggingface_hub[hf_xet]"])
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id=repo_id, local_dir=local_dir)
        PY
        """
    }
}

enum LocalModelReleaseGateStatus: String, Equatable, Sendable {
    case passed
    case inProgress = "in_progress"
}

struct LocalModelReleaseGateCheck: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var status: LocalModelReleaseGateStatus
    var evidence: [String]
    var blockers: [String]
}

struct LocalModelReleaseReadinessSummary: Equatable, Sendable {
    var isReadyForGA: Bool
    var title: String
    var detail: String
    var nextAction: String?
}

enum LocalModelReleaseReadinessSummaryBuilder {
    static func summary(for gates: [LocalModelReleaseGateCheck]) -> LocalModelReleaseReadinessSummary {
        let passedCount = gates.filter { $0.status == .passed }.count
        let totalCount = gates.count
        let blockers = gates.flatMap(\.blockers)
        let isReady = totalCount > 0 && passedCount == totalCount && blockers.isEmpty
        if isReady {
            return LocalModelReleaseReadinessSummary(
                isReadyForGA: true,
                title: "Ready for Local MLX general availability",
                detail: "All \(totalCount) Local MLX release gates have required evidence.",
                nextAction: nil
            )
        }
        return LocalModelReleaseReadinessSummary(
            isReadyForGA: false,
            title: "Not ready for Local MLX general availability",
            detail: "\(passedCount) of \(totalCount) Local MLX release gates have required evidence.",
            nextAction: nextAction(for: blockers)
        )
    }

    private static func nextAction(for blockers: [String]) -> String {
        guard !blockers.isEmpty else {
            return "Import the missing Local MLX release evidence."
        }
        let uniqueBlockers = blockers.reduce(into: [String]()) { result, blocker in
            let trimmed = blocker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        guard !uniqueBlockers.isEmpty else {
            return "Import the missing Local MLX release evidence."
        }
        if uniqueBlockers.count == 1 {
            return "Next action: \(uniqueBlockers[0])"
        }
        return "Next actions (\(uniqueBlockers.count)): \(uniqueBlockers.joined(separator: " | "))"
    }

    static func textReport(for gates: [LocalModelReleaseGateCheck]) -> String {
        let summary = summary(for: gates)
        var lines = [
            "Local MLX Release Readiness",
            summary.title,
            summary.detail
        ]
        if let nextAction = summary.nextAction {
            lines.append(nextAction)
        }
        lines.append("")
        for gate in gates {
            lines.append("\(gate.title): \(gate.status == .passed ? "passed" : "in progress")")
            if !gate.evidence.isEmpty {
                lines.append("Evidence:")
                lines += gate.evidence.map { "- \($0)" }
            }
            if !gate.blockers.isEmpty {
                lines.append("Blockers:")
                lines += gate.blockers.map { "- \($0)" }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalModelEvidencePayloadExtractor {
    static func jsonData(in payload: String) -> Data? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let object = firstJSONObject(in: payload) else { return nil }
        return object.data(using: .utf8)
    }

    private static func firstJSONObject(in payload: String) -> String? {
        var start: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false

        for index in payload.indices {
            let character = payload[index]
            if start == nil {
                if character == "{" {
                    start = index
                    depth = 1
                }
                continue
            }

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
                if depth == 0, let start {
                    let end = payload.index(after: index)
                    return String(payload[start..<end])
                }
            }
        }
        return nil
    }
}

struct LocalModelCombinedReleaseEvidenceBundle: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var releaseCandidateSamples: [LocalModelReleaseCandidateValidationSample]
    var betaSoakSamples: [LocalAgentBetaSoakSample]
    var hardwareSamples: [LocalModelSustainedValidationSample]

    init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        releaseCandidateSamples: [LocalModelReleaseCandidateValidationSample],
        betaSoakSamples: [LocalAgentBetaSoakSample],
        hardwareSamples: [LocalModelSustainedValidationSample]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.releaseCandidateSamples = releaseCandidateSamples
        self.betaSoakSamples = betaSoakSamples
        self.hardwareSamples = hardwareSamples
    }
}

struct LocalModelCombinedReleaseEvidenceMergeResult: Equatable, Sendable {
    var releaseCandidate: LocalModelReleaseCandidateValidationMergeResult
    var betaSoak: LocalAgentBetaSoakMergeResult
    var hardware: LocalModelHardwareValidationMergeResult

    var summary: String {
        [
            "Imported \(releaseCandidate.importedCount) release-candidate samples",
            "\(betaSoak.importedCount) beta-soak samples",
            "\(hardware.importedCount) hardware samples"
        ].joined(separator: ", ") + "."
    }
}

enum LocalModelCombinedReleaseEvidenceExchangeError: Error, Equatable, LocalizedError {
    case noSamples
    case unsupportedSchema(Int)
    case invalidPayload
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "Run or import Local MLX release, beta, or hardware evidence before copying a validation bundle."
        case .unsupportedSchema(let version):
            return "This Local MLX validation bundle uses an unsupported format version: \(version)."
        case .invalidPayload:
            return "The clipboard does not contain a valid Local MLX validation bundle."
        case .encodeFailed:
            return "ASTRA could not prepare the Local MLX validation bundle."
        }
    }
}

enum LocalModelCombinedReleaseEvidenceStore {
    static func exportEvidence(
        defaults: UserDefaults = .standard,
        exportedAt: Date = Date()
    ) throws -> String {
        let releaseSamples = LocalModelReleaseCandidateValidationStore.samples(defaults: defaults)
        let betaSamples = LocalAgentBetaSoakStore.samples(defaults: defaults)
        let hardwareSamples = LocalModelHardwareValidationStore.samples(defaults: defaults)
        guard !releaseSamples.isEmpty || !betaSamples.isEmpty || !hardwareSamples.isEmpty else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.noSamples
        }
        let bundle = LocalModelCombinedReleaseEvidenceBundle(
            exportedAt: exportedAt,
            releaseCandidateSamples: releaseSamples,
            betaSoakSamples: betaSamples,
            hardwareSamples: hardwareSamples
        )
        return try encodedEvidencePayload(bundle)
    }

    static func mergeEvidence(
        _ payload: String,
        defaults: UserDefaults = .standard
    ) throws -> LocalModelCombinedReleaseEvidenceMergeResult {
        guard let data = LocalModelEvidencePayloadExtractor.jsonData(in: payload) else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.invalidPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(LocalModelCombinedReleaseEvidenceBundle.self, from: data) else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.invalidPayload
        }
        guard bundle.schemaVersion == 1 else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.unsupportedSchema(bundle.schemaVersion)
        }
        guard !bundle.releaseCandidateSamples.isEmpty || !bundle.betaSoakSamples.isEmpty || !bundle.hardwareSamples.isEmpty else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.noSamples
        }

        let releaseResult = try mergeReleaseSamples(bundle.releaseCandidateSamples, defaults: defaults)
        let betaResult = try mergeBetaSamples(bundle.betaSoakSamples, defaults: defaults)
        let hardwareResult = try mergeHardwareSamples(bundle.hardwareSamples, defaults: defaults)
        return LocalModelCombinedReleaseEvidenceMergeResult(
            releaseCandidate: releaseResult,
            betaSoak: betaResult,
            hardware: hardwareResult
        )
    }

    private static func mergeReleaseSamples(
        _ samples: [LocalModelReleaseCandidateValidationSample],
        defaults: UserDefaults
    ) throws -> LocalModelReleaseCandidateValidationMergeResult {
        guard !samples.isEmpty else {
            return LocalModelReleaseCandidateValidationMergeResult(
                importedCount: 0,
                skippedCount: 0,
                report: LocalModelReleaseCandidateValidationStore.report(defaults: defaults)
            )
        }
        let payload = try encodedEvidencePayload(LocalModelReleaseCandidateValidationEvidenceBundle(samples: samples))
        return try LocalModelReleaseCandidateValidationStore.mergeEvidence(payload, defaults: defaults)
    }

    private static func mergeBetaSamples(
        _ samples: [LocalAgentBetaSoakSample],
        defaults: UserDefaults
    ) throws -> LocalAgentBetaSoakMergeResult {
        guard !samples.isEmpty else {
            return LocalAgentBetaSoakMergeResult(
                importedCount: 0,
                skippedCount: 0,
                report: LocalAgentBetaSoakStore.report(defaults: defaults)
            )
        }
        let payload = try encodedEvidencePayload(LocalAgentBetaSoakEvidenceBundle(samples: samples))
        return try LocalAgentBetaSoakStore.mergeEvidence(payload, defaults: defaults)
    }

    private static func mergeHardwareSamples(
        _ samples: [LocalModelSustainedValidationSample],
        defaults: UserDefaults
    ) throws -> LocalModelHardwareValidationMergeResult {
        guard !samples.isEmpty else {
            return LocalModelHardwareValidationMergeResult(
                importedCount: 0,
                skippedCount: 0,
                report: LocalModelHardwareValidationStore.report(defaults: defaults)
            )
        }
        let payload = try encodedEvidencePayload(LocalModelHardwareValidationEvidenceBundle(samples: samples))
        return try LocalModelHardwareValidationStore.mergeEvidence(payload, defaults: defaults)
    }

    private static func encodedEvidencePayload<T: Encodable>(_ bundle: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8) else {
            throw LocalModelCombinedReleaseEvidenceExchangeError.encodeFailed
        }
        return payload
    }
}

enum LocalAgentBetaSoakOutcome: String, Codable, Equatable, Sendable {
    case completed
    case blocked
    case approvalRequired = "approval_required"
    case cancelled
}

struct LocalAgentBetaSoakSample: Codable, Equatable, Sendable {
    var recordedAt: Date
    var model: String
    var outcome: LocalAgentBetaSoakOutcome
    var stopReason: String
    var enabledCapabilities: [String]
    var proposedTools: [String]
    var executedTools: [String]
    var successfulTools: [String]
    var turns: Int
    var toolCalls: Int
    var toolSuccesses: Int
    var toolErrors: Int
    var policyDecisions: Int
    var policyApprovalRequests: Int
    var policyViolations: Int
    var invalidActionRepairs: Int
    var missingToolFinalRepairs: Int
    var watchdogWarnings: Int
    var memoryDiagnostics: Int
    var firstTokenLatencyMs: Int?
    var tokensPerSecond: Double?
}

struct LocalAgentBetaSoakReport: Equatable, Sendable {
    var requiredHighRiskTools: [String]
    var coveredHighRiskTools: [String]
    var missingHighRiskTools: [String]
    var hasReadOnlyCompletedSample: Bool
    var nonCoveringSamples: [LocalAgentBetaSoakSample]
    var sampleCount: Int
    var completedCount: Int
    var blockedCount: Int
    var approvalRequiredCount: Int
    var cancelledCount: Int

    var isCompleteForBeta: Bool {
        hasReadOnlyCompletedSample && missingHighRiskTools.isEmpty
    }

    var summary: String {
        var missing: [String] = []
        if !hasReadOnlyCompletedSample {
            missing.append("read-only Local Agent workflow")
        }
        missing += missingHighRiskTools
        guard !missing.isEmpty else {
            return "Local Agent beta soak covers the read-only workflow and every high-risk beta tool."
        }
        return "Missing Local Agent beta soak coverage for: \(missing.joined(separator: ", "))."
    }

    var nonCoveringSummary: String {
        guard !nonCoveringSamples.isEmpty else {
            return "All beta-soak samples satisfy Gate C evidence rules."
        }
        return "\(nonCoveringSamples.count) beta-soak sample(s) do not count for Gate C. Samples must complete with \(LocalMLXRuntime.recommendedModelRepository) or be expected approval checkpoints."
    }
}

struct LocalAgentBetaSoakEvidenceBundle: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var samples: [LocalAgentBetaSoakSample]

    init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        samples: [LocalAgentBetaSoakSample]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.samples = samples
    }
}

struct LocalAgentBetaSoakMergeResult: Equatable, Sendable {
    var importedCount: Int
    var skippedCount: Int
    var report: LocalAgentBetaSoakReport
}

enum LocalAgentBetaSoakExchangeError: Error, Equatable, LocalizedError {
    case noSamples
    case unsupportedSchema(Int)
    case invalidPayload
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "Run Local Agent beta workflows before copying beta-soak evidence."
        case .unsupportedSchema(let version):
            return "This Local Agent beta-soak evidence uses an unsupported format version: \(version)."
        case .invalidPayload:
            return "The clipboard does not contain valid Local Agent beta-soak evidence."
        case .encodeFailed:
            return "ASTRA could not prepare the Local Agent beta-soak evidence."
        }
    }
}

enum LocalAgentBetaSoakMatrix {
    static let requiredHighRiskTools = LocalAgentBetaToolSurface.highRiskToolNames

    static func report(samples: [LocalAgentBetaSoakSample]) -> LocalAgentBetaSoakReport {
        let completedSamples = samples.filter {
            $0.outcome == .completed
                && $0.model.trimmingCharacters(in: .whitespacesAndNewlines) == LocalMLXRuntime.recommendedModelRepository
        }
        let nonCovering = samples.filter {
            !sampleCountsForGateC($0)
                && !sampleIsExpectedApprovalCheckpoint($0)
        }
        let covered = requiredHighRiskTools.filter { tool in
            completedSamples.contains { sample in
                sample.successfulTools.contains(tool)
            }
        }
        let hasReadOnlyCompletedSample = completedSamples.contains { sample in
            sample.successfulTools.contains { LocalAgentBetaToolSurface.readOnlyToolNames.contains($0) }
                && sample.successfulTools.allSatisfy { !requiredHighRiskTools.contains($0) }
        }
        return LocalAgentBetaSoakReport(
            requiredHighRiskTools: requiredHighRiskTools,
            coveredHighRiskTools: covered,
            missingHighRiskTools: requiredHighRiskTools.filter { !covered.contains($0) },
            hasReadOnlyCompletedSample: hasReadOnlyCompletedSample,
            nonCoveringSamples: nonCovering,
            sampleCount: samples.count,
            completedCount: samples.filter { $0.outcome == .completed }.count,
            blockedCount: samples.filter { $0.outcome == .blocked }.count,
            approvalRequiredCount: samples.filter { $0.outcome == .approvalRequired }.count,
            cancelledCount: samples.filter { $0.outcome == .cancelled }.count
        )
    }

    private static func sampleCountsForGateC(_ sample: LocalAgentBetaSoakSample) -> Bool {
        sample.outcome == .completed
            && sample.model.trimmingCharacters(in: .whitespacesAndNewlines) == LocalMLXRuntime.recommendedModelRepository
    }

    private static func sampleIsExpectedApprovalCheckpoint(_ sample: LocalAgentBetaSoakSample) -> Bool {
        sample.outcome == .approvalRequired
            && sample.model.trimmingCharacters(in: .whitespacesAndNewlines) == LocalMLXRuntime.recommendedModelRepository
            && sample.stopReason == "permission_approval_required"
            && sample.successfulTools.isEmpty
    }
}

enum LocalAgentBetaSoakStore {
    static let samplesKey = "astra.localModel.localAgent.betaSoakSamples.v1"
    static let evidenceOutputEnvironmentKey = "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT"

    static func samples(defaults: UserDefaults = .standard) -> [LocalAgentBetaSoakSample] {
        guard let data = defaults.data(forKey: samplesKey),
              let samples = try? JSONDecoder().decode([LocalAgentBetaSoakSample].self, from: data) else {
            return []
        }
        return deduplicated(samples)
    }

    static func record(
        _ sample: LocalAgentBetaSoakSample,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 128
    ) {
        var stored = samples(defaults: defaults)
        stored.append(sample)
        save(stored, defaults: defaults, maxSamples: maxSamples)
    }

    static func exportEvidence(
        defaults: UserDefaults = .standard,
        exportedAt: Date = Date()
    ) throws -> String {
        let stored = samples(defaults: defaults)
        guard !stored.isEmpty else {
            throw LocalAgentBetaSoakExchangeError.noSamples
        }
        let bundle = LocalAgentBetaSoakEvidenceBundle(
            exportedAt: exportedAt,
            samples: stored
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8) else {
            throw LocalAgentBetaSoakExchangeError.encodeFailed
        }
        return payload
    }

    static func mergeEvidence(
        _ payload: String,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 128
    ) throws -> LocalAgentBetaSoakMergeResult {
        guard let data = LocalModelEvidencePayloadExtractor.jsonData(in: payload) else {
            throw LocalAgentBetaSoakExchangeError.invalidPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(LocalAgentBetaSoakEvidenceBundle.self, from: data) else {
            throw LocalAgentBetaSoakExchangeError.invalidPayload
        }
        guard bundle.schemaVersion == 1 else {
            throw LocalAgentBetaSoakExchangeError.unsupportedSchema(bundle.schemaVersion)
        }
        var stored = samples(defaults: defaults)
        var imported = 0
        var skipped = 0
        for sample in bundle.samples {
            if stored.contains(sample) {
                skipped += 1
            } else {
                stored.append(sample)
                imported += 1
            }
        }
        save(stored, defaults: defaults, maxSamples: maxSamples)
        return LocalAgentBetaSoakMergeResult(
            importedCount: imported,
            skippedCount: skipped,
            report: report(defaults: defaults)
        )
    }

    private static func save(
        _ samples: [LocalAgentBetaSoakSample],
        defaults: UserDefaults,
        maxSamples: Int
    ) {
        var stored = deduplicated(samples)
        if stored.count > maxSamples {
            stored.removeFirst(stored.count - maxSamples)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: samplesKey)
    }

    static func recordRuntimeSample(_ sample: LocalAgentBetaSoakSample) {
        let environment = ProcessInfo.processInfo.environment
        let outputPath = environment[evidenceOutputEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isXCTest = environment["XCTestConfigurationFilePath"] != nil
        if !outputPath.isEmpty {
            writeEvidenceFile(sample: sample, outputPath: outputPath)
            if isXCTest {
                return
            }
        }
        guard !isXCTest else {
            return
        }
        record(sample)
    }

    private static func writeEvidenceFile(sample: LocalAgentBetaSoakSample, outputPath: String) {
        let fileManager = FileManager.default
        var existingSamples: [LocalAgentBetaSoakSample] = []
        if fileManager.fileExists(atPath: outputPath),
           let existingPayload = try? String(contentsOfFile: outputPath, encoding: .utf8),
           let data = existingPayload.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let bundle = try? decoder.decode(LocalAgentBetaSoakEvidenceBundle.self, from: data),
               bundle.schemaVersion == 1 {
                existingSamples = bundle.samples
            }
        }
        let bundle = LocalAgentBetaSoakEvidenceBundle(
            samples: deduplicated(existingSamples + [sample])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        try? FileManager.default.createDirectory(
            atPath: (outputPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? payload.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    static func report(defaults: UserDefaults = .standard) -> LocalAgentBetaSoakReport {
        LocalAgentBetaSoakMatrix.report(samples: samples(defaults: defaults))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: samplesKey)
    }

    private static func deduplicated(_ samples: [LocalAgentBetaSoakSample]) -> [LocalAgentBetaSoakSample] {
        var unique: [LocalAgentBetaSoakSample] = []
        for sample in samples {
            let key = betaSoakKey(for: sample)
            if let index = unique.firstIndex(where: { betaSoakKey(for: $0) == key }) {
                unique[index] = sample
            } else {
                unique.append(sample)
            }
        }
        return unique
    }

    private static func betaSoakKey(for sample: LocalAgentBetaSoakSample) -> String {
        [
            sample.model,
            sample.outcome.rawValue,
            sample.stopReason,
            sample.enabledCapabilities.joined(separator: ","),
            sample.proposedTools.joined(separator: ","),
            sample.executedTools.joined(separator: ","),
            sample.successfulTools.joined(separator: ",")
        ].joined(separator: "\u{1F}")
    }
}

enum LocalModelReleaseCandidateValidationMode: String, CaseIterable, Codable, Equatable, Sendable {
    case localChat = "local_chat"
    case localAgentReadOnly = "local_agent_read_only"

    var displayName: String {
        switch self {
        case .localChat:
            return "Private Local Chat live e2e"
        case .localAgentReadOnly:
            return "Local Agent read-only live e2e"
        }
    }
}

enum LocalModelReleaseCandidateValidationOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

struct LocalModelReleaseCandidateValidationSample: Codable, Equatable, Sendable {
    var recordedAt: Date
    var buildIdentifier: String?
    var mode: LocalModelReleaseCandidateValidationMode
    var outcome: LocalModelReleaseCandidateValidationOutcome
    var model: String
    var modelDirectory: String
    var helperPath: String
    var inputTokens: Int
    var outputTokens: Int
    var stopReason: String
    var marker: String
}

struct LocalModelReleaseCandidateValidationReport: Equatable, Sendable {
    var requiredModes: [LocalModelReleaseCandidateValidationMode]
    var coveredModes: [LocalModelReleaseCandidateValidationMode]
    var missingModes: [LocalModelReleaseCandidateValidationMode]
    var nonCoveringSamples: [LocalModelReleaseCandidateValidationSample]
    var samples: [LocalModelReleaseCandidateValidationSample]

    var isCompleteForGA: Bool {
        missingModes.isEmpty
    }

    var buildBoundCoveredModes: [LocalModelReleaseCandidateValidationMode] {
        requiredModes.filter { mode in
            samples.contains { sample in
                sample.mode == mode
                    && sample.isUsableReleaseEvidence
                    && sample.hasBuildIdentifier
            }
        }
    }

    var missingBuildBoundModes: [LocalModelReleaseCandidateValidationMode] {
        requiredModes.filter { !buildBoundCoveredModes.contains($0) }
    }

    var isBuildBoundCompleteForGA: Bool {
        missingBuildBoundModes.isEmpty
    }

    var summary: String {
        guard !missingModes.isEmpty else {
            return "Release-candidate live validation covers Private Local Chat and Local Agent read-only e2e."
        }
        return "Missing release-candidate live validation for: \(missingModes.map(\.displayName).joined(separator: ", "))."
    }

    var buildIdentifierSummary: String {
        let unique = uniqueBuildIdentifiers
        guard !unique.isEmpty else {
            return "No build-bound release-candidate evidence."
        }
        return "Release-candidate build ids: \(unique.joined(separator: ", "))."
    }

    var uniqueBuildIdentifiers: [String] {
        let identifiers = samples
            .filter(\.isUsableReleaseEvidence)
            .compactMap { $0.buildIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(identifiers)).sorted()
    }

    var buildBoundSummary: String {
        guard !missingBuildBoundModes.isEmpty else {
            return "Build-bound release-candidate evidence covers Private Local Chat and Local Agent read-only e2e."
        }
        return "Missing build-bound release-candidate evidence for: \(missingBuildBoundModes.map(\.displayName).joined(separator: ", "))."
    }

    var nonCoveringSummary: String {
        guard !nonCoveringSamples.isEmpty else {
            return "All release-candidate samples satisfy Gate A/B evidence rules."
        }
        return "\(nonCoveringSamples.count) release-candidate sample(s) do not count for Gates A/B/D. Release-candidate samples must use \(LocalMLXRuntime.recommendedModelRepository) and include model folder, helper path, tokens, stop reason, and marker."
    }
}

struct LocalModelReleaseCandidateValidationEvidenceBundle: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var samples: [LocalModelReleaseCandidateValidationSample]

    init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        samples: [LocalModelReleaseCandidateValidationSample]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.samples = samples
    }
}

struct LocalModelReleaseCandidateValidationMergeResult: Equatable, Sendable {
    var importedCount: Int
    var skippedCount: Int
    var report: LocalModelReleaseCandidateValidationReport
}

enum LocalModelReleaseCandidateValidationExchangeError: Error, Equatable, LocalizedError {
    case noSamples
    case unsupportedSchema(Int)
    case invalidPayload
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "Run Local MLX release-candidate live validation before copying evidence."
        case .unsupportedSchema(let version):
            return "This release-candidate validation evidence uses an unsupported format version: \(version)."
        case .invalidPayload:
            return "The clipboard does not contain valid Local MLX release-candidate validation evidence."
        case .encodeFailed:
            return "ASTRA could not prepare the release-candidate validation evidence."
        }
    }
}

enum LocalModelReleaseCandidateValidationMatrix {
    static let requiredModes: [LocalModelReleaseCandidateValidationMode] = [
        .localChat,
        .localAgentReadOnly
    ]

    static func report(
        samples: [LocalModelReleaseCandidateValidationSample]
    ) -> LocalModelReleaseCandidateValidationReport {
        let covered = requiredModes.filter { mode in
            samples.contains { sample in
                sample.mode == mode && sample.isUsableReleaseEvidence
            }
        }
        return LocalModelReleaseCandidateValidationReport(
            requiredModes: requiredModes,
            coveredModes: covered,
            missingModes: requiredModes.filter { !covered.contains($0) },
            nonCoveringSamples: samples.filter { !$0.isUsableReleaseEvidence },
            samples: samples
        )
    }
}

extension LocalModelReleaseCandidateValidationSample {
    var isUsableReleaseEvidence: Bool {
        outcome == .passed
            && model.trimmingCharacters(in: .whitespacesAndNewlines) == LocalMLXRuntime.recommendedModelRepository
            && !modelDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !helperPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inputTokens > 0
            && outputTokens > 0
            && !stopReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBuildIdentifier: Bool {
        !(buildIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LocalModelReleaseCandidateValidationStore {
    static let samplesKey = "astra.localModel.releaseCandidateValidationSamples.v1"

    static func samples(defaults: UserDefaults = .standard) -> [LocalModelReleaseCandidateValidationSample] {
        guard let data = defaults.data(forKey: samplesKey),
              let samples = try? JSONDecoder().decode([LocalModelReleaseCandidateValidationSample].self, from: data) else {
            return []
        }
        return deduplicated(samples)
    }

    static func record(
        _ sample: LocalModelReleaseCandidateValidationSample,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 32
    ) {
        var stored = samples(defaults: defaults)
        stored.append(sample)
        save(stored, defaults: defaults, maxSamples: maxSamples)
    }

    static func exportEvidence(
        defaults: UserDefaults = .standard,
        exportedAt: Date = Date()
    ) throws -> String {
        let stored = samples(defaults: defaults)
        guard !stored.isEmpty else {
            throw LocalModelReleaseCandidateValidationExchangeError.noSamples
        }
        let bundle = LocalModelReleaseCandidateValidationEvidenceBundle(
            exportedAt: exportedAt,
            samples: stored
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8) else {
            throw LocalModelReleaseCandidateValidationExchangeError.encodeFailed
        }
        return payload
    }

    static func mergeEvidence(
        _ payload: String,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 32
    ) throws -> LocalModelReleaseCandidateValidationMergeResult {
        guard let data = LocalModelEvidencePayloadExtractor.jsonData(in: payload) else {
            throw LocalModelReleaseCandidateValidationExchangeError.invalidPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(LocalModelReleaseCandidateValidationEvidenceBundle.self, from: data) else {
            throw LocalModelReleaseCandidateValidationExchangeError.invalidPayload
        }
        guard bundle.schemaVersion == 1 else {
            throw LocalModelReleaseCandidateValidationExchangeError.unsupportedSchema(bundle.schemaVersion)
        }
        var stored = samples(defaults: defaults)
        var imported = 0
        var skipped = 0
        for sample in bundle.samples {
            if stored.contains(sample) {
                skipped += 1
            } else {
                stored.append(sample)
                imported += 1
            }
        }
        save(stored, defaults: defaults, maxSamples: maxSamples)
        return LocalModelReleaseCandidateValidationMergeResult(
            importedCount: imported,
            skippedCount: skipped,
            report: report(defaults: defaults)
        )
    }

    private static func save(
        _ samples: [LocalModelReleaseCandidateValidationSample],
        defaults: UserDefaults,
        maxSamples: Int
    ) {
        var stored = deduplicated(samples)
        if stored.count > maxSamples {
            stored.removeFirst(stored.count - maxSamples)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: samplesKey)
    }

    private static func deduplicated(
        _ samples: [LocalModelReleaseCandidateValidationSample]
    ) -> [LocalModelReleaseCandidateValidationSample] {
        var unique: [LocalModelReleaseCandidateValidationSample] = []
        for sample in samples {
            let key = releaseEvidenceKey(for: sample)
            if let index = unique.firstIndex(where: { releaseEvidenceKey(for: $0) == key }) {
                unique[index] = sample
            } else {
                unique.append(sample)
            }
        }
        return unique
    }

    private static func releaseEvidenceKey(for sample: LocalModelReleaseCandidateValidationSample) -> String {
        [
            sample.mode.rawValue,
            sample.outcome.rawValue,
            sample.model,
            sample.modelDirectory,
            sample.helperPath,
            sample.buildIdentifier ?? "",
            sample.marker
        ].joined(separator: "\u{1F}")
    }

    static func report(defaults: UserDefaults = .standard) -> LocalModelReleaseCandidateValidationReport {
        LocalModelReleaseCandidateValidationMatrix.report(samples: samples(defaults: defaults))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: samplesKey)
    }
}

enum LocalModelReleaseGateAudit {
    static var gates: [LocalModelReleaseGateCheck] {
        checks()
    }

    static func checks(
        defaults: UserDefaults = .standard,
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport? = nil
    ) -> [LocalModelReleaseGateCheck] {
        let betaReport = LocalAgentBetaSoakStore.report(defaults: defaults)
        let hardwareReport = LocalModelHardwareValidationStore.report(defaults: defaults)
        let releaseReport = releaseCandidateReport ?? LocalModelReleaseCandidateValidationStore.report(defaults: defaults)
        return [
            gateA(releaseCandidateReport: releaseReport),
            gateB(releaseCandidateReport: releaseReport),
            gateC(betaReport: betaReport),
            gateD(
                hardwareReport: hardwareReport,
                releaseCandidateReport: releaseReport,
                betaReport: betaReport
            )
        ]
    }

    private static func gateA(
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport
    ) -> LocalModelReleaseGateCheck {
        let hasLiveChatEvidence = releaseCandidateReport.coveredModes.contains(.localChat)
        let blockers = hasLiveChatEvidence
            ? []
            : ["Record Private Local Chat release-candidate live e2e evidence before claiming Local Chat preview readiness."]
        return LocalModelReleaseGateCheck(
            id: "gate-a-local-chat-preview",
            title: "Gate A: Local Chat preview",
            status: blockers.isEmpty ? .passed : .inProgress,
            evidence: [
                "Local MLX provider, installed-model menu, one-click install, readiness, text-only prompt guard, and fake-helper Local Chat coverage are implemented.",
                hasLiveChatEvidence
                    ? "Private Local Chat release-candidate live e2e evidence is recorded."
                    : "No Private Local Chat release-candidate live e2e evidence recorded yet."
            ],
            blockers: blockers
        )
    }

    private static func gateB(
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport
    ) -> LocalModelReleaseGateCheck {
        let hasLiveAgentEvidence = releaseCandidateReport.coveredModes.contains(.localAgentReadOnly)
        let blockers = hasLiveAgentEvidence
            ? []
            : ["Record Local Agent read-only release-candidate live e2e evidence before claiming developer-flag readiness."]
        return LocalModelReleaseGateCheck(
            id: "gate-b-local-agent-developer-flag",
            title: "Gate B: Local Agent developer flag",
            status: blockers.isEmpty ? .passed : .inProgress,
            evidence: [
                "Local Agent is behind the experimental tools flag.",
                "Read-only tool loops, typed action parsing, policy checks, cancellation, fake-completion prevention, approvals, and metrics have focused regression coverage.",
                hasLiveAgentEvidence
                    ? "Local Agent read-only release-candidate live e2e evidence is recorded."
                    : "No Local Agent read-only release-candidate live e2e evidence recorded yet."
            ],
            blockers: blockers
        )
    }

    private static func gateC(betaReport: LocalAgentBetaSoakReport) -> LocalModelReleaseGateCheck {
        var blockers: [String] = []
        if !betaReport.isCompleteForBeta {
            blockers.append("Run a broader beta soak with real Local Agent high-risk tool workflows before claiming beta stability.")
            if !betaReport.hasReadOnlyCompletedSample {
                blockers.append("Record at least one completed read-only Local Agent workflow.")
            }
            if !betaReport.missingHighRiskTools.isEmpty {
                blockers.append("Record completed Local Agent workflows for: \(betaReport.missingHighRiskTools.joined(separator: ", ")).")
            }
        }
        return LocalModelReleaseGateCheck(
            id: "gate-c-local-agent-beta",
            title: "Gate C: Local Agent beta",
            status: blockers.isEmpty ? .passed : .inProgress,
            evidence: [
                "The beta tool surface is explicit and audited.",
                "High-risk tools have separate capability gates, approval paths, audit artifacts, timeouts, cancellation, and focused tests.",
                "Beta-soak samples: \(betaReport.sampleCount) total, \(betaReport.completedCount) completed, \(betaReport.blockedCount) blocked, \(betaReport.approvalRequiredCount) approval-required, \(betaReport.cancelledCount) cancelled.",
                "Covered high-risk tools: \(releaseList(betaReport.coveredHighRiskTools)).",
                "Missing high-risk tools: \(releaseList(betaReport.missingHighRiskTools)).",
                betaReport.nonCoveringSummary,
                betaReport.summary
            ],
            blockers: blockers
        )
    }

    private static func gateD(
        hardwareReport: LocalModelHardwareValidationReport,
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport,
        betaReport: LocalAgentBetaSoakReport
    ) -> LocalModelReleaseGateCheck {
        var blockers: [String] = []
        if !betaReport.isCompleteForBeta {
            blockers.append("Complete Gate C beta-soak evidence before claiming Local MLX general availability.")
        }
        if !hardwareReport.isCompleteForGA {
            blockers.append(hardwareReport.summary)
        }
        if !releaseCandidateReport.isCompleteForGA {
            blockers.append(releaseCandidateReport.summary)
        }
        if !releaseCandidateReport.isBuildBoundCompleteForGA {
            blockers.append(releaseCandidateReport.buildBoundSummary)
        }
        if !releaseCandidateReport.nonCoveringSamples.isEmpty {
            blockers.append("Remove or replace non-covering release-candidate evidence before GA packaging.")
        }
        if !betaReport.nonCoveringSamples.isEmpty {
            blockers.append("Remove or replace non-covering Local Agent beta-soak evidence before GA packaging.")
        }
        if !hardwareReport.nonCoveringSamples.isEmpty {
            blockers.append("Remove or replace non-covering hardware evidence before GA packaging.")
        }
        let packagingPreflight = releasePackagingPreflightCommand(
            releaseCandidateReport: releaseCandidateReport,
            isReady: blockers.isEmpty
        )
        return LocalModelReleaseGateCheck(
            id: "gate-d-general-availability",
            title: "Gate D: General availability",
            status: blockers.isEmpty ? .passed : .inProgress,
            evidence: [
                "Install, readiness, hardware warnings, Local Chat, Local Agent beta coverage, and release-candidate evidence are required before GA.",
                "Gate C beta-soak status: \(betaReport.isCompleteForBeta ? "complete" : "incomplete"). \(betaReport.summary)",
                nextBetaCollectionCommand(betaReport: betaReport),
                "Hardware validation samples: \(hardwareReport.samples.count). \(hardwareReport.summary)",
                "Covered hardware tiers: \(releaseList(hardwareReport.coveredTiers.map(\.displayName))).",
                "Missing hardware tiers: \(releaseList(hardwareReport.missingTiers.map(\.displayName))).",
                hardwareReport.nonCoveringSummary,
                "Next hardware collection: \(releaseList(hardwareReport.missingTiers.map { "\($0.displayName): \($0.collectionCommand)" })).",
                "Release-candidate validation samples: \(releaseCandidateReport.samples.count). \(releaseCandidateReport.summary)",
                releaseCandidateReport.nonCoveringSummary,
                releaseCandidateReport.buildIdentifierSummary,
                "Covered release-candidate modes: \(releaseList(releaseCandidateReport.coveredModes.map(\.displayName))).",
                "Missing release-candidate modes: \(releaseList(releaseCandidateReport.missingModes.map(\.displayName))).",
                "Missing build-bound release-candidate modes: \(releaseList(releaseCandidateReport.missingBuildBoundModes.map(\.displayName))).",
                nextReleaseCandidateCollectionCommand(releaseCandidateReport: releaseCandidateReport),
                "Recommended first-install model: \(LocalMLXRuntime.recommendedModelRepository).",
                packagingPreflight,
            ],
            blockers: blockers
        )
    }

    private static func releaseList(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private static func nextBetaCollectionCommand(betaReport: LocalAgentBetaSoakReport) -> String {
        guard !betaReport.isCompleteForBeta else {
            return "Next beta collection: none."
        }
        return "Next beta collection: run script/local_mlx_collect_release_evidence.sh --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" --include-high-risk-tools --beta-out /tmp/astra-local-agent-beta-soak-evidence.json."
    }

    private static func nextReleaseCandidateCollectionCommand(
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport
    ) -> String {
        guard !releaseCandidateReport.isCompleteForGA || !releaseCandidateReport.isBuildBoundCompleteForGA else {
            return "Next release-candidate collection: none."
        }
        return "Next release-candidate collection: run script/local_mlx_collect_release_evidence.sh --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" --out /tmp/astra-local-mlx-release-evidence.json."
    }

    private static func releasePackagingPreflightCommand(
        releaseCandidateReport: LocalModelReleaseCandidateValidationReport,
        isReady: Bool
    ) -> String {
        guard isReady else {
            return "Release packaging preflight: unavailable until Gates A-D are complete."
        }
        let buildIdentifier = releaseCandidateReport.uniqueBuildIdentifiers.count == 1
            ? releaseCandidateReport.uniqueBuildIdentifiers[0]
            : "ASTRA_VERSION+ASTRA_BUILD"
        return """
        Release packaging preflight: save the copied validation bundle to /tmp/astra-local-mlx-validation-bundle.json, then run ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1 ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1 ASTRA_LOCAL_MLX_RELEASE_BUILD_ID=\(buildIdentifier) ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json script/release_update.sh.
        """
    }
}

enum LocalAgentToolCapability: String, CaseIterable, Hashable, Sendable {
    case taskOutputWrite = "task_output_write"
    case workspaceWrite = "workspace_write"
    case shellExecution = "shell_execution"
    case networkFetch = "network_fetch"
    case browserClick = "browser_click"
    case browserType = "browser_type"

    var settingsKey: String {
        switch self {
        case .taskOutputWrite:
            return "astra.localModel.localAgent.capability.taskOutputWrite.v1"
        case .workspaceWrite:
            return "astra.localModel.localAgent.capability.workspaceWrite.v1"
        case .shellExecution:
            return "astra.localModel.localAgent.capability.shellExecution.v1"
        case .networkFetch:
            return "astra.localModel.localAgent.capability.networkFetch.v1"
        case .browserClick:
            return "astra.localModel.localAgent.capability.browserClick.v1"
        case .browserType:
            return "astra.localModel.localAgent.capability.browserType.v1"
        }
    }

    var displayName: String {
        switch self {
        case .taskOutputWrite:
            return "task output writes"
        case .workspaceWrite:
            return "scoped file edits"
        case .shellExecution:
            return "shell commands"
        case .networkFetch:
            return "network fetches"
        case .browserClick:
            return "browser clicks"
        case .browserType:
            return "browser typing"
        }
    }

    var toolName: String {
        switch self {
        case .taskOutputWrite:
            return "task.write_output"
        case .workspaceWrite:
            return "workspace.write_file"
        case .shellExecution:
            return "shell.exec"
        case .networkFetch:
            return "network.fetch"
        case .browserClick:
            return "browser.click"
        case .browserType:
            return "browser.type"
        }
    }

    static func capability(for tool: String) -> LocalAgentToolCapability? {
        switch tool {
        case "task.write_output":
            return .taskOutputWrite
        case "workspace.write_file":
            return .workspaceWrite
        case "shell.exec":
            return .shellExecution
        case "network.fetch":
            return .networkFetch
        case "browser.click":
            return .browserClick
        case "browser.type":
            return .browserType
        default:
            return nil
        }
    }
}

enum LocalAgentToolRisk: Equatable, Sendable {
    case readOnly
    case highRisk(LocalAgentToolCapability)
}

struct LocalAgentToolSpec: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var risk: LocalAgentToolRisk

    var capability: LocalAgentToolCapability? {
        guard case .highRisk(let capability) = risk else { return nil }
        return capability
    }
}

enum LocalAgentBetaToolSurface {
    static let highRiskCapabilities: [LocalAgentToolCapability] = [
        .taskOutputWrite,
        .workspaceWrite,
        .shellExecution,
        .networkFetch,
        .browserClick,
        .browserType
    ]

    static let toolSpecs: [LocalAgentToolSpec] = [
        LocalAgentToolSpec(name: "workspace.read_file", risk: .readOnly),
        LocalAgentToolSpec(name: "workspace.list_files", risk: .readOnly),
        LocalAgentToolSpec(name: "workspace.search", risk: .readOnly),
        LocalAgentToolSpec(name: "task.list_outputs", risk: .readOnly),
        LocalAgentToolSpec(name: "task.read_output", risk: .readOnly),
        LocalAgentToolSpec(name: "browser.read_page", risk: .readOnly),
        LocalAgentToolSpec(name: "browser.analyze", risk: .readOnly),
        LocalAgentToolSpec(name: "jira.search", risk: .readOnly),
        LocalAgentToolSpec(name: "github.search", risk: .readOnly),
        LocalAgentToolSpec(name: "google_drive.search", risk: .readOnly),
        LocalAgentToolSpec(name: "google_drive.read", risk: .readOnly),
        LocalAgentToolSpec(name: "gmail.search", risk: .readOnly),
        LocalAgentToolSpec(name: "gmail.read", risk: .readOnly),
        LocalAgentToolSpec(name: "slack.search", risk: .readOnly),
        LocalAgentToolSpec(name: "slack.thread", risk: .readOnly),
    ] + highRiskCapabilities.map { capability in
        LocalAgentToolSpec(name: capability.toolName, risk: .highRisk(capability))
    }

    static var readOnlyToolNames: [String] {
        toolSpecs.compactMap { spec in
            guard spec.capability == nil else { return nil }
            return spec.name
        }
    }

    static var highRiskToolNames: [String] {
        highRiskCapabilities.map(\.toolName)
    }

    static var allToolNames: [String] {
        readOnlyToolNames + highRiskToolNames
    }

    static let browserMutationToolNames = [
        "browser.click",
        "browser.type"
    ]

    static let deferredBrowserMutationToolNames = [
        "browser.navigate",
        "browser.submit",
        "browser.select",
        "browser.upload",
        "browser.keypress",
        "browser.scroll",
        "browser.drag",
        "browser.evaluate",
        "browser.download"
    ]

    static let betaDecision = "Local Agent beta supports read-only tools plus separately approved task output writes, scoped workspace file edits, shell commands, URL fetches, browser clicks, and browser typing. Browser mutations beyond click/type are deferred."

    static func spec(for toolName: String) -> LocalAgentToolSpec? {
        toolSpecs.first { $0.name == toolName }
    }
}

struct LocalAgentToolCapabilities: Equatable, Sendable {
    var enabled: Set<LocalAgentToolCapability>

    static let none = LocalAgentToolCapabilities(enabled: [])
    static let all = LocalAgentToolCapabilities(enabled: Set(LocalAgentToolCapability.allCases))

    static func current(defaults: UserDefaults = .standard) -> LocalAgentToolCapabilities {
        LocalAgentToolCapabilities(
            enabled: Set(LocalAgentToolCapability.allCases.filter { capability in
                defaults.bool(forKey: capability.settingsKey)
            })
        )
    }

    func contains(_ capability: LocalAgentToolCapability) -> Bool {
        enabled.contains(capability)
    }

    func disabledCapability(for tool: String) -> LocalAgentToolCapability? {
        guard let capability = LocalAgentToolCapability.capability(for: tool),
              !enabled.contains(capability) else {
            return nil
        }
        return capability
    }

    var supportedToolNames: [String] {
        let gated = LocalAgentBetaToolSurface.highRiskCapabilities
            .filter { enabled.contains($0) }
            .map(\.toolName)
        return LocalAgentBetaToolSurface.readOnlyToolNames + gated
    }

    var enabledSummary: String {
        guard !enabled.isEmpty else {
            return "read-only tools only"
        }
        let names = LocalAgentToolCapability.allCases
            .filter { enabled.contains($0) }
            .map(\.displayName)
        return "read-only tools plus " + names.joined(separator: ", ")
    }
}

enum LocalModelSettingsStore {
    static let providerEnabledKey = "astra.localModel.providerEnabled.v1"
    static let modelDirectoryKey = "astra.localModel.modelDirectory.v1"
    static let modelMetadataKey = "astra.localModel.modelMetadata.v1"
    static let preferredModelKey = "astra.localModel.preferredModel.v1"
    static let maxContextTokensKey = "astra.localModel.maxContextTokens.v1"
    static let maxOutputTokensKey = "astra.localModel.maxOutputTokens.v1"
    static let keepWarmTTLSecondsKey = "astra.localModel.keepWarmTTLSeconds.v1"
    static let persistentHelperEnabledKey = "astra.localModel.persistentHelper.v1"
    static let memoryBudgetGBKey = "astra.localModel.memoryBudgetGB.v1"
    static let experimentalToolsKey = "astra.local-model.experimental-tools"
    static let localAgentMaxTurnsKey = "astra.localModel.localAgent.maxTurns.v1"
    static let localAgentMaxToolCallsKey = "astra.localModel.localAgent.maxToolCalls.v1"
    static let localAgentToolTimeoutSecondsKey = "astra.localModel.localAgent.toolTimeoutSeconds.v1"
    static let defaultMaxContextTokens = 8_192
    static let defaultMaxOutputTokens = 1_024
    static let defaultKeepWarmTTLSeconds = 0
    static let defaultMemoryBudgetGB = 0
    static let defaultLocalAgentMaxTurns = 8
    static let defaultLocalAgentMaxToolCalls = 6
    static let defaultLocalAgentToolTimeoutSeconds = 15
    static var defaultProviderEnabled: Bool { !AppChannel.current.isProduction }

    static let persistedKeys: [String] = [
        providerEnabledKey,
        modelDirectoryKey,
        modelMetadataKey,
        preferredModelKey,
        maxContextTokensKey,
        maxOutputTokensKey,
        keepWarmTTLSecondsKey,
        persistentHelperEnabledKey,
        memoryBudgetGBKey,
        experimentalToolsKey,
        localAgentMaxTurnsKey,
        localAgentMaxToolCallsKey,
        localAgentToolTimeoutSecondsKey,
    ] + LocalAgentToolCapability.allCases.map(\.settingsKey) + [
        LocalModelPerformanceStore.profileKey,
        LocalModelHardwareValidationStore.samplesKey,
        LocalAgentBetaSoakStore.samplesKey,
        LocalModelReleaseCandidateValidationStore.samplesKey
    ]

    static func providerEnabled(
        defaults: UserDefaults = .standard,
        channel: AppChannel = .current
    ) -> Bool {
        guard defaults.object(forKey: providerEnabledKey) != nil else {
            return !channel.isProduction
        }
        return defaults.bool(forKey: providerEnabledKey)
    }

    static func modelDirectory(
        providerHomeDirectory: String = "",
        defaults: UserDefaults = .standard
    ) -> String {
        let providerDirectory = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerDirectory.isEmpty {
            return providerDirectory
        }
        return defaults.string(forKey: modelDirectoryKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func setModelDirectory(_ path: String, defaults: UserDefaults = .standard) {
        setModelDirectory(path, metadata: nil, defaults: defaults)
    }

    static func setModelDirectory(
        _ path: String,
        metadata: LocalModelMetadata?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(path, forKey: modelDirectoryKey)
        if let metadata,
           let data = try? JSONEncoder().encode(metadata) {
            defaults.set(data, forKey: modelMetadataKey)
        } else {
            defaults.removeObject(forKey: modelMetadataKey)
        }
        defaults.set(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) + 1,
                     forKey: AppStorageKeys.runtimeProviderSettingsRevision)
    }

    static func selectedModelMetadata(defaults: UserDefaults = .standard) -> LocalModelMetadata? {
        guard let data = defaults.data(forKey: modelMetadataKey) else { return nil }
        return try? JSONDecoder().decode(LocalModelMetadata.self, from: data)
    }

    static func preferredModel(defaults: UserDefaults = .standard) -> String {
        let configured = defaults.string(forKey: preferredModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty else { return LocalMLXRuntime.defaultModel }
        return configured
    }

    static func maxContextTokens(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: maxContextTokensKey)
        guard configured > 0 else { return defaultMaxContextTokens }
        return min(max(configured, 1_024), 65_536)
    }

    static func maxOutputTokens(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: maxOutputTokensKey)
        guard configured > 0 else { return defaultMaxOutputTokens }
        return min(max(configured, 128), 8_192)
    }

    static func keepWarmTTLSeconds(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: keepWarmTTLSecondsKey)
        return min(max(configured, 0), 3_600)
    }

    /// When enabled, the Local Agent loop drives one long-lived `serve` helper that keeps the
    /// model resident across turns (instead of spawning a fresh single-shot helper per turn).
    /// Defaults OFF so the proven single-shot path stays the safe default until validated.
    static func persistentHelperEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: persistentHelperEnabledKey) != nil else { return false }
        return defaults.bool(forKey: persistentHelperEnabledKey)
    }

    static func memoryBudgetOverrideGB(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: memoryBudgetGBKey)
        return min(max(configured, 0), 128)
    }

    static func memoryBudgetOverrideBytes(defaults: UserDefaults = .standard) -> UInt64? {
        let configuredGB = memoryBudgetOverrideGB(defaults: defaults)
        guard configuredGB > 0 else { return nil }
        return UInt64(configuredGB) * LocalModelMemoryBudget.gib
    }

    static func experimentalToolsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: experimentalToolsKey)
    }

    static func localAgentMaxTurns(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: localAgentMaxTurnsKey)
        guard configured > 0 else { return defaultLocalAgentMaxTurns }
        return min(max(configured, 1), 32)
    }

    static func localAgentMaxToolCalls(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: localAgentMaxToolCallsKey)
        guard configured > 0 else { return defaultLocalAgentMaxToolCalls }
        return min(max(configured, 1), 50)
    }

    static func localAgentToolTimeoutSeconds(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: localAgentToolTimeoutSecondsKey)
        guard configured > 0 else { return defaultLocalAgentToolTimeoutSeconds }
        return min(max(configured, 5), 120)
    }

    static func localAgentToolCapabilities(defaults: UserDefaults = .standard) -> LocalAgentToolCapabilities {
        LocalAgentToolCapabilities.current(defaults: defaults)
    }
}

struct LocalModelPerformanceProfile: Codable, Equatable, Sendable {
    var model: String
    var backend: String
    var checkedAt: Date
    var isAppleSilicon: Bool
    var physicalMemoryBytes: UInt64
    var chipClass: String
    var inputTokens: Int?
    var outputTokens: Int?
    var durationMs: Int?
    var firstTokenLatencyMs: Int?
    var tokensPerSecond: Double?

    init(
        model: String,
        backend: String,
        checkedAt: Date = Date(),
        hardware: LocalHardwareProfile = .current(),
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        durationMs: Int? = nil,
        firstTokenLatencyMs: Int? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.model = model
        self.backend = backend
        self.checkedAt = checkedAt
        self.isAppleSilicon = hardware.isAppleSilicon
        self.physicalMemoryBytes = hardware.physicalMemoryBytes
        self.chipClass = hardware.chipClass
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.firstTokenLatencyMs = firstTokenLatencyMs
        self.tokensPerSecond = tokensPerSecond
    }

    init(report: LocalModelSmokeReport, checkedAt: Date = Date()) {
        self.init(
            model: report.model ?? LocalMLXRuntime.defaultModel,
            backend: report.backend,
            checkedAt: checkedAt,
            inputTokens: report.inputTokens,
            outputTokens: report.outputTokens,
            durationMs: report.durationMs,
            firstTokenLatencyMs: report.firstTokenLatencyMs,
            tokensPerSecond: report.tokensPerSecond
        )
    }
}

enum LocalModelPerformanceStore {
    static let profileKey = "astra.localModel.performanceProfile.v1"

    static func profile(defaults: UserDefaults = .standard) -> LocalModelPerformanceProfile? {
        profile(raw: defaults.string(forKey: profileKey) ?? "")
    }

    static func profile(raw: String) -> LocalModelPerformanceProfile? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LocalModelPerformanceProfile.self, from: data)
    }

    static func record(_ profile: LocalModelPerformanceProfile, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: profileKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: profileKey)
    }
}

enum LocalModelValidationMode: String, Codable, Equatable, Sendable {
    case localChat = "local_chat"
    case localAgentReadOnly = "local_agent_read_only"
    case localAgentBeta = "local_agent_beta"
}

enum LocalModelSustainedValidationOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case blockedAsExpected = "blocked_as_expected"
}

enum LocalModelHardwareValidationTier: String, CaseIterable, Codable, Equatable, Sendable {
    case lowMemory8GB = "low_memory_8gb"
    case base16GB = "base_16gb"
    case pro32GBPlus = "pro_32gb_plus"
    case max32GBPlus = "max_32gb_plus"

    var displayName: String {
        switch self {
        case .lowMemory8GB:
            "8 GB class"
        case .base16GB:
            "16 GB base-class"
        case .pro32GBPlus:
            "32 GB+ Pro-class"
        case .max32GBPlus:
            "32 GB+ Max/Ultra-class"
        }
    }

    var evidenceOutputPath: String {
        switch self {
        case .lowMemory8GB:
            return "/tmp/astra-local-mlx-hardware-8gb.json"
        case .base16GB:
            return "/tmp/astra-local-mlx-hardware-16gb.json"
        case .pro32GBPlus:
            return "/tmp/astra-local-mlx-hardware-pro.json"
        case .max32GBPlus:
            return "/tmp/astra-local-mlx-hardware-max.json"
        }
    }

    var collectionCommand: String {
        "script/local_mlx_collect_hardware_evidence.sh --require-tier \(rawValue) --out \(evidenceOutputPath)"
    }
}

struct LocalModelSustainedValidationSample: Codable, Equatable, Sendable {
    var profile: LocalModelPerformanceProfile
    var mode: LocalModelValidationMode
    var outcome: LocalModelSustainedValidationOutcome
    var iterations: Int
    var durationSeconds: Int
    var notes: String

    init(
        profile: LocalModelPerformanceProfile,
        mode: LocalModelValidationMode,
        outcome: LocalModelSustainedValidationOutcome,
        iterations: Int,
        durationSeconds: Int,
        notes: String = ""
    ) {
        self.profile = profile
        self.mode = mode
        self.outcome = outcome
        self.iterations = max(0, iterations)
        self.durationSeconds = max(0, durationSeconds)
        self.notes = notes
    }
}

struct LocalModelHardwareValidationReport: Equatable, Sendable {
    var requiredTiers: [LocalModelHardwareValidationTier]
    var coveredTiers: [LocalModelHardwareValidationTier]
    var missingTiers: [LocalModelHardwareValidationTier]
    var nonCoveringSamples: [LocalModelSustainedValidationSample]
    var samples: [LocalModelSustainedValidationSample]

    var isCompleteForGA: Bool {
        missingTiers.isEmpty
    }

    var summary: String {
        guard !missingTiers.isEmpty else {
            return "Sustained local-model validation covers all required Mac tiers."
        }
        return "Missing sustained local-model validation for: \(missingTiers.map(\.displayName).joined(separator: ", "))."
    }

    var nonCoveringSummary: String {
        guard !nonCoveringSamples.isEmpty else {
            return "All imported hardware samples satisfy Gate D evidence rules."
        }
        return "\(nonCoveringSamples.count) hardware sample(s) do not count for Gate D. Passed hardware samples must run at least \(LocalModelHardwareValidationMatrix.minimumSustainedIterations) iterations with \(LocalMLXRuntime.recommendedModelRepository) and include MLX backend, token counts, duration, first-token latency, and throughput."
    }
}

struct LocalModelHardwareValidationEvidenceBundle: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var samples: [LocalModelSustainedValidationSample]

    init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        samples: [LocalModelSustainedValidationSample]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.samples = samples
    }
}

struct LocalModelHardwareValidationMergeResult: Equatable, Sendable {
    var importedCount: Int
    var skippedCount: Int
    var report: LocalModelHardwareValidationReport
}

enum LocalModelHardwareValidationExchangeError: Error, Equatable, LocalizedError {
    case noSamples
    case unsupportedSchema(Int)
    case invalidPayload
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "Run validation on this Mac before copying hardware evidence."
        case .unsupportedSchema(let version):
            return "This validation evidence uses an unsupported format version: \(version)."
        case .invalidPayload:
            return "The clipboard does not contain valid Local MLX validation evidence."
        case .encodeFailed:
            return "ASTRA could not prepare the validation evidence."
        }
    }
}

enum LocalModelHardwareValidationMatrix {
    static let minimumSustainedIterations = 3

    static let requiredTiers: [LocalModelHardwareValidationTier] = [
        .pro32GBPlus,
    ]

    static func tier(for profile: LocalModelPerformanceProfile) -> LocalModelHardwareValidationTier? {
        hardwareTier(
            isAppleSilicon: profile.isAppleSilicon,
            physicalMemoryBytes: profile.physicalMemoryBytes,
            chipClass: profile.chipClass
        )
    }

    static func tier(for hardware: LocalHardwareProfile) -> LocalModelHardwareValidationTier? {
        hardwareTier(
            isAppleSilicon: hardware.isAppleSilicon,
            physicalMemoryBytes: hardware.physicalMemoryBytes,
            chipClass: hardware.chipClass
        )
    }

    static func report(samples: [LocalModelSustainedValidationSample]) -> LocalModelHardwareValidationReport {
        let covered = requiredTiers.filter { requiredTier in
            samples.contains { sampleCovers($0, tier: requiredTier) }
        }
        let missing = requiredTiers.filter { !covered.contains($0) }
        let requiredSet = Set(requiredTiers)
        let nonCovering = samples.filter { sample in
            guard let tier = Self.tier(for: sample.profile) else { return true }
            guard requiredSet.contains(tier) else { return false }
            return !sampleCovers(sample, tier: tier)
        }
        return LocalModelHardwareValidationReport(
            requiredTiers: requiredTiers,
            coveredTiers: covered,
            missingTiers: missing,
            nonCoveringSamples: nonCovering,
            samples: samples
        )
    }

    private static func sampleCovers(
        _ sample: LocalModelSustainedValidationSample,
        tier: LocalModelHardwareValidationTier
    ) -> Bool {
        guard Self.tier(for: sample.profile) == tier else { return false }
        switch (tier, sample.outcome) {
        case (.lowMemory8GB, .blockedAsExpected):
            return true
        case (_, .passed):
            return sample.iterations >= minimumSustainedIterations
                && sample.durationSeconds > 0
                && sample.profile.model.trimmingCharacters(in: .whitespacesAndNewlines) == LocalMLXRuntime.recommendedModelRepository
                && sample.profile.backend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mlx"
                && (sample.profile.inputTokens ?? 0) > 0
                && (sample.profile.outputTokens ?? 0) > 0
                && (sample.profile.durationMs ?? 0) > 0
                && (sample.profile.firstTokenLatencyMs ?? 0) > 0
                && (sample.profile.tokensPerSecond ?? 0) > 0
        default:
            return false
        }
    }

    private static func hardwareTier(
        isAppleSilicon: Bool,
        physicalMemoryBytes: UInt64,
        chipClass: String
    ) -> LocalModelHardwareValidationTier? {
        guard isAppleSilicon else { return nil }
        let memoryGB = Double(physicalMemoryBytes) / Double(LocalModelMemoryBudget.gib)
        if memoryGB < 12 {
            return .lowMemory8GB
        }
        if memoryGB < 24 {
            return .base16GB
        }
        switch chipClass {
        case "max", "ultra":
            return .max32GBPlus
        case "pro":
            return .pro32GBPlus
        default:
            return .base16GB
        }
    }
}

enum LocalModelHardwareValidationStore {
    static let samplesKey = "astra.localModel.hardwareValidationSamples.v1"
    static let evidenceOutputEnvironmentKey = "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_OUT"

    static func samples(defaults: UserDefaults = .standard) -> [LocalModelSustainedValidationSample] {
        guard let data = defaults.data(forKey: samplesKey),
              let samples = try? JSONDecoder().decode([LocalModelSustainedValidationSample].self, from: data) else {
            return []
        }
        return deduplicated(samples)
    }

    static func record(
        _ sample: LocalModelSustainedValidationSample,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 64
    ) {
        var stored = samples(defaults: defaults)
        stored.append(sample)
        save(stored, defaults: defaults, maxSamples: maxSamples)
    }

    static func exportEvidence(
        defaults: UserDefaults = .standard,
        exportedAt: Date = Date()
    ) throws -> String {
        let stored = samples(defaults: defaults)
        guard !stored.isEmpty else {
            throw LocalModelHardwareValidationExchangeError.noSamples
        }
        let bundle = LocalModelHardwareValidationEvidenceBundle(
            exportedAt: exportedAt,
            samples: stored
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle),
              let payload = String(data: data, encoding: .utf8) else {
            throw LocalModelHardwareValidationExchangeError.encodeFailed
        }
        return payload
    }

    static func mergeEvidence(
        _ payload: String,
        defaults: UserDefaults = .standard,
        maxSamples: Int = 64
    ) throws -> LocalModelHardwareValidationMergeResult {
        guard let data = LocalModelEvidencePayloadExtractor.jsonData(in: payload) else {
            throw LocalModelHardwareValidationExchangeError.invalidPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(LocalModelHardwareValidationEvidenceBundle.self, from: data) else {
            throw LocalModelHardwareValidationExchangeError.invalidPayload
        }
        guard bundle.schemaVersion == 1 else {
            throw LocalModelHardwareValidationExchangeError.unsupportedSchema(bundle.schemaVersion)
        }
        var stored = samples(defaults: defaults)
        var imported = 0
        var skipped = 0
        for sample in bundle.samples {
            let key = hardwareEvidenceKey(for: sample)
            if let existingIndex = stored.firstIndex(where: { hardwareEvidenceKey(for: $0) == key }) {
                if stored[existingIndex] == sample {
                    skipped += 1
                } else {
                    stored[existingIndex] = sample
                    imported += 1
                }
            } else {
                stored.append(sample)
                imported += 1
            }
        }
        save(stored, defaults: defaults, maxSamples: maxSamples)
        return LocalModelHardwareValidationMergeResult(
            importedCount: imported,
            skippedCount: skipped,
            report: report(defaults: defaults)
        )
    }

    private static func save(
        _ samples: [LocalModelSustainedValidationSample],
        defaults: UserDefaults,
        maxSamples: Int
    ) {
        var stored = deduplicated(samples)
        if stored.count > maxSamples {
            stored.removeFirst(stored.count - maxSamples)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: samplesKey)
    }

    static func report(defaults: UserDefaults = .standard) -> LocalModelHardwareValidationReport {
        LocalModelHardwareValidationMatrix.report(samples: samples(defaults: defaults))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: samplesKey)
    }

    private static func deduplicated(
        _ samples: [LocalModelSustainedValidationSample]
    ) -> [LocalModelSustainedValidationSample] {
        var unique: [LocalModelSustainedValidationSample] = []
        for sample in samples {
            let key = hardwareEvidenceKey(for: sample)
            if let index = unique.firstIndex(where: { hardwareEvidenceKey(for: $0) == key }) {
                unique[index] = sample
            } else {
                unique.append(sample)
            }
        }
        return unique
    }

    private static func hardwareEvidenceKey(for sample: LocalModelSustainedValidationSample) -> String {
        let tier = LocalModelHardwareValidationMatrix.tier(for: sample.profile)?.rawValue ?? "unknown"
        return [
            tier,
            sample.mode.rawValue,
            sample.profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
            sample.profile.backend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "\u{1F}")
    }
}

struct LocalModelSustainedValidationRun: Equatable, Sendable {
    var check: RuntimeReadinessCheck
    var hardwareReport: LocalModelHardwareValidationReport
}

struct LocalModelSustainedValidationService {
    private let runner: BinaryRunner
    private let timeout: TimeInterval
    private let detectExecutable: @Sendable (String) -> String
    private let isExecutable: @Sendable (String) -> Bool
    private let hardwareProfile: @Sendable () -> LocalHardwareProfile
    private let now: @Sendable () -> Date

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        timeout: TimeInterval = 180,
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimePathResolver.detectExecutablePath(named: $0)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        hardwareProfile: @escaping @Sendable () -> LocalHardwareProfile = {
            LocalHardwareProfile.current()
        },
        now: @escaping @Sendable () -> Date = {
            Date()
        }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
        self.isExecutable = isExecutable
        self.hardwareProfile = hardwareProfile
        self.now = now
    }

    func run(
        configuration: RuntimeReadinessConfiguration,
        mode: LocalModelValidationMode,
        iterations requestedIterations: Int = 3,
        defaults: UserDefaults = .standard
    ) async -> LocalModelSustainedValidationRun {
        let hardware = hardwareProfile()
        let model = LocalModelSettingsStore.preferredModel(defaults: defaults)

        guard LocalModelSettingsStore.providerEnabled(defaults: defaults) else {
            return result(
                check: RuntimeReadinessCheck(
                    id: "local-mlx-sustained-validation",
                    title: "Local validation run",
                    detail: "Private Local Chat is off for this ASTRA channel.",
                    state: .blocked,
                    remediation: "Turn on Private Local Chat before validating this Mac."
                ),
                defaults: defaults
            )
        }

        if hardware.tier == .unsupported8GB || !hardware.isAppleSilicon {
            let sample = LocalModelSustainedValidationSample(
                profile: LocalModelPerformanceProfile(
                    model: model,
                    backend: "mlx",
                    checkedAt: now(),
                    hardware: hardware
                ),
                mode: mode,
                outcome: .blockedAsExpected,
                iterations: 0,
                durationSeconds: 0,
                notes: "Blocked by local hardware policy before model launch."
            )
            LocalModelHardwareValidationStore.record(sample, defaults: defaults)
            return result(
                check: RuntimeReadinessCheck(
                    id: "local-mlx-sustained-validation",
                    title: "Local validation run",
                    detail: "ASTRA recorded that this Mac is below the local model memory target.",
                    state: .warning,
                    remediation: "Use 16 GB or larger Apple Silicon for Private Local Chat, and 32 GB or larger for Local Agent beta."
                ),
                defaults: defaults
            )
        }

        let configuredExecutable = configuration.executablePath(for: .localMLX)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configuredExecutable.isEmpty
            ? detectExecutable(LocalMLXRuntime.executableName)
            : configuredExecutable
        guard !executable.isEmpty, isExecutable(executable) else {
            return result(
                check: RuntimeReadinessCheck(
                    id: "local-mlx-sustained-validation",
                    title: "Local validation run",
                    detail: "ASTRA local model support was not found.",
                    state: .blocked,
                    remediation: "Update or reinstall ASTRA, then run readiness again."
                ),
                defaults: defaults
            )
        }

        let modelDirectory = LocalModelSettingsStore.modelDirectory(
            providerHomeDirectory: configuration.providerSettings.homeDirectory(for: .localMLX),
            defaults: defaults
        )
        let validation = LocalModelCatalog.validate(directory: modelDirectory)
        guard validation.state == .ready else {
            return result(
                check: RuntimeReadinessCheck(
                    id: "local-mlx-sustained-validation",
                    title: "Local validation run",
                    detail: validation.detail,
                    state: .blocked,
                    remediation: validation.remediation
                ),
                defaults: defaults
            )
        }

        let iterations = max(1, min(requestedIterations, 10))
        let startedAt = now()
        var lastReport: LocalModelSmokeReport?
        var completedIterations = 0

        for _ in 0..<iterations {
            let smokeRun = await runner.run(
                path: executable,
                args: smokeArguments(
                    modelDirectory: modelDirectory,
                    model: model,
                    metadata: validation.metadata,
                    hardware: hardware,
                    defaults: defaults
                ),
                timeout: timeout
            )
            guard smokeRun.isSuccess,
                  let report = LocalModelSmokeReportCodec.decode(stdout: smokeRun.stdout),
                  report.status == "ok" else {
                let failedProfile = profile(
                    report: LocalModelSmokeReportCodec.decode(stdout: smokeRun.stdout),
                    model: model,
                    hardware: hardware
                )
                LocalModelHardwareValidationStore.record(LocalModelSustainedValidationSample(
                    profile: failedProfile,
                    mode: mode,
                    outcome: .failed,
                    iterations: completedIterations,
                    durationSeconds: durationSeconds(since: startedAt),
                    notes: failureDetail(smokeRun)
                ), defaults: defaults)
                return result(
                    check: RuntimeReadinessCheck(
                        id: "local-mlx-sustained-validation",
                        title: "Local validation run",
                        detail: failureDetail(smokeRun),
                        state: .blocked,
                        remediation: "Choose a different installed model or lower the context limit, then validate this Mac again."
                    ),
                    defaults: defaults
                )
            }
            completedIterations += 1
            lastReport = report
        }

        let profile = profile(report: lastReport, model: model, hardware: hardware)
        LocalModelPerformanceStore.record(profile, defaults: defaults)
        LocalModelHardwareValidationStore.record(LocalModelSustainedValidationSample(
            profile: profile,
            mode: mode,
            outcome: .passed,
            iterations: completedIterations,
            durationSeconds: durationSeconds(since: startedAt),
            notes: "Validated repeated local completions on this Mac."
        ), defaults: defaults)

        let report = LocalModelHardwareValidationStore.report(defaults: defaults)
        return LocalModelSustainedValidationRun(
            check: RuntimeReadinessCheck(
                id: "local-mlx-sustained-validation",
                title: "Local validation run",
                detail: successDetail(iterations: completedIterations, profile: profile),
                state: report.isCompleteForGA ? .ready : .warning,
                remediation: report.isCompleteForGA ? nil : report.summary
            ),
            hardwareReport: report
        )
    }

    private func result(
        check: RuntimeReadinessCheck,
        defaults: UserDefaults
    ) -> LocalModelSustainedValidationRun {
        LocalModelSustainedValidationRun(
            check: check,
            hardwareReport: LocalModelHardwareValidationStore.report(defaults: defaults)
        )
    }

    private func smokeArguments(
        modelDirectory: String,
        model: String,
        metadata: LocalModelMetadata?,
        hardware: LocalHardwareProfile,
        defaults: UserDefaults
    ) -> [String] {
        var args = [
            "--smoke",
            "--model-dir", modelDirectory,
            "--model", model,
            "--max-context-tokens", String(LocalModelSettingsStore.maxContextTokens(defaults: defaults)),
            "--max-output-tokens", String(min(16, max(1, LocalModelSettingsStore.maxOutputTokens(defaults: defaults))))
        ]
        if let metadata {
            let budget = LocalModelMemoryBudget.effectiveBudgetBytes(
                for: hardware,
                configuredBudgetBytes: LocalModelSettingsStore.memoryBudgetOverrideBytes(defaults: defaults)
            )
            if budget > 0 {
                args += [
                    "--memory-budget-bytes", String(budget),
                    "--cache-limit-bytes", String(LocalModelMemoryBudget.cacheLimitBytes(forBudget: budget))
                ]
            }
            let estimate = LocalModelMemoryBudget.estimatedResidentBytes(
                metadata: metadata,
                maxContextTokens: LocalModelSettingsStore.maxContextTokens(defaults: defaults)
            )
            args += ["--estimated-memory-bytes", String(estimate)]
        }
        return args
    }

    private func profile(
        report: LocalModelSmokeReport?,
        model: String,
        hardware: LocalHardwareProfile
    ) -> LocalModelPerformanceProfile {
        LocalModelPerformanceProfile(
            model: report?.model ?? model,
            backend: report?.backend ?? "mlx",
            checkedAt: now(),
            hardware: hardware,
            inputTokens: report?.inputTokens,
            outputTokens: report?.outputTokens,
            durationMs: report?.durationMs,
            firstTokenLatencyMs: report?.firstTokenLatencyMs,
            tokensPerSecond: report?.tokensPerSecond
        )
    }

    private func durationSeconds(since start: Date) -> Int {
        max(1, Int(now().timeIntervalSince(start)))
    }

    private func successDetail(iterations: Int, profile: LocalModelPerformanceProfile) -> String {
        let firstToken = profile.firstTokenLatencyMs.map { "\($0)ms first token" } ?? "unknown first token"
        let throughput = profile.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "unknown throughput"
        return "Completed \(iterations) local response checks on this Mac (\(throughput), \(firstToken))."
    }

    private func failureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .timedOut:
            return "Timed out while validating the selected local model."
        case .cancelled:
            return "Local model validation was cancelled."
        case .launchFailed(let reason):
            return "Could not start local validation: \(RuntimeReadinessRedactor.redacted(reason))"
        case .exited(let code):
            if let report = LocalModelSmokeReportCodec.decode(stdout: result.stdout),
               let message = report.message {
                return "Validation stopped with status \(code): \(message)"
            }
            let evidence = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let sanitized = RuntimeReadinessRedactor.redacted(evidence)
            return sanitized.isEmpty
                ? "Validation stopped with status \(code)."
                : "Validation stopped with status \(code): \(String(sanitized.prefix(140)))"
        }
    }
}

enum LocalModelSmokeReportCodec {
    static func decode(stdout: String) -> LocalModelSmokeReport? {
        LocalModelJSONReportCodec.decodeLast(LocalModelSmokeReport.self, from: stdout)
    }
}

enum LocalModelJSONReportCodec {
    static func decodeLast<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        guard let data = output.data(using: .utf8) else { return nil }
        return objectCandidates(in: data)
            .compactMap { try? JSONDecoder().decode(type, from: $0) }
            .last
    }

    private static func objectCandidates(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var candidates: [Data] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x7b else {
                index += 1
                continue
            }

            var depth = 0
            var inString = false
            var escaped = false
            var cursor = index
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5c {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                } else {
                    if byte == 0x22 {
                        inString = true
                    } else if byte == 0x7b {
                        depth += 1
                    } else if byte == 0x7d {
                        depth -= 1
                        if depth == 0 {
                            candidates.append(Data(bytes[index...cursor]))
                            break
                        }
                    }
                }
                cursor += 1
            }
            index += 1
        }
        return candidates
    }
}

enum LocalModelValidationState: Equatable, Sendable {
    case ready
    case warning
    case blocked
}

struct LocalModelValidationReport: Equatable, Sendable {
    var state: LocalModelValidationState
    var detail: String
    var remediation: String?
    var metadata: LocalModelMetadata? = nil
}

struct LocalModelCatalogEntry: Identifiable, Equatable, Sendable {
    var id: String { directory }
    var directory: String
    var displayName: String
    var report: LocalModelValidationReport
}

struct LocalModelInstallCandidate: Identifiable, Equatable, Sendable {
    var id: String { repository }
    var title: String
    var subtitle: String
    var reason: String
    var repository: String
    var localDirectory: String
    var estimatedSize: String
    var estimatedBytes: UInt64
    var runtimeModel: String

    init(
        title: String,
        subtitle: String = "",
        reason: String = "",
        repository: String,
        localDirectory: String,
        estimatedSize: String,
        estimatedBytes: UInt64,
        runtimeModel: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.reason = reason
        self.repository = repository
        self.localDirectory = localDirectory
        self.estimatedSize = estimatedSize
        self.estimatedBytes = estimatedBytes
        self.runtimeModel = runtimeModel
    }

    var consentMessage: String {
        "ASTRA will download \(title) from Hugging Face (\(estimatedSize)), save it in ASTRA's LocalModels folder, validate it, and select it for Private Local Chat. Source: \(repository)."
    }

    var downloadCommand: String {
        LocalMLXRuntime.downloadCommand(repository: repository, localDirectory: localDirectory)
    }

    static var recommended4Bit: LocalModelInstallCandidate {
        LocalModelInstallCandidate(
            title: "Qwen 3 4B",
            subtitle: "Recommended first install. Verified for private local runs in ASTRA.",
            reason: "Best starting point for most Macs: lower memory use, quick setup, and good structured answers.",
            repository: LocalMLXRuntime.recommendedModelRepository,
            localDirectory: LocalMLXRuntime.recommendedModelDirectory,
            estimatedSize: "about 2.1 GB",
            estimatedBytes: 2_100_000_000,
            runtimeModel: LocalMLXRuntime.defaultModel
        )
    }

    static var qwen4Bit: LocalModelInstallCandidate {
        recommended4Bit
    }

    static var qwen8Bit: LocalModelInstallCandidate {
        LocalModelInstallCandidate(
            title: "Qwen 3 8B",
            subtitle: "Larger alternative for stronger coding and reasoning.",
            reason: "Choose this on Macs with more memory when answer quality matters more than speed.",
            repository: "Qwen/Qwen3-8B-MLX-4bit",
            localDirectory: LocalMLXRuntime.recommendedModelDirectory(for: "Qwen/Qwen3-8B-MLX-4bit"),
            estimatedSize: "about 4.1 GB",
            estimatedBytes: 4_100_000_000,
            runtimeModel: "Qwen/Qwen3-8B-MLX-4bit"
        )
    }

    static var llamaSmall: LocalModelInstallCandidate {
        LocalModelInstallCandidate(
            title: "Llama 3.2 3B",
            subtitle: "Smallest option for lighter local runs.",
            reason: "Choose this for lower-memory Macs or quick private drafts when smaller is more important than depth.",
            repository: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            localDirectory: LocalMLXRuntime.recommendedModelDirectory(for: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
            estimatedSize: "about 1.8 GB",
            estimatedBytes: 1_800_000_000,
            runtimeModel: "mlx-community/Llama-3.2-3B-Instruct-4bit"
        )
    }

    static var installCandidates: [LocalModelInstallCandidate] {
        [.recommended4Bit, .qwen8Bit, .llamaSmall]
    }

    static func recommendedCandidate(for hardware: LocalHardwareProfile) -> LocalModelInstallCandidate {
        switch hardware.tier {
        case .unsupported8GB:
            llamaSmall
        case .minimum16GB, .recommended32GBPlus:
            recommended4Bit
        }
    }

    static func installCandidates(for hardware: LocalHardwareProfile) -> [LocalModelInstallCandidate] {
        switch hardware.tier {
        case .unsupported8GB:
            [llamaSmall, recommended4Bit, qwen8Bit]
        case .minimum16GB:
            [recommended4Bit, llamaSmall, qwen8Bit]
        case .recommended32GBPlus:
            installCandidates
        }
    }
}

enum LocalModelInstallChoices {
    static func selectableRuntimeModels(
        preferredModel: String,
        candidates: [LocalModelInstallCandidate] = LocalModelInstallCandidate.installCandidates,
        fileManager: FileManager = .default
    ) -> [String] {
        var choices: [String] = []
        for candidate in candidates {
            guard LocalModelCatalog.validate(
                directory: candidate.localDirectory,
                fileManager: fileManager
            ).state != .blocked else {
                continue
            }
            if !choices.contains(candidate.runtimeModel) {
                choices.append(candidate.runtimeModel)
            }
        }

        let current = preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !isUnsupportedPreferredModel(current), !choices.contains(current) {
            choices.append(current)
        }
        if choices.isEmpty {
            choices.append(LocalMLXRuntime.defaultModel)
        }
        return choices
    }

    private static func isUnsupportedPreferredModel(_: String) -> Bool {
        return false
    }
}

enum LocalModelSelectionSummary {
    static func summary(
        directory rawDirectory: String,
        candidates: [LocalModelInstallCandidate] = LocalModelInstallCandidate.installCandidates,
        fileManager: FileManager = .default
    ) -> String {
        let directory = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            return "No local model selected yet."
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Selected model folder is missing. Install a model or choose another folder."
        }

        let report = LocalModelCatalog.validate(directory: directory, fileManager: fileManager)
        guard report.state != .blocked else {
            return "Selected model folder needs attention: \(report.detail)"
        }

        let standardized = standardizedDirectory(directory)
        if let candidate = candidates.first(where: {
            standardizedDirectory($0.localDirectory) == standardized
        }) {
            return "\(candidate.title) selected."
        }
        let folderName = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
        return folderName.isEmpty ? "\(directory) selected." : "\(folderName) selected."
    }

    private static func standardizedDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

struct LocalModelInstallResult: Equatable, Sendable {
    var candidate: LocalModelInstallCandidate
    var validationReport: LocalModelValidationReport
}

struct LocalModelInstallProgress: Equatable, Sendable {
    var downloadedBytes: UInt64
    var estimatedBytes: UInt64

    var fractionCompleted: Double? {
        guard estimatedBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(estimatedBytes))
    }
}

struct LocalModelAvailabilityService {
    var runner: any BinaryRunner = ProcessBinaryRunner()
    var detectExecutable: @Sendable (String) -> String = { RuntimePathResolver.detectExecutablePath(named: $0) }
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func refreshAndPersist(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let configuredPath = configuration.executablePath(for: .localMLX)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configuredPath.isEmpty
            ? detectExecutable(LocalMLXRuntime.executableName)
            : configuredPath
        guard !executable.isEmpty, isExecutable(executable) else {
            return persistInstallableSuggestions(
                detail: "Install a local model to populate available model choices.",
                remediation: "Install the recommended model from Settings."
            )
        }

        var args = [
            "--list-models",
            "--models-root", LocalMLXRuntime.recommendedModelsRoot
        ]
        let selectedDirectory = LocalModelSettingsStore.modelDirectory(
            providerHomeDirectory: configuration.providerSettings.homeDirectory(for: .localMLX)
        )
        if !selectedDirectory.isEmpty {
            args.append(contentsOf: ["--model-dir", selectedDirectory])
        }

        let result = await runner.run(path: executable, args: args, timeout: 5, environment: nil)
        guard result.isSuccess else {
            return persistInstallableSuggestions(
                detail: "Using installable model recommendations until ASTRA can read the installed local models.",
                remediation: modelListFailureDetail(result)
            )
        }
        guard let report = decodeModelListReport(result.stdout) else {
            return persistInstallableSuggestions(
                detail: "Using installable model recommendations until ASTRA can read the installed local models.",
                remediation: "Run readiness again. If this repeats, update or reinstall ASTRA."
            )
        }

        let models = uniqueModels(report.models.map(\.model))
        guard !models.isEmpty else {
            return persistInstallableSuggestions(
                detail: "No local models are installed yet.",
                remediation: "Install one model from Settings before using Local MLX."
            )
        }

        RuntimeModelAvailability.persistAvailableModels(models, for: .localMLX, authority: .authoritative)
        return RuntimeReadinessCheck(
            id: "local-mlx-models",
            title: "Installed local models",
            detail: "Available: \(models.joined(separator: ", "))",
            state: .ready,
            remediation: nil
        )
    }

    private func persistInstallableSuggestions(detail: String, remediation: String?) -> RuntimeReadinessCheck {
        RuntimeModelAvailability.persistAvailableModels(
            LocalMLXRuntime.defaultModels,
            for: .localMLX,
            authority: .suggestions
        )
        return RuntimeReadinessCheck(
            id: "local-mlx-models",
            title: "Installed local models",
            detail: detail,
            state: .warning,
            remediation: remediation
        )
    }

    private func decodeModelListReport(_ output: String) -> LocalModelListReport? {
        LocalModelJSONReportCodec.decodeLast(LocalModelListReport.self, from: output)
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        return unique
    }

    private func modelListFailureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .launchFailed(let reason):
            return "Could not start local model support: \(RuntimeReadinessRedactor.redacted(reason))"
        case .timedOut:
            return "ASTRA timed out while reading installed local models."
        case .cancelled:
            return "Reading installed local models was cancelled."
        case .exited(let code):
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let trimmed = evidence
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "ASTRA could not read installed local models. Status \(code)."
                : "ASTRA could not read installed local models. Status \(code): \(RuntimeReadinessRedactor.redacted(trimmed))"
        }
    }
}

enum LocalModelInstallerError: LocalizedError, Equatable {
    case pythonLaunchFailed(String)
    case timedOut
    case cancelled
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case downloadFailed(code: Int32, evidence: String)
    case validationFailed(LocalModelValidationReport)

    var errorDescription: String? {
        switch self {
        case .pythonLaunchFailed(let reason):
            return "Could not start Python to install the local model: \(reason)"
        case .timedOut:
            return "Timed out while downloading the local model."
        case .cancelled:
            return "Cancelled local model install. Partial files were removed."
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            return "Not enough free disk space to install this local model. ASTRA needs about \(Self.formatBytes(requiredBytes)) free, but this Mac has about \(Self.formatBytes(availableBytes)) free."
        case .downloadFailed(let code, let evidence):
            return evidence.isEmpty
                ? "Model download failed with exit code \(code)."
                : "Model download failed with exit code \(code): \(evidence)"
        case .validationFailed(let report):
            return report.remediation.map { "\(report.detail) \($0)" } ?? report.detail
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

struct LocalModelInstaller {
    static let pythonExecutable = "/usr/bin/python3"
    static let timeout: TimeInterval = 7_200

    var runner: any BinaryRunner = ProcessBinaryRunner()
    var defaults: UserDefaults = .standard
    var fileManager: FileManager = .default
    var availableDiskSpace: @Sendable (String) -> UInt64? = { path in
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.uint64Value
    }
    var validateModelDirectory: (String, FileManager) -> LocalModelValidationReport = {
        LocalModelCatalog.validate(directory: $0, fileManager: $1)
    }

    func install(
        candidate: LocalModelInstallCandidate,
        progress: (@Sendable (LocalModelInstallProgress) async -> Void)? = nil
    ) async throws -> LocalModelInstallResult {
        let finalParentDirectory = URL(fileURLWithPath: candidate.localDirectory, isDirectory: true)
            .standardizedFileURL
            .deletingLastPathComponent()
            .path
        try fileManager.createDirectory(
            atPath: finalParentDirectory,
            withIntermediateDirectories: true
        )
        try ensureEnoughDiskSpace(for: candidate)
        let stagingDirectory = Self.stagingDirectory(for: candidate)
        try removeItemIfExists(atPath: stagingDirectory)
        let installedValidation: LocalModelValidationReport

        do {
            try Self.throwIfCancelled()
            let progressTask = startProgressMonitor(
                stagingDirectory: stagingDirectory,
                estimatedBytes: candidate.estimatedBytes,
                progress: progress
            )
            let result = await runner.run(
                path: Self.pythonExecutable,
                args: Self.installArguments(for: candidate),
                timeout: Self.timeout,
                environment: nil
            )
            progressTask?.cancel()
            _ = await progressTask?.result
            try Self.throwIfCancelled()
            try Self.throwIfInstallFailed(result)

            let stagingValidation = validateModelDirectory(stagingDirectory, fileManager)
            try Self.throwIfCancelled()
            guard stagingValidation.state != .blocked else {
                throw LocalModelInstallerError.validationFailed(stagingValidation)
            }

            let validation = try replaceInstalledModel(
                stagingDirectory: stagingDirectory,
                finalDirectory: candidate.localDirectory
            ) {
                let finalValidation = validateModelDirectory(candidate.localDirectory, fileManager)
                guard finalValidation.state != .blocked else {
                    throw LocalModelInstallerError.validationFailed(finalValidation)
                }
                return finalValidation
            }

            if let progress {
                await progress(LocalModelInstallProgress(
                    downloadedBytes: candidate.estimatedBytes,
                    estimatedBytes: candidate.estimatedBytes
                ))
            }
            LocalModelSettingsStore.setModelDirectory(
                candidate.localDirectory,
                metadata: validation.metadata,
                defaults: defaults
            )
            installedValidation = validation
        } catch {
            try? removeItemIfExists(atPath: stagingDirectory)
            throw error
        }
        defaults.set(candidate.runtimeModel, forKey: LocalModelSettingsStore.preferredModelKey)
        RuntimeProviderSettingsStore.setHomeDirectory(candidate.localDirectory, for: .localMLX, defaults: defaults)

        return LocalModelInstallResult(candidate: candidate, validationReport: installedValidation)
    }

    static func requiredFreeBytes(for candidate: LocalModelInstallCandidate) -> UInt64 {
        guard candidate.estimatedBytes > 0 else { return 0 }
        let installBuffer = candidate.estimatedBytes / 4
        let minimumScratch: UInt64 = 512 * 1024 * 1024
        let required = candidate.estimatedBytes.addingReportingOverflow(max(installBuffer, minimumScratch))
        return required.overflow ? UInt64.max : required.partialValue
    }

    private func ensureEnoughDiskSpace(for candidate: LocalModelInstallCandidate) throws {
        let requiredBytes = Self.requiredFreeBytes(for: candidate)
        guard requiredBytes > 0,
              let availableBytes = availableDiskSpace(Self.diskSpaceCheckPath(for: candidate)) else {
            return
        }
        guard availableBytes >= requiredBytes else {
            throw LocalModelInstallerError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    static func diskSpaceCheckPath(for candidate: LocalModelInstallCandidate) -> String {
        URL(fileURLWithPath: candidate.localDirectory, isDirectory: true)
            .standardizedFileURL
            .deletingLastPathComponent()
            .path
    }

    static func installArguments(for candidate: LocalModelInstallCandidate) -> [String] {
        ["-c", installScript, candidate.repository, stagingDirectory(for: candidate)]
    }

    static func stagingDirectory(for candidate: LocalModelInstallCandidate) -> String {
        let finalURL = URL(fileURLWithPath: candidate.localDirectory, isDirectory: true).standardizedFileURL
        return finalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent("\(finalURL.lastPathComponent).partial", isDirectory: true)
            .path
    }

    private func replaceInstalledModel(
        stagingDirectory: String,
        finalDirectory: String,
        validateFinal: () throws -> LocalModelValidationReport
    ) throws -> LocalModelValidationReport {
        let stagingURL = URL(fileURLWithPath: stagingDirectory, isDirectory: true)
        let finalURL = URL(fileURLWithPath: finalDirectory, isDirectory: true)
        let parentURL = finalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let backupURL = parentURL.appendingPathComponent(".\(finalURL.lastPathComponent).previous-\(UUID().uuidString)", isDirectory: true)
        var hadPreviousInstall = false
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.moveItem(at: finalURL, to: backupURL)
            hadPreviousInstall = true
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            let validation = try validateFinal()
            if hadPreviousInstall {
                try? fileManager.removeItem(at: backupURL)
            }
            return validation
        } catch {
            if fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
            }
            if hadPreviousInstall, !fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.moveItem(at: backupURL, to: finalURL)
            }
            throw error
        }
    }

    private func removeItemIfExists(atPath path: String) throws {
        guard fileManager.fileExists(atPath: path) else { return }
        try fileManager.removeItem(atPath: path)
    }

    private func startProgressMonitor(
        stagingDirectory: String,
        estimatedBytes: UInt64,
        progress: (@Sendable (LocalModelInstallProgress) async -> Void)?
    ) -> Task<Void, Never>? {
        guard let progress else { return nil }
        let fileManager = fileManager
        return Task {
            while !Task.isCancelled {
                let downloadedBytes = Self.directorySize(
                    atPath: stagingDirectory,
                    fileManager: fileManager
                )
                await progress(LocalModelInstallProgress(
                    downloadedBytes: downloadedBytes,
                    estimatedBytes: estimatedBytes
                ))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func directorySize(atPath path: String, fileManager: FileManager = .default) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .isRegularFileKey
            ]),
                values.isRegularFile == true else {
                continue
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            if size > 0 {
                total += UInt64(size)
            }
        }
        return total
    }

    private static func throwIfInstallFailed(_ result: RunResult) throws {
        switch result.outcome {
        case .exited(code: 0):
            return
        case .launchFailed(let reason):
            throw LocalModelInstallerError.pythonLaunchFailed(reason)
        case .timedOut:
            throw LocalModelInstallerError.timedOut
        case .cancelled:
            throw LocalModelInstallerError.cancelled
        case .exited(let code):
            throw LocalModelInstallerError.downloadFailed(
                code: code,
                evidence: sanitizedEvidence(stdout: result.stdout, stderr: result.stderr)
            )
        }
    }

    private static func throwIfCancelled() throws {
        if Task.isCancelled {
            throw LocalModelInstallerError.cancelled
        }
    }

    private static func sanitizedEvidence(stdout: String, stderr: String) -> String {
        let evidence = stderr.isEmpty ? stdout : stderr
        return evidence
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(220)
            .description
    }

    private static let installScript = """
    import importlib.util
    import inspect
    import os
    import subprocess
    import sys

    repo_id = sys.argv[1]
    local_dir = sys.argv[2]
    os.makedirs(os.path.dirname(local_dir), exist_ok=True)
    if importlib.util.find_spec("huggingface_hub") is None or importlib.util.find_spec("hf_xet") is None:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "-U", "huggingface_hub[hf_xet]"])
    from huggingface_hub import snapshot_download
    allow_patterns = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "merges.txt",
        "vocab.json",
        "*.tiktoken",
        "*.safetensors",
        "*.safetensors.index.json",
        "model*.bin",
        "pytorch_model*.bin",
    ]
    kwargs = {
        "repo_id": repo_id,
        "local_dir": local_dir,
        "allow_patterns": allow_patterns,
    }
    if "resume_download" in inspect.signature(snapshot_download).parameters:
        kwargs["resume_download"] = True
    snapshot_download(**kwargs)
    """
}

struct LocalModelMetadata: Codable, Equatable, Sendable {
    var directory: String
    var modelType: String
    var architectures: [String]
    var quantizationMethod: String?
    var weightFileCount: Int
    var weightBytes: UInt64
    var hiddenSize: Int?
    var layerCount: Int?
    var attentionHeadCount: Int?
    var keyValueHeadCount: Int?
    var hasVisionConfig: Bool? = nil
    var hasPerLayerEmbeddings: Bool? = nil

    var normalizedModelType: String {
        modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var primaryArchitecture: String {
        architectures.first ?? "unknown"
    }

    func estimatedKVCacheBytes(maxContextTokens: Int) -> UInt64? {
        guard maxContextTokens > 0,
              let hiddenSize,
              let layerCount,
              let attentionHeadCount,
              attentionHeadCount > 0 else {
            return nil
        }
        let kvHeads = max(1, keyValueHeadCount ?? attentionHeadCount)
        let headDimension = max(1, hiddenSize / attentionHeadCount)
        let bytesPerScalar = 2
        let kvBytes = UInt64(maxContextTokens)
            * UInt64(layerCount)
            * UInt64(kvHeads)
            * UInt64(headDimension)
            * UInt64(2)
            * UInt64(bytesPerScalar)
        return kvBytes
    }
}

enum LocalModelCatalog {
    static func scan(
        roots: [String],
        maxDepth: Int = 1,
        fileManager: FileManager = .default
    ) -> [LocalModelCatalogEntry] {
        var entries: [LocalModelCatalogEntry] = []
        var seen: Set<String> = []
        for root in roots.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !root.isEmpty {
            scan(directory: root, remainingDepth: maxDepth, seen: &seen, entries: &entries, fileManager: fileManager)
        }
        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func importModel(
        directory path: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> LocalModelValidationReport {
        let report = validate(directory: path, fileManager: fileManager)
        guard report.state != .blocked else {
            return report
        }
        LocalModelSettingsStore.setModelDirectory(path, metadata: report.metadata, defaults: defaults)
        return report
    }

    static func validate(directory path: String, fileManager: FileManager = .default) -> LocalModelValidationReport {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "No local model folder is selected.",
                remediation: "Install the recommended local model from Runtime settings, or select an existing MLX folder with config, tokenizer, and weight files."
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected local model folder does not exist.",
                remediation: "Choose a local MLX model folder that ASTRA can read."
            )
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        if containsGGUF(contents: contents) && !containsMLXAssets(contents: contents) {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected folder contains GGUF files, not MLX model assets.",
                remediation: "Download an MLX safetensors model such as \(LocalMLXRuntime.recommendedModelRepository) into \(LocalMLXRuntime.recommendedModelsRoot), then select that model folder."
            )
        }

        var missing: [String] = []
        if !contents.contains("config.json") {
            missing.append("config.json")
        }
        if !contents.contains("tokenizer.json") && !contents.contains("tokenizer.model") {
            missing.append("tokenizer.json or tokenizer.model")
        }
        let weightSummary = weightSummary(contents: contents, directory: path, fileManager: fileManager)
        if weightSummary.fileCount == 0 {
            missing.append("model weights (.safetensors or .bin)")
        }

        guard missing.isEmpty else {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model folder is missing \(missing.joined(separator: ", ")).",
                remediation: "Import a complete MLX-compatible model directory."
            )
        }

        guard weightSummary.bytes > 0 else {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model folder has weight files, but they are empty.",
                remediation: "Import a complete MLX-compatible model directory with non-empty weight shards."
            )
        }

        let parsedMetadata: LocalModelMetadata
        do {
            parsedMetadata = try metadata(
                directory: path,
                contents: contents,
                weightFileCount: weightSummary.fileCount,
                weightBytes: weightSummary.bytes,
                fileManager: fileManager
            )
        } catch {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model config is incomplete: \(error.localizedDescription)",
                remediation: "Use a model folder with a config.json that declares a supported model_type."
            )
        }

        if LocalModelArchitectureSupport.isGemma4Unified(modelType: parsedMetadata.modelType) {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model folder is \(parsedMetadata.primaryArchitecture), but Gemma 4 Unified MLX folders are not supported by the current Local MLX provider.",
                remediation: "Use the recommended Qwen MLX model for local text tasks, or choose a Gemma 4 MLX folder that reports model_type 'gemma4' or 'gemma4_text'."
            )
        }

        if parsedMetadata.hasVisionConfig == true,
           !LocalModelArchitectureSupport.supportsImageInputs(modelType: parsedMetadata.modelType) {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model folder is a multimodal MLX conversion, but its model type '\(parsedMetadata.modelType)' is not supported by the current Local MLX provider.",
                remediation: "Choose a supported Gemma 4 MLX multimodal folder or install the recommended Qwen text model from Settings."
            )
        }

        guard LocalModelArchitectureSupport.isSupported(modelType: parsedMetadata.modelType) else {
            return LocalModelValidationReport(
                state: .blocked,
                detail: "Selected model folder is installed but unsupported: model type '\(parsedMetadata.modelType)' is not supported by the current Local MLX provider.",
                remediation: "Install the recommended Qwen model from Settings, or choose a supported text-only Qwen, Llama, Mistral, Phi, DeepSeek, or similar MLX model."
            )
        }

        let mediaDetail = parsedMetadata.hasVisionConfig == true
            ? " Multimodal image input is available for this model."
            : ""
        return LocalModelValidationReport(
            state: .ready,
            detail: "Selected model folder is \(parsedMetadata.modelType) (\(parsedMetadata.primaryArchitecture)) with \(parsedMetadata.weightFileCount) weight file(s), \(formatBytes(parsedMetadata.weightBytes)).\(mediaDetail)",
            remediation: nil,
            metadata: parsedMetadata
        )
    }

    static func metadata(directory path: String, fileManager: FileManager = .default) throws -> LocalModelMetadata {
        let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        let weightSummary = weightSummary(contents: contents, directory: path, fileManager: fileManager)
        return try metadata(
            directory: path,
            contents: contents,
            weightFileCount: weightSummary.fileCount,
            weightBytes: weightSummary.bytes,
            fileManager: fileManager
        )
    }

    private static func scan(
        directory path: String,
        remainingDepth: Int,
        seen: inout Set<String>,
        entries: inout [LocalModelCatalogEntry],
        fileManager: FileManager
    ) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !seen.contains(standardized) else { return }
        seen.insert(standardized)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        if looksLikeModelDirectory(standardized, fileManager: fileManager) {
            entries.append(LocalModelCatalogEntry(
                directory: standardized,
                displayName: URL(fileURLWithPath: standardized).lastPathComponent,
                report: validate(directory: standardized, fileManager: fileManager)
            ))
            return
        }

        guard remainingDepth > 0,
              let children = try? fileManager.contentsOfDirectory(atPath: standardized) else {
            return
        }
        for child in children.sorted() {
            guard !child.hasPrefix(".") else { continue }
            let childPath = (standardized as NSString).appendingPathComponent(child)
            scan(
                directory: childPath,
                remainingDepth: remainingDepth - 1,
                seen: &seen,
                entries: &entries,
                fileManager: fileManager
            )
        }
    }

    private static func looksLikeModelDirectory(_ path: String, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return false }
        return contents.contains("config.json")
            || contents.contains("tokenizer.json")
            || contents.contains("tokenizer.model")
            || contents.contains(where: isWeightFile)
    }

    private static func isWeightFile(_ name: String) -> Bool {
        name.hasSuffix(".safetensors") || name.hasSuffix(".bin")
    }

    private static func containsGGUF(contents: [String]) -> Bool {
        contents.contains { $0.lowercased().hasSuffix(".gguf") }
    }

    private static func containsMLXAssets(contents: [String]) -> Bool {
        contents.contains("config.json")
            || contents.contains("tokenizer.json")
            || contents.contains("tokenizer.model")
            || contents.contains(where: isWeightFile)
    }

    private static func weightSummary(
        contents: [String],
        directory: String,
        fileManager: FileManager
    ) -> (fileCount: Int, bytes: UInt64) {
        var count = 0
        var bytes: UInt64 = 0
        for file in contents where isWeightFile(file) {
            count += 1
            let path = (directory as NSString).appendingPathComponent(file)
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
            bytes += size
        }
        return (count, bytes)
    }

    private static func metadata(
        directory path: String,
        contents _: [String],
        weightFileCount: Int,
        weightBytes: UInt64,
        fileManager _: FileManager
    ) throws -> LocalModelMetadata {
        let configURL = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalModelCatalogError.invalidConfig
        }
        guard let modelType = string("model_type", in: object), !modelType.isEmpty else {
            throw LocalModelCatalogError.missingModelType
        }
        return LocalModelMetadata(
            directory: path,
            modelType: modelType,
            architectures: stringArray("architectures", in: object),
            quantizationMethod: nestedString("quantization_config", "quant_method", in: object)
                ?? nestedString("quantization_config", "quant_method_version", in: object)
                ?? nestedString("quantization_config", "mode", in: object)
                ?? nestedString("quantization", "mode", in: object)
                ?? nestedInt("quantization_config", "bits", in: object).map { "\($0)-bit" }
                ?? nestedInt("quantization", "bits", in: object).map { "\($0)-bit" },
            weightFileCount: weightFileCount,
            weightBytes: weightBytes,
            hiddenSize: int("hidden_size", in: object)
                ?? nestedInt("text_config", "hidden_size", in: object),
            layerCount: int("num_hidden_layers", in: object)
                ?? nestedInt("text_config", "num_hidden_layers", in: object)
                ?? int("n_layer", in: object),
            attentionHeadCount: int("num_attention_heads", in: object)
                ?? nestedInt("text_config", "num_attention_heads", in: object)
                ?? int("n_head", in: object),
            keyValueHeadCount: int("num_key_value_heads", in: object)
                ?? nestedInt("text_config", "num_key_value_heads", in: object),
            hasVisionConfig: object["vision_config"] is [String: Any],
            hasPerLayerEmbeddings: nestedInt("text_config", "hidden_size_per_layer_input", in: object) != nil
                || int("hidden_size_per_layer_input", in: object) != nil
        )
    }

    private static func string(_ key: String, in object: [String: Any]) -> String? {
        object[key] as? String
    }

    private static func stringArray(_ key: String, in object: [String: Any]) -> [String] {
        object[key] as? [String] ?? []
    }

    private static func int(_ key: String, in object: [String: Any]) -> Int? {
        if let int = object[key] as? Int { return int }
        if let number = object[key] as? NSNumber { return number.intValue }
        return nil
    }

    private static func nestedString(_ parent: String, _ key: String, in object: [String: Any]) -> String? {
        guard let nested = object[parent] as? [String: Any] else { return nil }
        return nested[key] as? String
    }

    private static func nestedInt(_ parent: String, _ key: String, in object: [String: Any]) -> Int? {
        guard let nested = object[parent] as? [String: Any] else { return nil }
        return int(key, in: nested)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

enum LocalModelCatalogError: LocalizedError {
    case invalidConfig
    case missingModelType

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "config.json is not a JSON object."
        case .missingModelType:
            return "config.json does not declare model_type."
        }
    }
}

enum LocalModelArchitectureSupport {
    private static let supportedModelTypes: Set<String> = [
        "llama",
        "mistral",
        "gemma",
        "gemma2",
        "gemma3",
        "gemma3_text",
        "gemma3n",
        "gemma4",
        "gemma4_text",
        "qwen2",
        "qwen3",
        "qwen3_moe",
        "qwen3_next",
        "qwen3_5",
        "qwen3_5_text",
        "phi",
        "phi3",
        "phimoe",
        "deepseek_v3",
        "glm4",
        "starcoder2",
        "cohere",
        "granite",
        "smollm3",
        "lfm2",
        "olmo2",
        "olmo3",
        "gpt_oss",
        "apertus"
    ]

    static func isSupported(modelType: String) -> Bool {
        supportedModelTypes.contains(modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func supportsImageInputs(modelType: String) -> Bool {
        let normalized = modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "gemma4"
    }

    static func isGemma4Unified(modelType: String) -> Bool {
        modelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gemma4_unified"
    }
}

enum LocalModelGemma4Support {
    static func requires32GBHardware(metadata: LocalModelMetadata) -> Bool {
        let directory = metadata.directory.lowercased()
        let architectures = metadata.architectures.joined(separator: " ").lowercased()
        return metadata.normalizedModelType == "gemma4_unified"
            || directory.contains("gemma-4-12b")
            || directory.contains("gemma4-12b")
            || architectures.contains("gemma4unified")
    }
}

enum LocalHardwareTier: String, Equatable, Sendable {
    case unsupported8GB
    case minimum16GB
    case recommended32GBPlus
}

enum LocalModelMemoryBudget {
    static let gib: UInt64 = 1_073_741_824
    static let mib: UInt64 = 1_048_576

    static func readinessCheck(
        metadata: LocalModelMetadata,
        hardware: LocalHardwareProfile,
        maxContextTokens: Int,
        configuredBudgetBytes: UInt64? = nil
    ) -> RuntimeReadinessCheck {
        if LocalModelGemma4Support.requires32GBHardware(metadata: metadata),
           hardware.tier != .recommended32GBPlus {
            return RuntimeReadinessCheck(
                id: "local-mlx-memory-fit",
                title: "Model memory fit",
                detail: "Gemma 4 12B needs the 32 GB+ Local MLX tier for reliable multimodal runs on Apple Silicon.",
                state: .blocked,
                remediation: "Use a 32 GB+ Mac for Gemma 4 12B, or choose Qwen 3 4B, Qwen 3 8B, or Llama 3.2 3B on this machine."
            )
        }
        let estimate = estimatedResidentBytes(
            metadata: metadata,
            maxContextTokens: maxContextTokens
        )
        let automaticBudget = budgetBytes(for: hardware)
        let budget = effectiveBudgetBytes(
            for: hardware,
            configuredBudgetBytes: configuredBudgetBytes
        )
        let budgetMode = configuredBudgetBytes == nil ? "auto" : "configured"
        let detail = "Estimated local model memory \(LocalModelCatalog.formatBytes(estimate)) for \(maxContextTokens) context tokens; \(budgetMode) budget \(LocalModelCatalog.formatBytes(budget)) (auto ceiling \(LocalModelCatalog.formatBytes(automaticBudget)))."

        if budget == 0 {
            return RuntimeReadinessCheck(
                id: "local-mlx-memory-fit",
                title: "Model memory fit",
                detail: detail,
                state: .blocked,
                remediation: "Use Apple Silicon hardware with at least 16 GB unified memory for local MLX inference."
            )
        }

        if estimate > budget {
            return RuntimeReadinessCheck(
                id: "local-mlx-memory-fit",
                title: "Model memory fit",
                detail: detail,
                state: .blocked,
                remediation: "This installed model is too large for the current memory budget. Choose a smaller quantized model, lower the Local MLX max context setting, or use a Mac with more unified memory."
            )
        }

        if Double(estimate) > Double(budget) * 0.80 {
            return RuntimeReadinessCheck(
                id: "local-mlx-memory-fit",
                title: "Model memory fit",
                detail: detail,
                state: .warning,
                remediation: "This model is close to the conservative memory budget; keep other heavy apps closed and consider a lower context limit."
            )
        }

        return RuntimeReadinessCheck(
            id: "local-mlx-memory-fit",
            title: "Model memory fit",
            detail: detail,
            state: .ready,
            remediation: nil
        )
    }

    static func estimatedResidentBytes(metadata: LocalModelMetadata, maxContextTokens: Int) -> UInt64 {
        let weightsAndScratch = UInt64(Double(metadata.weightBytes) * 1.25)
        let kvCache = metadata.estimatedKVCacheBytes(maxContextTokens: maxContextTokens)
            ?? UInt64(max(1, maxContextTokens)) * 256 * 1_024
        return weightsAndScratch + kvCache + gib
    }

    static func budgetBytes(for hardware: LocalHardwareProfile) -> UInt64 {
        guard hardware.isAppleSilicon else { return 0 }
        switch hardware.tier {
        case .unsupported8GB:
            return 0
        case .minimum16GB:
            return min(8 * gib, UInt64(Double(hardware.physicalMemoryBytes) * 0.45))
        case .recommended32GBPlus:
            return UInt64(Double(hardware.physicalMemoryBytes) * 0.55)
        }
    }

    static func effectiveBudgetBytes(
        for hardware: LocalHardwareProfile,
        configuredBudgetBytes: UInt64?
    ) -> UInt64 {
        let automaticBudget = budgetBytes(for: hardware)
        guard automaticBudget > 0 else { return 0 }
        guard let configuredBudgetBytes, configuredBudgetBytes > 0 else {
            return automaticBudget
        }
        return min(configuredBudgetBytes, automaticBudget)
    }

    static func cacheLimitBytes(forBudget budget: UInt64) -> UInt64 {
        guard budget > 0 else { return 0 }
        return min(2 * gib, max(256 * mib, budget / 8))
    }
}

struct LocalHardwareProfile: Equatable, Sendable {
    var isAppleSilicon: Bool
    var physicalMemoryBytes: UInt64
    var cpuBrand: String

    var tier: LocalHardwareTier {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824
        if gib < 12 { return .unsupported8GB }
        if gib < 24 { return .minimum16GB }
        return .recommended32GBPlus
    }

    var chipClass: String {
        let lower = cpuBrand.lowercased()
        if lower.contains("ultra") { return "ultra" }
        if lower.contains("max") { return "max" }
        if lower.contains("pro") { return "pro" }
        if lower.contains("apple m") { return "base" }
        return "unknown"
    }

    var capacityLabel: String {
        switch tier {
        case .unsupported8GB:
            "8 GB class"
        case .minimum16GB:
            "16 GB minimum"
        case .recommended32GBPlus:
            "32 GB+ recommended"
        }
    }

    var speedLabel: String {
        switch chipClass {
        case "ultra":
            "Ultra-class bandwidth"
        case "max":
            "Max-class bandwidth"
        case "pro":
            "Pro-class bandwidth"
        case "base":
            "Base-chip bandwidth"
        default:
            "Unknown bandwidth"
        }
    }

    var unifiedMemoryDescription: String {
        LocalModelCatalog.formatBytes(physicalMemoryBytes)
    }

    static func current() -> LocalHardwareProfile {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return LocalHardwareProfile(
            isAppleSilicon: appleSilicon,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            cpuBrand: sysctlString("machdep.cpu.brand_string")
        )
    }

    func readinessCheck() -> RuntimeReadinessCheck {
        guard isAppleSilicon else {
            return RuntimeReadinessCheck(
                id: "local-mlx-hardware",
                title: "Apple Silicon hardware",
                detail: "Native MLX inference requires Apple Silicon.",
                state: .blocked,
                remediation: "Use an Apple Silicon Mac for the local MLX provider."
            )
        }

        switch tier {
        case .unsupported8GB:
            return RuntimeReadinessCheck(
                id: "local-mlx-hardware",
                title: "Unified memory",
                detail: "This Mac has less than 12 GiB unified memory; local models are likely to force heavy swap.",
                state: .blocked,
                remediation: "Use a 16 GB or larger Apple Silicon Mac, or keep using cloud/CLI providers."
            )
        case .minimum16GB:
            return RuntimeReadinessCheck(
                id: "local-mlx-hardware",
                title: "Unified memory",
                detail: "16 GB class hardware can run small quantized models with conservative context settings. Chip class: \(chipClass).",
                state: .warning,
                remediation: "Start with the low-footprint model and keep context under \(LocalModelSettingsStore.defaultMaxContextTokens) tokens."
            )
        case .recommended32GBPlus:
            return RuntimeReadinessCheck(
                id: "local-mlx-hardware",
                title: "Unified memory",
                detail: "32 GB+ class hardware is suitable for the curated local model set. Chip class: \(chipClass).",
                state: .ready,
                remediation: nil
            )
        }
    }

    private static func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

enum LocalAgentHardwareSupport {
    static func readinessCheck(hardware: LocalHardwareProfile) -> RuntimeReadinessCheck {
        guard hardware.isAppleSilicon else {
            return RuntimeReadinessCheck(
                id: "local-agent-hardware",
                title: "Local Agent hardware",
                detail: "Local Agent requires an Apple Silicon Mac.",
                state: .blocked,
                remediation: "Use an Apple Silicon Mac, or keep Local Agent tools off and choose a cloud/CLI provider for tool work."
            )
        }

        switch hardware.tier {
        case .unsupported8GB:
            return RuntimeReadinessCheck(
                id: "local-agent-hardware",
                title: "Local Agent hardware",
                detail: "This Mac does not have enough unified memory for Local Agent tool loops.",
                state: .blocked,
                remediation: "Use a 16 GB or larger Apple Silicon Mac for Private Local Chat, and 32 GB or larger for Local Agent beta."
            )
        case .minimum16GB:
            return RuntimeReadinessCheck(
                id: "local-agent-hardware",
                title: "Local Agent hardware",
                detail: "This Mac can try small Local Agent tasks, but 32 GB or more is the supported beta target.",
                state: .warning,
                remediation: "Keep context and tool limits low, use the smallest installed model, and close other heavy apps before running Local Agent."
            )
        case .recommended32GBPlus:
            return RuntimeReadinessCheck(
                id: "local-agent-hardware",
                title: "Local Agent hardware",
                detail: "This Mac meets the Local Agent beta hardware target.",
                state: .ready,
                remediation: nil
            )
        }
    }
}

struct LocalMLXRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "local-mlx"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [LocalMLXRuntimeAdapter()]
    }
}

enum LocalModelRunBudgetResolver {
    static func memoryBudgetBytes(modelDirectory: String) -> Int? {
        guard !modelDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let report = LocalModelCatalog.validate(directory: modelDirectory)
        guard report.metadata != nil else { return nil }
        let hardware = LocalHardwareProfile.current()
        let budget = LocalModelMemoryBudget.effectiveBudgetBytes(
            for: hardware,
            configuredBudgetBytes: LocalModelSettingsStore.memoryBudgetOverrideBytes()
        )
        guard budget > 0 else { return nil }
        return intClamped(budget)
    }

    static func cacheLimitBytes(modelDirectory: String) -> Int? {
        guard let budget = memoryBudgetBytes(modelDirectory: modelDirectory), budget > 0 else { return nil }
        return intClamped(LocalModelMemoryBudget.cacheLimitBytes(forBudget: UInt64(budget)))
    }

    private static func intClamped(_ value: UInt64) -> Int {
        let maxValue = UInt64(Int.max)
        return Int(min(value, maxValue))
    }
}

enum LocalModelInputMedia {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic"
    ]

    static func imageAttachments(
        prompt: String,
        taskInputs: [String],
        fileManager: FileManager = .default
    ) -> [LocalModelMediaAttachment] {
        var attachments: [LocalModelMediaAttachment] = []
        var seen: Set<String> = []

        func append(path rawPath: String, source: String) {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let path = (trimmed as NSString).expandingTildeInPath
            guard isImagePath(path), fileManager.fileExists(atPath: path) else { return }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { return }
            attachments.append(.image(
                path: standardized,
                source: source,
                mimeType: mimeType(for: standardized)
            ))
        }

        for input in taskInputs {
            append(path: input, source: "task_input")
        }
        for path in attachedFilePaths(in: prompt) {
            append(path: path, source: "composer_attachment")
        }

        return attachments
    }

    static func attachingImages(
        from inputs: [String],
        to messages: [LocalModelChatMessage],
        fileManager: FileManager = .default
    ) -> [LocalModelChatMessage] {
        let attachments = imageAttachments(prompt: "", taskInputs: inputs, fileManager: fileManager)
        guard !attachments.isEmpty,
              let userIndex = messages.indices.last(where: {
                  messages[$0].role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
              }) else {
            return messages
        }
        var updated = messages
        updated[userIndex].attachments.append(contentsOf: attachments)
        return updated
    }

    private static func attachedFilePaths(in prompt: String) -> [String] {
        prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("- ") else { return nil }
                let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }
                return path
            }
    }

    private static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func mimeType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "tiff", "tif":
            return "image/tiff"
        case "bmp":
            return "image/bmp"
        case "heic":
            return "image/heic"
        default:
            return nil
        }
    }
}

struct LocalMLXRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .localMLX,
        displayName: "Local MLX",
        executableName: LocalMLXRuntime.executableName,
        installHint: "Update or reinstall ASTRA so local model support is restored.",
        authHint: "No account is required. Install a local model or select one on this Mac.",
        defaultModel: LocalMLXRuntime.defaultModel,
        defaultModels: LocalMLXRuntime.defaultModels,
        supportsAstraRunProtocol: true,
        executionCapabilities: .textOnly
    )
    let readinessCheckID = "local-mlx-helper"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .localMLX, launchOverheadTokens: 0)
    let modelAvailabilityAuthority: RuntimeModelAvailabilityAuthority = .authoritative

    func policyAdapter(runtimeCapabilities _: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        LocalModelPolicyAdapter()
    }

    func providerConfigOwnership(workspacePath _: String) -> PolicyConfigOwnership {
        .generated
    }

    func existingProviderConfigSummary(workspacePath _: String) -> String? {
        nil
    }

    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport {
        guard LocalModelSettingsStore.providerEnabled() else {
            return RuntimeReadinessReport(checks: [
                RuntimeReadinessCheck(
                    id: "local-mlx-rollout-gate",
                    title: "Local provider rollout gate",
                    detail: "Local MLX is disabled for this ASTRA channel.",
                    state: .blocked,
                    remediation: "Enable the Local MLX provider setting in a development or beta build while this runtime is under validation."
                )
            ])
        }

        let executable = probes.resolvedExecutable(
            configuredPath: configuration.executablePath(for: id),
            binary: descriptor.executableName
        )
        let helper = await probes.checkExecutable(
            id: readinessCheckID,
            title: "Local model support",
            executable: executable,
            args: ["--version"],
            missingDetail: "ASTRA local model support was not found.",
            installHint: descriptor.installHint
        )
        let modelDirectory = LocalModelSettingsStore.modelDirectory(
            providerHomeDirectory: configuration.providerSettings.homeDirectory(for: id)
        )
        let modelReport = LocalModelCatalog.validate(directory: modelDirectory)
        let hardware = LocalHardwareProfile.current()

        var checks = [
            helper.check,
            hardware.readinessCheck(),
            RuntimeReadinessCheck(
                id: "local-mlx-model-folder",
                title: "Local model folder",
                detail: modelReport.detail,
                state: readinessState(from: modelReport.state),
                remediation: modelReport.remediation
            )
        ]
        if LocalModelSettingsStore.experimentalToolsEnabled() {
            checks.append(LocalAgentHardwareSupport.readinessCheck(hardware: hardware))
        }
        if let metadata = modelReport.metadata {
            checks.append(LocalModelMemoryBudget.readinessCheck(
                metadata: metadata,
                hardware: hardware,
                maxContextTokens: LocalModelSettingsStore.maxContextTokens(),
                configuredBudgetBytes: LocalModelSettingsStore.memoryBudgetOverrideBytes()
            ))
        }
        if helper.isReady, let executable = helper.executable {
            let backend = await backendCheck(executable: executable, probes: probes)
            checks.append(backend)
            if backend.state == .ready,
               modelReport.state == .ready {
                checks.append(await smokeCheck(
                    executable: executable,
                    modelDirectory: modelDirectory,
                    model: LocalModelSettingsStore.preferredModel(),
                    probes: probes
                ))
            }
        }
        return RuntimeReadinessReport(checks: checks)
    }

    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        await LocalModelAvailabilityService().refreshAndPersist(configuration: configuration)
    }

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? LocalMLXRuntime.detectPath() : configuredPath,
            homeDirectory: LocalModelSettingsStore.modelDirectory(
                providerHomeDirectory: configuration.homeDirectory(for: id)
            )
        )
    }

    func missingExecutableAuditReason() -> String {
        "local_model_helper_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "local_helper_missing"
    }

    func missingExecutableMessage(executablePath: String) -> String {
        "ASTRA could not start Local MLX from '\(executablePath)'. Update or reinstall ASTRA, then run readiness again."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "Local MLX started working on: \(task.goal)"
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: context.task)
        let runtimeDirectory = requestDirectory(for: context.task)
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let modelDirectory = LocalModelSettingsStore.modelDirectory(
            providerHomeDirectory: context.providerHomeDirectory
        )
        let requestPath = writeRequest(
            prompt: context.prompt,
            model: model,
            modelDirectory: modelDirectory,
            permissionPolicy: context.executionPolicy.permissionPolicy(default: context.permissionPolicy),
            directory: runtimeDirectory,
            imageAttachments: LocalModelInputMedia.imageAttachments(
                prompt: context.prompt,
                taskInputs: context.task.inputs
            )
        )
        var environment = taskEnv
        environment["ASTRA_LOCAL_MODEL_PROTOCOL_FD"] = String(LocalMLXRuntime.protocolFileDescriptor)
        environment["ASTRA_LOCAL_MODEL_CONTROL_FD"] = String(LocalMLXRuntime.controlFileDescriptor)
        environment["ASTRA_LOCAL_MODEL_PROVIDER_ENABLED"] = LocalModelSettingsStore.providerEnabled() ? "1" : "0"
        environment["ASTRA_LOCAL_MODEL_EXPERIMENTAL_TOOLS"] = LocalModelSettingsStore.experimentalToolsEnabled() ? "1" : "0"
        environment["ASTRA_LOCAL_AGENT_CAPABILITIES"] = LocalModelSettingsStore.localAgentToolCapabilities().enabledSummary

        return AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: context.executablePath.isEmpty ? LocalMLXRuntime.detectPath() : context.executablePath,
            arguments: ["run", "--request-file", requestPath],
            currentDirectory: context.workspacePath,
            environment: AgentRuntimeProcessRunner.environment(
                phase: "run",
                task: context.task,
                taskEnv: environment,
                includeClaudeTeamFlag: false
            ),
            browserShimDirectory: nil,
            providerVersion: nil,
            eventStream: .fileDescriptor(LocalMLXRuntime.protocolFileDescriptor),
            controlStream: .fileDescriptor(LocalMLXRuntime.controlFileDescriptor),
            parsesJSONLines: true,
            directoriesToCreate: [runtimeDirectory],
            providerDetectedFields: [
                "runtime": id.rawValue,
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: context.executablePath)),
                "executable_path": context.executablePath,
                "event_stream": "fd\(LocalMLXRuntime.protocolFileDescriptor)",
                "control_stream": "fd\(LocalMLXRuntime.controlFileDescriptor)",
                "model_directory_configured": String(!modelDirectory.isEmpty)
            ],
            commandPlannedFields: [
                "runtime": id.rawValue,
                "phase": "run",
                "model": model,
                "provider_model": model,
                "permission_policy": context.executionPolicy.permissionPolicy(default: context.permissionPolicy).rawValue,
                "parses_json_lines": "true",
                "event_stream": "fd\(LocalMLXRuntime.protocolFileDescriptor)",
                "control_stream": "fd\(LocalMLXRuntime.controlFileDescriptor)",
                "experimental_tools_enabled": String(LocalModelSettingsStore.experimentalToolsEnabled()),
                "max_context_tokens": String(LocalModelSettingsStore.maxContextTokens()),
                "max_output_tokens": String(LocalModelSettingsStore.maxOutputTokens()),
                "keep_warm_ttl_seconds": String(LocalModelSettingsStore.keepWarmTTLSeconds()),
                "memory_budget_gb": String(LocalModelSettingsStore.memoryBudgetOverrideGB()),
                "local_agent_max_turns": String(LocalModelSettingsStore.localAgentMaxTurns()),
                "local_agent_max_tool_calls": String(LocalModelSettingsStore.localAgentMaxToolCalls()),
                "local_agent_tool_timeout_seconds": String(LocalModelSettingsStore.localAgentToolTimeoutSeconds()),
                "local_agent_capabilities": LocalModelSettingsStore.localAgentToolCapabilities().enabledSummary,
                "task_env_count": String(taskEnv.count)
            ]
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines _: Bool) -> [ParsedEvent] {
        LocalModelProtocolParser.agentEvents(from: line).compactMap(AgentEventRecorder.parsedEvent)
    }

    func blockingProcessPermissionMessage(line _: String, parsesJSONLines _: Bool) -> String? {
        nil
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines _: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: LocalModelProtocolParser.agentEvents(from: line))
    }

    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent] {
        guard case .agent(let agentEvent) = event else { return [] }
        return pipeline.process(agentEvent).map(AgentRuntimeRecordedEvent.agent)
    }

    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: pipeline.flushAgentEvents())
    }

    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode _: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .agent(let agentEvent) = event else { return }
        AgentEventRecorder.recordLocalModelEvent(
            agentEvent,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    @MainActor
    func recordPostProcessEvents(context: AgentRuntimePostProcessContext) {
        let output = context.run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        context.onEvent(.result(
            text: output,
            costUSD: nil,
            totalInputTokens: context.run.inputTokens,
            totalOutputTokens: context.run.outputTokens,
            durationMs: nil,
            numTurns: nil,
            isError: false
        ))
    }

    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent? {
        guard let agentEvent = event.agentEvent else { return nil }
        return AgentEventRecorder.parsedEvent(from: agentEvent)
    }

    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode _: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty ? LocalMLXRuntime.detectPath() : configuredPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return AgentUtilityRunResult(
                exitCode: -1,
                output: "",
                error: "ASTRA could not start Local MLX utility prompts. Update or reinstall ASTRA, then run readiness again."
            )
        }

        let model = AgentRuntimeProcessRunner.model(configuration.model, for: id)
        let modelDirectory = LocalModelSettingsStore.modelDirectory(
            providerHomeDirectory: configuration.homeDirectory(for: id)
        )
        let requestDirectory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("astra-local-model-utility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: requestDirectory) }
        let requestPath = writeUtilityRequest(
            prompt: prompt,
            model: model,
            modelDirectory: modelDirectory,
            directory: requestDirectory
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["run", "--request-file", requestPath]
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        process.environment = localUtilityEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        let parsed = parseUtilityOutput(result.stdout)
        let error = parsed.errors.isEmpty ? result.stderr : (result.stderr + "\n" + parsed.errors.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentUtilityRunResult(
            exitCode: result.exitCode,
            output: parsed.output,
            error: error
        )
    }

    private func readinessState(from state: LocalModelValidationState) -> RuntimeReadinessState {
        switch state {
        case .ready: .ready
        case .warning: .warning
        case .blocked: .blocked
        }
    }

    private func backendCheck(executable: String, probes: RuntimeReadinessProbeContext) async -> RuntimeReadinessCheck {
        let result = await probes.run(path: executable, args: ["--health"])
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "local-mlx-backend",
                title: "Local model engine",
                detail: "ASTRA could not verify local model support.",
                state: .blocked,
                remediation: "Update or reinstall ASTRA, then run readiness again."
            )
        }
        if result.stdout.contains(#""backend":"mlx""#) {
            return RuntimeReadinessCheck(
                id: "local-mlx-backend",
                title: "Local model engine",
                detail: "Local model support is ready.",
                state: .ready,
                remediation: nil
            )
        }
        return RuntimeReadinessCheck(
            id: "local-mlx-backend",
            title: "Local model engine",
            detail: "This ASTRA build does not include working local model support.",
            state: .blocked,
            remediation: "Update or reinstall ASTRA. Local models cannot run from this build."
        )
    }

    private func smokeCheck(
        executable: String,
        modelDirectory: String,
        model: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(
            path: executable,
            args: [
                "--smoke",
                "--model-dir", modelDirectory,
                "--model", model,
                "--max-context-tokens", String(LocalModelSettingsStore.maxContextTokens()),
                "--max-output-tokens", "1"
            ],
            timeout: 120
        )
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "local-mlx-smoke",
                title: "Local response test",
                detail: smokeFailureDetail(result),
                state: .blocked,
                remediation: smokeFailureRemediation(result)
            )
        }
        guard let report = LocalModelSmokeReportCodec.decode(stdout: result.stdout),
              report.status == "ok" else {
            return RuntimeReadinessCheck(
                id: "local-mlx-smoke",
                title: "Local response test",
                detail: LocalModelSmokeReportCodec.decode(stdout: result.stdout)?.message ?? "ASTRA could not confirm the selected model can answer.",
                state: .blocked,
                remediation: "Run the Local MLX readiness check again after choosing a complete compatible model folder."
            )
        }
        LocalModelPerformanceStore.record(LocalModelPerformanceProfile(report: report))
        return RuntimeReadinessCheck(
            id: "local-mlx-smoke",
            title: "Local response test",
            detail: smokeSuccessDetail(report),
            state: .ready,
            remediation: nil
        )
    }

    private func smokeSuccessDetail(_ report: LocalModelSmokeReport) -> String {
        let firstToken = report.firstTokenLatencyMs.map { "first token \($0)ms" } ?? "first token unknown"
        let speed = report.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "throughput unknown"
        let duration = report.durationMs.map { "duration \($0)ms" } ?? "duration unknown"
        return "Tiny local completion succeeded (\(firstToken), \(speed), \(duration))."
    }

    private func smokeFailureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .timedOut:
            return "Timed out while loading the local model or generating the first token."
        case .cancelled:
            return "The local model smoke test was cancelled."
        case .launchFailed(let reason):
            return "Could not launch smoke test: \(RuntimeReadinessRedactor.redacted(reason))"
        case .exited(let code):
            let evidence = smokeFailureEvidence(result)
            if smokeFailureLooksLikeMissingMetalLibrary(evidence) {
                return "ASTRA is missing a required local model runtime file."
            }
            if let report = LocalModelSmokeReportCodec.decode(stdout: result.stdout),
               let message = report.message {
                return "Exited with status \(code): \(message)"
            }
            let sanitized = RuntimeReadinessRedactor.redacted(evidence)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitized.isEmpty ? "Exited with status \(code)." : "Exited with status \(code): \(String(sanitized.prefix(140)))"
        }
    }

    private func smokeFailureRemediation(_ result: RunResult) -> String {
        if smokeFailureLooksLikeMissingMetalLibrary(smokeFailureEvidence(result)) {
            return "Update or reinstall ASTRA, then run readiness again. This is an ASTRA packaging issue, not a model setup issue."
        }
        return "Choose a different installed model or lower the context limit. If it still fails, reinstall the model from Settings."
    }

    private func smokeFailureEvidence(_ result: RunResult) -> String {
        [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func smokeFailureLooksLikeMissingMetalLibrary(_ evidence: String) -> Bool {
        let lower = evidence.lowercased()
        return lower.contains("metallib")
            && (lower.contains("library not found")
                || lower.contains("failed to load")
                || lower.contains("missing"))
    }

    @MainActor
    private func requestDirectory(for task: AgentTask) -> String {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let base = taskFolder.isEmpty
            ? NSTemporaryDirectory()
            : taskFolder
        return (base as NSString).appendingPathComponent(".local-model")
    }

    private func writeRequest(
        prompt: String,
        model: String,
        modelDirectory: String,
        permissionPolicy: PermissionPolicy,
        directory: String,
        imageAttachments: [LocalModelMediaAttachment] = []
    ) -> String {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let requestPath = (directory as NSString).appendingPathComponent("request-\(UUID().uuidString).json")
        let request = LocalModelRunRequest(
            prompt: prompt,
            messages: [LocalModelChatMessage(role: "user", content: prompt, attachments: imageAttachments)],
            model: model,
            modelDirectory: modelDirectory.isEmpty ? nil : modelDirectory,
            permissionMode: permissionPolicy.rawValue,
            experimentalToolsEnabled: LocalModelSettingsStore.experimentalToolsEnabled(),
            maxContextTokens: LocalModelSettingsStore.maxContextTokens(),
            maxOutputTokens: LocalModelSettingsStore.maxOutputTokens(),
            memoryBudgetBytes: memoryBudgetBytes(modelDirectory: modelDirectory),
            cacheLimitBytes: cacheLimitBytes(modelDirectory: modelDirectory),
            keepWarmTTLSeconds: LocalModelSettingsStore.keepWarmTTLSeconds()
        )
        if let data = try? JSONEncoder().encode(request) {
            try? data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
        }
        return requestPath
    }

    private func writeUtilityRequest(
        prompt: String,
        model: String,
        modelDirectory: String,
        directory: String
    ) -> String {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let requestPath = (directory as NSString).appendingPathComponent("utility-request-\(UUID().uuidString).json")
        let messages = [
            LocalModelChatMessage(
                role: "system",
                content: "You are ASTRA's Private Local Chat utility. Answer only from the prompt text. Do not claim you used files, shell commands, browser sessions, connectors, credentials, or ASTRA tools."
            ),
            LocalModelChatMessage(role: "user", content: prompt)
        ]
        let request = LocalModelRunRequest(
            prompt: prompt,
            messages: messages,
            model: model,
            modelDirectory: modelDirectory.isEmpty ? nil : modelDirectory,
            permissionMode: PermissionPolicy.restricted.rawValue,
            experimentalToolsEnabled: false,
            maxContextTokens: LocalModelSettingsStore.maxContextTokens(),
            maxOutputTokens: min(LocalModelSettingsStore.maxOutputTokens(), 2_048),
            memoryBudgetBytes: memoryBudgetBytes(modelDirectory: modelDirectory),
            cacheLimitBytes: cacheLimitBytes(modelDirectory: modelDirectory),
            keepWarmTTLSeconds: 0
        )
        if let data = try? JSONEncoder().encode(request) {
            try? data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
        }
        return requestPath
    }

    private func localUtilityEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "ASTRA_LOCAL_MODEL_PROTOCOL_FD": "1",
            "ASTRA_LOCAL_MODEL_PROVIDER_ENABLED": LocalModelSettingsStore.providerEnabled() ? "1" : "0",
            "ASTRA_LOCAL_MODEL_EXPERIMENTAL_TOOLS": "0"
        ]
        for key in ["HOME", "PATH", "TMPDIR"] {
            if let value = parent[key] {
                environment[key] = value
            }
        }
        return environment
    }

    private func parseUtilityOutput(_ output: String) -> (output: String, errors: [String]) {
        var text = ""
        var completion: String?
        var errors: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            for event in LocalModelProtocolParser.agentEvents(from: String(line)) {
                switch event {
                case .text(let chunk):
                    text += chunk
                case .completed(let summary):
                    if let summary, !summary.isEmpty {
                        completion = summary
                    }
                case .failed(let message):
                    errors.append(message)
                default:
                    break
                }
            }
        }
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            return (visible, errors)
        }
        return (completion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", errors)
    }

    private func memoryBudgetBytes(modelDirectory: String) -> Int? {
        LocalModelRunBudgetResolver.memoryBudgetBytes(modelDirectory: modelDirectory)
    }

    private func cacheLimitBytes(modelDirectory: String) -> Int? {
        LocalModelRunBudgetResolver.cacheLimitBytes(modelDirectory: modelDirectory)
    }
}
