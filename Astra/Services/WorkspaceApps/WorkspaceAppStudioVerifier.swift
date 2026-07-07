import Foundation

/// Grounded post-edit verification: after a turn produces an app, RUN it in the preview sandbox and
/// report whether the change behaves as asked — instead of trusting the model's "Fixed it" summary.
///
/// This is the execution-backed version of a "did the edit land?" check. It deliberately does NOT
/// ask a second model to judge the diff (that shares the generator's blind spot). It combines two
/// grounded signals:
///   - Tier 1 `WorkspaceAppSelfCheck.autoExercise` — free + deterministic: run every declared action
///     once; a structural throw is the strongest negative signal.
///   - Tier 3 `WorkspaceAppScenarioCheckGenerator` — the model AUTHORS an acceptance check from the
///     user's intent, which ASTRA then RUNS for real (rowCount / summaryContains / noErrors). The
///     verdict comes from execution, not the model's imagination.
///
/// Scope + honesty: it verifies the app's GOVERNED data/action layer (the same actions a data-backed
/// HTML app drives through the `astra.*` bridge). It does not click the HTML UI itself, so a pass
/// means "the declared behavior works", not "every pixel is right". Apps with no runnable actions
/// (a pure-UI calculator) are `notApplicable` — there is nothing to execute.
struct WorkspaceAppStudioVerification: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case verified       // an intent-grounded check ran and passed
        case failed         // an action threw, or the intent check ran and failed
        case inconclusive   // actions ran, but no intent check could be authored/run
        case notApplicable  // nothing executable to verify (no actions)
    }

    var status: Status
    /// One-line, user-facing lead.
    var headline: String
    /// A sentence of grounded evidence (the failing action + reason, the row count asserted, etc.).
    var detail: String
    /// Raw signals, kept for the event log / Test panel (nil when not run).
    var autoExercise: WorkspaceAppSelfCheckReport?
    var scenario: WorkspaceAppScenarioCheckResult?

    /// The honest chat line for a turn. Empty for `notApplicable` (the caller suppresses it).
    var chatLine: String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case .verified:
            return trimmedDetail.isEmpty ? headline : "\(headline) \(trimmedDetail)"
        case .failed:
            let evidence = trimmedDetail.isEmpty ? "" : " \(trimmedDetail)"
            return "\(headline)\(evidence) The app is saved — tell me what to fix, or open Test to dig in."
        case .inconclusive:
            return headline
        case .notApplicable:
            return ""
        }
    }
}

enum WorkspaceAppStudioVerifier {
    /// Verify the just-produced `manifest` against the turn's `intent`, in the sandbox.
    /// `scenarioRunner` is injected so tests drive the Tier-3 author step without a provider CLI.
    static func verify(
        intent: String,
        manifest: WorkspaceAppManifest,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        scenarioRunner: WorkspaceAppStudioPromptRunner = WorkspaceAppScenarioCheckGenerator.defaultRunner
    ) async -> WorkspaceAppStudioVerification {
        // Nothing executable to verify (e.g. a pure-UI HTML tool). The surgical-edit + no-op guards
        // already cover "did the UI change"; there's no governed action to run here.
        guard !manifest.actions.isEmpty else {
            return WorkspaceAppStudioVerification(
                status: .notApplicable, headline: "", detail: "", autoExercise: nil, scenario: nil
            )
        }

        // Tier 1 — free, deterministic: run every action once.
        let exercise = WorkspaceAppSelfCheck.autoExercise(manifest: manifest)

        // Tier 3 — intent-grounded: the model authors an acceptance check, ASTRA runs it for real.
        let scenario = await WorkspaceAppScenarioCheckGenerator.generate(
            scenario: intent,
            manifest: manifest,
            workspacePath: workspacePath,
            configuration: configuration,
            runner: scenarioRunner
        )

        return combine(exercise: exercise, scenario: scenario)
    }

    /// Fold the two grounded signals into one verdict. A structural action failure is the strongest
    /// negative; then the intent check's real outcome; otherwise the app ran but the specific change
    /// couldn't be auto-checked (honest "inconclusive", never a false "verified").
    static func combine(
        exercise: WorkspaceAppSelfCheckReport,
        scenario: WorkspaceAppScenarioCheckResult
    ) -> WorkspaceAppStudioVerification {
        if let failed = exercise.results.first(where: { $0.status == .fail }) {
            return WorkspaceAppStudioVerification(
                status: .failed,
                headline: "I ran the app and an action failed.",
                detail: "\(failed.label): \(failed.detail)",
                autoExercise: exercise,
                scenario: scenario
            )
        }
        // A check was authored from the intent AND actually ran at least one step. A step-less check
        // (e.g. `noErrors` over zero steps) is vacuously "pass" and proves nothing about a change —
        // it must NOT read as verified; it falls through to inconclusive below.
        if let check = scenario.check, !check.steps.isEmpty {
            if scenario.result.status == .fail {
                return WorkspaceAppStudioVerification(
                    status: .failed,
                    headline: "I checked your change against what you asked and it didn't hold:",
                    detail: scenario.result.detail,
                    autoExercise: exercise,
                    scenario: scenario
                )
            }
            if scenario.result.status == .pass {
                return WorkspaceAppStudioVerification(
                    status: .verified,
                    headline: "Verified — I ran your change in a sandbox and it behaves as asked.",
                    detail: scenario.result.detail,
                    autoExercise: exercise,
                    scenario: scenario
                )
            }
            // `.warn` is not a clean pass — fall through to the honest "inconclusive" below.
        }
        // No conclusive intent check (unauthorable, step-less, or warn), but the actions all ran.
        let count = exercise.results.count
        return WorkspaceAppStudioVerification(
            status: .inconclusive,
            headline: "I exercised the app's \(count) action\(count == 1 ? "" : "s") and they ran, but couldn't auto-check that specific change.",
            detail: "",
            autoExercise: exercise,
            scenario: scenario
        )
    }
}
