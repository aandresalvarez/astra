import Foundation

/// A one-shot model call used by the generator. Injected so tests can feed canned
/// outputs without a real provider; the default binds `AgentUtilityRuntimeRunner`
/// in read-only tool mode (generation must never let the model take actions).
typealias WorkspaceAppStudioPromptRunner = (
    _ prompt: String,
    _ workspacePath: String,
    _ configuration: AgentUtilityRuntimeConfiguration
) async -> AgentUtilityRunResult

/// Outcome of model-backed manifest generation. The manifest is ALWAYS valid and
/// publishable: either a model manifest the validator accepted, or — when the
/// model is unavailable or never produces a valid manifest — the deterministic
/// template, so generation is never worse than today's behavior.
struct WorkspaceAppStudioGenerationResult: Equatable {
    enum Origin: String, Equatable {
        case model                  // valid on the first model attempt
        case modelRepaired          // valid after one or more repair turns
        case deterministicFallback  // model failed/never valid -> deterministic template
    }

    var manifest: WorkspaceAppManifest
    var validationReport: WorkspaceAppManifestValidationReport
    /// True when the kept manifest came from the model (vs. the template fallback).
    var accepted: Bool
    var origin: Origin
    /// Number of model calls actually made (0 when the deterministic path is used
    /// without any provider attempt — currently never, but kept explicit).
    var attemptCount: Int
    /// Human-readable provider failure when a `runPrompt` call errored (degraded).
    var providerFailure: String?

    /// Mirrors `WorkspaceAppStudioDraft.canPublish`: a blockers-only gate. Warnings
    /// never block publishing.
    var canPublish: Bool { validationReport.isValid }
}

