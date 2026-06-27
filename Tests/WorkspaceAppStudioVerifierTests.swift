import Foundation
import Testing
@testable import ASTRA

/// Grounded post-turn verification: after a turn produces an app, RUN it in the sandbox and report
/// whether the change behaves as asked — rather than trusting the model's "Fixed it" summary. These
/// tests pin the verdict-folding logic (pure) and the end-to-end grounded path (a scripted scenario
/// author + the real sandbox runner).
@Suite("Workspace App Studio Verifier (grounded post-turn verification)")
struct WorkspaceAppStudioVerifierTests {
    // MARK: - Fixtures

    private func report(_ statuses: [WorkspaceAppCheckStatus]) -> WorkspaceAppSelfCheckReport {
        WorkspaceAppSelfCheckReport(results: statuses.enumerated().map {
            WorkspaceAppCheckResult(id: "a\($0.offset)", label: "Action \($0.offset)", status: $0.element, detail: "d")
        })
    }

    private func scenario(_ status: WorkspaceAppCheckStatus?, detail: String = "ran", steps: Int = 1) -> WorkspaceAppScenarioCheckResult {
        if let status {
            let stepList = (0..<steps).map { WorkspaceAppCheckStep(actionID: "a\($0)", record: nil) }
            let check = WorkspaceAppCheck(id: "chk", label: "scenario", steps: stepList,
                                          expect: WorkspaceAppCheckExpectation(kind: "noErrors", table: nil, op: nil, value: nil, text: nil, actionID: nil))
            return WorkspaceAppScenarioCheckResult(check: check, result: WorkspaceAppCheckResult(id: "chk", label: "scenario", status: status, detail: detail))
        }
        // check == nil ⇒ the model couldn't author/parse a check.
        return WorkspaceAppScenarioCheckResult(check: nil, result: WorkspaceAppCheckResult(id: "scenario", label: "scenario", status: .fail, detail: "Could not parse a check."))
    }

    // MARK: - combine() verdict folding

    @Test("a thrown action (Tier 1) is the strongest negative — verdict failed")
    func exerciseFailureWins() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass, .fail]), scenario: scenario(.pass))
        #expect(v.status == .failed)
        #expect(v.detail.contains("Action 1"))
    }

    @Test("clean exercise + an intent check that passed → verified")
    func scenarioPassVerifies() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass, .warn]), scenario: scenario(.pass))
        #expect(v.status == .verified)
        #expect(v.chatLine.contains("Verified"))
    }

    @Test("clean exercise + an intent check that failed → failed")
    func scenarioFailFails() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass]), scenario: scenario(.fail, detail: "Expected items count eq 1, got 0."))
        #expect(v.status == .failed)
        #expect(v.chatLine.contains("count eq 1"))
        #expect(v.chatLine.contains("open Test"))   // honest, actionable
    }

    @Test("clean exercise + no authorable intent check → inconclusive, never a false verified")
    func noScenarioIsInconclusive() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass, .pass]), scenario: scenario(nil))
        #expect(v.status == .inconclusive)
        #expect(v.chatLine.contains("exercised"))
    }

    @Test("a step-less check is vacuously 'pass' but proves nothing → inconclusive, not verified")
    func emptyStepsCheckIsInconclusive() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass]), scenario: scenario(.pass, steps: 0))
        #expect(v.status == .inconclusive)
    }

    @Test("a warn outcome is not a clean pass → inconclusive, not verified")
    func warnScenarioIsInconclusive() {
        let v = WorkspaceAppStudioVerifier.combine(exercise: report([.pass]), scenario: scenario(.warn))
        #expect(v.status == .inconclusive)
    }

    // MARK: - verify() end to end

    @Test("an app with no runnable actions is notApplicable (nothing to execute)")
    func noActionsIsNotApplicable() async {
        let pureUI = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "calc", name: "Calculator"),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: "<main>1+1</main>"
        )
        let v = await WorkspaceAppStudioVerifier.verify(
            intent: "make it add", manifest: pureUI, workspacePath: "/tmp/x",
            configuration: .claude(), scenarioRunner: { _, _, _ in AgentUtilityRunResult(exitCode: 0, output: "", error: "") }
        )
        #expect(v.status == .notApplicable)
        #expect(v.chatLine.isEmpty)
    }

    @Test("a data app's declared CRUD is exercised cleanly (the reference app, no thrown action)")
    func referenceDataAppExercisesClean() {
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        #expect(WorkspaceAppSelfCheck.autoExercise(manifest: manifest).failCount == 0)
    }

    @Test("verify RUNS the model-authored check for real — an insert that yields 1 row verifies")
    func groundedScenarioPasses() async {
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        guard let insert = manifest.actions.first(where: { $0.type == "appStorage.insert" }), let table = insert.table else {
            Issue.record("expected an appStorage.insert action with a table"); return
        }
        let checkJSON = #"{"id":"chk","label":"add one","steps":[{"actionID":"\#(insert.id)"}],"expect":{"kind":"rowCount","table":"\#(table)","op":"eq","value":1}}"#
        let runner: WorkspaceAppStudioPromptRunner = { _, _, _ in
            AgentUtilityRunResult(exitCode: 0, output: "ASTRA_APP_CHECK\n\(checkJSON)\nEND_ASTRA_APP_CHECK", error: "")
        }
        let v = await WorkspaceAppStudioVerifier.verify(
            intent: "after adding one item the table has one row", manifest: manifest,
            workspacePath: "/tmp/x", configuration: .claude(), scenarioRunner: runner
        )
        #expect(v.scenario?.check != nil)         // the check was authored + parsed
        #expect(v.status == .verified)            // and it RAN and passed in the sandbox
    }

    @Test("verify reports a real failure when the executed check doesn't hold")
    func groundedScenarioFails() async {
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        guard let insert = manifest.actions.first(where: { $0.type == "appStorage.insert" }), let table = insert.table else {
            Issue.record("expected an appStorage.insert action with a table"); return
        }
        // One insert can't produce 99 rows → the executed check fails for real.
        let checkJSON = #"{"id":"chk","label":"impossible","steps":[{"actionID":"\#(insert.id)"}],"expect":{"kind":"rowCount","table":"\#(table)","op":"eq","value":99}}"#
        let runner: WorkspaceAppStudioPromptRunner = { _, _, _ in
            AgentUtilityRunResult(exitCode: 0, output: "ASTRA_APP_CHECK\n\(checkJSON)\nEND_ASTRA_APP_CHECK", error: "")
        }
        let v = await WorkspaceAppStudioVerifier.verify(
            intent: "after adding one item there are 99 rows", manifest: manifest,
            workspacePath: "/tmp/x", configuration: .claude(), scenarioRunner: runner
        )
        #expect(v.status == .failed)
    }
}
