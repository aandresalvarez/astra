import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Studio Generator (Slice 2)")
struct WorkspaceAppStudioGeneratorTests {
    // MARK: - Fixtures

    /// A scripted prompt-runner: returns the canned outputs in order (repeating the
    /// last once exhausted) and records every call for prompt/count assertions.
    final class ScriptedRunner {
        private(set) var calls: [(prompt: String, workspacePath: String)] = []
        private let outputs: [AgentUtilityRunResult]

        init(_ outputs: [AgentUtilityRunResult]) {
            self.outputs = outputs
        }

        var runner: WorkspaceAppStudioPromptRunner {
            { [self] prompt, workspacePath, _ in
                calls.append((prompt, workspacePath))
                let index = min(calls.count - 1, outputs.count - 1)
                return outputs[index]
            }
        }
    }

    private static func ok(_ output: String) -> AgentUtilityRunResult {
        AgentUtilityRunResult(exitCode: 0, output: output, error: "")
    }

    private static func manifestBlock(_ json: String) -> AgentUtilityRunResult {
        ok("ASTRA_APP_MANIFEST\n\(json)\nEND_ASTRA_APP_MANIFEST")
    }

    private static func json(_ manifest: WorkspaceAppManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(manifest), encoding: .utf8)!
    }

    /// The deterministic template manifest — a known-valid manifest the model can "return".
    private static var validManifest: WorkspaceAppManifest {
        WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
    }

    /// A well-formed-but-invalid manifest: blank id + name produce validation blockers.
    private static var invalidManifest: WorkspaceAppManifest {
        var manifest = validManifest
        manifest.app.id = ""
        manifest.app.name = ""
        return manifest
    }

    // MARK: - Fixture sanity

    @Test("the invalid fixture really is rejected, the valid one accepted")
    func fixtureValidity() {
        #expect(WorkspaceAppManifestValidator.validate(Self.validManifest).isValid)
        #expect(!WorkspaceAppManifestValidator.validate(Self.invalidManifest).isValid)
    }

    // MARK: - Happy paths

    @Test("a valid manifest on the first attempt is accepted as model-origin")
    func validFirstShot() async {
        let runner = ScriptedRunner([Self.manifestBlock(Self.json(Self.validManifest))])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            runner: runner.runner
        )
        #expect(result.accepted)
        #expect(result.origin == .model)
        #expect(result.attemptCount == 1)
        #expect(result.canPublish)
        #expect(runner.calls.count == 1)
    }

    @Test("an invalid first attempt is repaired on the next turn")
    func invalidThenRepaired() async {
        let runner = ScriptedRunner([
            Self.manifestBlock(Self.json(Self.invalidManifest)),
            Self.manifestBlock(Self.json(Self.validManifest))
        ])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 2,
            runner: runner.runner
        )
        #expect(result.accepted)
        #expect(result.origin == .modelRepaired)
        #expect(result.attemptCount == 2)
        #expect(result.canPublish)
        #expect(runner.calls.count == 2)
    }

    @Test("the repair prompt embeds the prior validation blockers")
    func repairPromptCarriesIssues() async {
        let runner = ScriptedRunner([
            Self.manifestBlock(Self.json(Self.invalidManifest)),
            Self.manifestBlock(Self.json(Self.validManifest))
        ])
        _ = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            runner: runner.runner
        )
        let repairPrompt = runner.calls[1].prompt
        #expect(repairPrompt.contains("[BLOCKER]"))
        #expect(repairPrompt.contains("REJECTED"))
    }

    // MARK: - Degradation

    @Test("exhausting repair attempts falls back to the deterministic template")
    func exhaustedFallsBackToTemplate() async {
        let runner = ScriptedRunner([Self.manifestBlock(Self.json(Self.invalidManifest))])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 2,
            runner: runner.runner
        )
        #expect(!result.accepted)
        #expect(result.origin == .deterministicFallback)
        // Fallback manifest is the valid template, so it remains publishable.
        #expect(result.canPublish)
        #expect(result.providerFailure == nil)
        // 1 first attempt + 2 repair attempts.
        #expect(result.attemptCount == 3)
        #expect(runner.calls.count == 3)
    }

    @Test("a provider error degrades immediately to the template fallback")
    func providerErrorFallsBack() async {
        let runner = ScriptedRunner([
            AgentUtilityRunResult(exitCode: 1, output: "", error: "boom")
        ])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            runner: runner.runner
        )
        #expect(!result.accepted)
        #expect(result.origin == .deterministicFallback)
        #expect(result.providerFailure == "boom")
        #expect(result.canPublish) // template is valid
        #expect(runner.calls.count == 1)
    }

    @Test("a provider error mid-repair stops and falls back")
    func providerErrorMidRepair() async {
        let runner = ScriptedRunner([
            Self.manifestBlock(Self.json(Self.invalidManifest)),
            AgentUtilityRunResult(exitCode: 137, output: "", error: "killed")
        ])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 3,
            runner: runner.runner
        )
        #expect(result.origin == .deterministicFallback)
        #expect(result.providerFailure == "killed")
        #expect(result.attemptCount == 2)
        #expect(runner.calls.count == 2)
    }

    @Test("maxRepairAttempts of 0 means no repair turn after an invalid first shot")
    func respectsZeroRepairBudget() async {
        let runner = ScriptedRunner([Self.manifestBlock(Self.json(Self.invalidManifest))])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 0,
            runner: runner.runner
        )
        #expect(result.origin == .deterministicFallback)
        #expect(result.attemptCount == 1)
        #expect(runner.calls.count == 1)
    }

    // MARK: - Malformed model output

    @Test("output with no manifest block is treated as invalid and repaired/fallen back")
    func noBlockFallsBack() async {
        let runner = ScriptedRunner([Self.ok("Sure! Here is an app idea but no block.")])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 1,
            runner: runner.runner
        )
        #expect(result.origin == .deterministicFallback)
        #expect(result.canPublish)
        #expect(runner.calls.count == 2) // first + 1 repair, both blockless
    }

    @Test("output with BOTH a manifest and a patch block is rejected")
    func bothBlocksRejected() async {
        let both = Self.ok(
            "ASTRA_APP_MANIFEST\n\(Self.json(Self.validManifest))\nEND_ASTRA_APP_MANIFEST\n"
            + "ASTRA_APP_PATCH\n[]\nEND_ASTRA_APP_PATCH"
        )
        let runner = ScriptedRunner([both])
        let result = await WorkspaceAppStudioGenerator.generate(
            intent: "Build me a grocery database app.",
            workspaceName: "Demo",
            workspacePath: "/tmp/demo",
            maxRepairAttempts: 0,
            runner: runner.runner
        )
        // Both-blocks is a structured-output failure -> not accepted -> fallback.
        #expect(result.origin == .deterministicFallback)
        #expect(runner.calls.count == 1)
    }

    // MARK: - Prompt content (the unknown-contract guard)

    @Test("the generation prompt lists known contracts and forbids markdown fences")
    func generationPromptGuards() {
        let families = WorkspaceAppContractRegistry().families
        let prompt = WorkspaceAppStudioGenerator.generationPrompt(
            intent: "track groceries",
            workspaceName: "Demo",
            base: Self.validManifest,
            contractFamilies: families
        )
        #expect(prompt.contains("appStorage.records"))
        #expect(prompt.contains("ASTRA_APP_MANIFEST"))
        #expect(prompt.contains("END_ASTRA_APP_MANIFEST"))
        #expect(prompt.lowercased().contains("no backticks"))
        // The valid baseline is embedded as the few-shot example.
        #expect(prompt.contains("\"schemaVersion\""))
    }
}