/// Model-backed Workspace App manifest generation (App Studio Slice 2).
///
/// Pipeline: deterministic base manifest (fallback + few-shot example) ->
/// model prompt -> `applyStructuredOutput` (decode + authoritative validation) ->
/// validation-report-driven repair loop preserving the last valid manifest ->
/// graceful degradation to the template. Model output is untrusted until the
/// validator accepts it (spec §17.2/§17.3).
enum WorkspaceAppStudioGenerator {
    /// Default runner: the real utility runtime, pinned to read-only tool mode.
    static let defaultRunner: WorkspaceAppStudioPromptRunner = { prompt, workspacePath, configuration in
        await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: configuration,
            toolMode: .readOnly
        )
    }

    static func generate(
        intent rawIntent: String,
        workspaceName: String,
        workspacePath: String,
        existingManifest: WorkspaceAppManifest? = nil,
        maxRepairAttempts: Int = 2,
        configuration: AgentUtilityRuntimeConfiguration = .claude(),
        contractFamilies: [WorkspaceAppContractFamily] = WorkspaceAppContractRegistry().families,
        runner: WorkspaceAppStudioPromptRunner = defaultRunner
    ) async -> WorkspaceAppStudioGenerationResult {
        let intent = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        // The base is BOTH the graceful fallback and the valid example shown to the
        // model. When editing an existing app, that manifest is the base instead.
        let base = existingManifest ?? WorkspaceAppStudioBuilder.baseManifest(intent: intent)
        let baseReport = WorkspaceAppManifestValidator.validate(base)

        func fallback(attempts: Int, providerFailure: String?) -> WorkspaceAppStudioGenerationResult {
            WorkspaceAppStudioGenerationResult(
                manifest: base,
                validationReport: baseReport,
                accepted: false,
                origin: .deterministicFallback,
                attemptCount: attempts,
                providerFailure: providerFailure
            )
        }

        // --- First attempt ---
        let firstPrompt = generationPrompt(
            intent: intent,
            workspaceName: workspaceName,
            base: base,
            contractFamilies: contractFamilies
        )
        let firstResult = await runner(firstPrompt, workspacePath, configuration)
        guard firstResult.exitCode == 0 else {
            return fallback(attempts: 1, providerFailure: firstResult.failureDetail)
        }

        var attempts = 1
        var applied = WorkspaceAppStudioBuilder.applyStructuredOutput(firstResult.output, to: base)
        if applied.accepted {
            return WorkspaceAppStudioGenerationResult(
                manifest: applied.manifest,
                validationReport: applied.validationReport,
                accepted: true,
                origin: .model,
                attemptCount: attempts,
                providerFailure: nil
            )
        }

        // --- Repair loop (spec §17.3): feed validation issues back, preserve last valid ---
        var repairs = 0
        while repairs < maxRepairAttempts {
            repairs += 1
            // `rejectedManifest` is populated only when JSON decoded but failed
            // validation; on a decode/parse error it is nil and the validation
            // report carries the parse error to feed back.
            let rejected = applied.rejectedManifest ?? base
            let prompt = repairPrompt(
                intent: intent,
                rejected: rejected,
                report: applied.validationReport,
                contractFamilies: contractFamilies
            )
            let result = await runner(prompt, workspacePath, configuration)
            attempts += 1
            guard result.exitCode == 0 else {
                return fallback(attempts: attempts, providerFailure: result.failureDetail)
            }
            applied = WorkspaceAppStudioBuilder.applyStructuredOutput(result.output, to: base)
            if applied.accepted {
                return WorkspaceAppStudioGenerationResult(
                    manifest: applied.manifest,
                    validationReport: applied.validationReport,
                    accepted: true,
                    origin: .modelRepaired,
                    attemptCount: attempts,
                    providerFailure: nil
                )
            }
        }

        // Exhausted without a valid model manifest -> deterministic template (valid).
        return fallback(attempts: attempts, providerFailure: nil)
    }

    // MARK: - Prompts (internal for test assertions)

    static func generationPrompt(
        intent: String,
        workspaceName: String,
        base: WorkspaceAppManifest,
        contractFamilies: [WorkspaceAppContractFamily]
    ) -> String {
        """
        You are ASTRA App Studio's manifest generator. Produce ONE Workspace App \
        manifest, as JSON, that fulfills the user's intent for the "\(workspaceName)" workspace.

        USER INTENT:
        "\(intent)"

        Respond with EXACTLY ONE block. Put each marker on its own line with NO \
        markdown fences and NO backticks:

        ASTRA_APP_MANIFEST
        { ...the manifest JSON... }
        END_ASTRA_APP_MANIFEST

        The JSON must decode into this shape:
        - schemaVersion: Int (keep the value from the baseline below)
        - app: { id (lowercase-kebab, no spaces), name, icon (SF Symbol), description, tags: [String], archetypes: [String] }
        - requirements: [ { id, contract, operations: [String], optional: Bool, reason } ]
        - storage (optional): { tables: [ { name, columns: [ { name, type, ... } ] } ] }
        - sources, views, actions, automations: arrays
        - permissions: object

        You may ONLY reference these capability contracts. Use the exact `contract` \
        id and operation names — do NOT invent contracts or operations:
        \(contractCatalog(contractFamilies))

        Rules:
        - Output JSON only inside the block; ASTRA validates it and rejects anything invalid.
        - Keep every automation disabled (enabled = false).
        - Prefer app-owned storage (contract `appStorage.records`) for local data.

        Here is a VALID baseline manifest. Adapt it to the intent — keep its overall \
        structure, change ids/names/fields as needed:

        \(encode(base))
        """
    }

    static func repairPrompt(
        intent: String,
        rejected: WorkspaceAppManifest,
        report: WorkspaceAppManifestValidationReport,
        contractFamilies: [WorkspaceAppContractFamily]
    ) -> String {
        """
        Your previous manifest for the intent "\(intent)" was REJECTED by ASTRA's validator.

        Fix every BLOCKER below (warnings are advisory and do not block):
        \(issueDigest(report))

        The manifest you produced (JSON):
        \(encode(rejected))

        Return a corrected manifest as EXACTLY ONE block, each marker on its own \
        line, NO markdown fences and NO backticks:

        ASTRA_APP_MANIFEST
        { ...the corrected manifest JSON... }
        END_ASTRA_APP_MANIFEST

        You may ONLY reference these capability contracts (exact ids/operations):
        \(contractCatalog(contractFamilies))
        """
    }

    // MARK: - Helpers

    /// Bulleted catalog of the capability contracts the model is allowed to use.
    /// The validator does not (yet) reject references to unknown contract families,
    /// so this list is the primary guard against the model inventing contracts.
    static func contractCatalog(_ families: [WorkspaceAppContractFamily]) -> String {
        families
            .map { family in
                let ops = family.operations.map { "\($0.name) (\($0.effect.rawValue))" }.joined(separator: ", ")
                return "- \(family.id) — \(family.displayName): \(ops)"
            }
            .joined(separator: "\n")
    }

    /// One line per validation issue, e.g. `[BLOCKER] /app/id: App id is required.`
    static func issueDigest(_ report: WorkspaceAppManifestValidationReport) -> String {
        guard !report.issues.isEmpty else { return "(no issues reported)" }
        return report.issues
            .map { "[\($0.severity.rawValue.uppercased())] \($0.path): \($0.message)" }
            .joined(separator: "\n")
    }

    private static func encode(_ manifest: WorkspaceAppManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
