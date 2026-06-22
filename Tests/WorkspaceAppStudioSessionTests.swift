import Foundation
import Testing
@testable import ASTRA

/// The conversational App Studio engine: each turn generates the first app or refines the
/// current one, the live preview tracks `draftRevision`, and publish gating mirrors the
/// validator. Generation is stubbed (no provider CLI) so these are fast pure-logic tests.
@MainActor
@Suite("Workspace App Studio Session")
struct WorkspaceAppStudioSessionTests {
    // MARK: - Fixtures

    /// Stub at the generate seam: returns canned results in order (repeating the last) and
    /// records every call so multi-turn manifest threading + provider routing are provable.
    final class StubGenerator {
        private(set) var calls: [(intent: String, existing: WorkspaceAppManifest?, providers: Set<String>)] = []
        private let results: [WorkspaceAppStudioGenerationResult]

        init(_ results: [WorkspaceAppStudioGenerationResult]) { self.results = results }

        var generate: WorkspaceAppStudioGenerate {
            { [self] intent, _, _, existing, _, providers in
                calls.append((intent, existing, providers))
                return results[min(calls.count - 1, results.count - 1)]
            }
        }
    }

    private static var validManifest: WorkspaceAppManifest {
        WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
    }

    private static var invalidManifest: WorkspaceAppManifest {
        var manifest = validManifest
        manifest.app.id = ""
        manifest.app.name = ""
        return manifest
    }

    private static func result(
        _ manifest: WorkspaceAppManifest,
        origin: WorkspaceAppStudioGenerationResult.Origin = .model,
        attemptCount: Int = 1,
        providerFailure: String? = nil,
        summary: String? = nil
    ) -> WorkspaceAppStudioGenerationResult {
        WorkspaceAppStudioGenerationResult(
            manifest: manifest,
            validationReport: WorkspaceAppManifestValidator.validate(manifest),
            accepted: origin != .deterministicFallback,
            origin: origin,
            attemptCount: attemptCount,
            providerFailure: providerFailure,
            summary: summary
        )
    }

    private func workspace() -> Workspace {
        Workspace(name: "Demo", primaryPath: "/tmp/demo")
    }

    private func session(_ results: [WorkspaceAppStudioGenerationResult]) -> (WorkspaceAppStudioSession, StubGenerator) {
        let stub = StubGenerator(results)
        return (WorkspaceAppStudioSession(generate: stub.generate), stub)
    }

    private func submit(_ session: WorkspaceAppStudioSession, _ text: String, _ workspace: Workspace) async {
        await session.submit(
            text, workspace: workspace,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model,
            availableProviders: []
        )
    }

    // MARK: - First turn

    @Test("the first message generates an app and surfaces an assistant summary")
    func firstTurnGenerates() async {
        let (session, stub) = session([Self.result(Self.validManifest)])
        let ws = workspace()
        #expect(session.draft == nil)

        await submit(session, "track lab samples with a status and an owner", ws)

        #expect(stub.calls.count == 1)
        #expect(stub.calls[0].existing == nil) // first turn has no prior manifest
        #expect(session.draft != nil)
        // A data intent is now a data-backed HTML app: a provisional draft shows instantly, then the
        // model result upgrades it → two revisions.
        #expect(session.draftRevision == 2)
        #expect(session.isGenerating == false)
        #expect(session.canPublish)
        // user turn + assistant summary (the seeded greeting is replaced on reset, not here)
        #expect(session.messages.filter { $0.role == .user }.count == 1)
        #expect(session.messages.last?.role == .assistant)
        #expect(session.messages.last?.kind == .summary)
    }

    // MARK: - Multi-turn refinement carries the prior manifest

    @Test("a follow-up turn passes the current draft manifest back as the base")
    func secondTurnCarriesManifest() async {
        let (session, stub) = session([Self.result(Self.validManifest)])
        let ws = workspace()

        await submit(session, "first message", ws)
        await submit(session, "add an owner field", ws)

        #expect(stub.calls.count == 2)
        #expect(stub.calls[0].intent == "first message")
        #expect(stub.calls[1].intent == "add an owner field")
        #expect(stub.calls[0].existing == nil)
        // Turn 2 must carry turn 1's manifest so the generator patches/extends it.
        #expect(stub.calls[1].existing == Self.validManifest)
        // Turn 1: provisional (data-backed HTML) + model result = 2 revisions; turn 2: result only
        // (no provisional once a draft exists) = 3.
        #expect(session.draftRevision == 3)
    }

    // MARK: - Refinement chips (pure, no model call)

    @Test("a refinement chip mutates the draft and reads as a conversation turn")
    func refinementApplies() async {
        let (session, _) = session([Self.result(Self.validManifest)])
        let ws = workspace()
        await submit(session, "track groceries", ws)
        let revisionBefore = session.draftRevision

        session.applyRefinement(.addApproval, workspace: ws)

        #expect(session.draft?.manifest.actions.contains { $0.type == "gate.humanApproval" } == true)
        #expect(session.draftRevision == revisionBefore + 1)
        // Shown as a user request + an assistant confirmation.
        #expect(session.messages.suffix(2).first?.role == .user)
        #expect(session.messages.last?.role == .assistant)
    }

    @Test("an unavailable refinement is a no-op (no draft churn, no extra messages)")
    func unavailableRefinementIsNoOp() async {
        let (session, _) = session([Self.result(Self.validManifest)])
        let ws = workspace()
        await submit(session, "track groceries", ws)
        session.applyRefinement(.addApproval, workspace: ws) // now applied
        let revisionAfterFirst = session.draftRevision
        let messageCount = session.messages.count

        session.applyRefinement(.addApproval, workspace: ws) // already present -> unavailable

        #expect(session.draftRevision == revisionAfterFirst)
        #expect(session.messages.count == messageCount)
    }

    // MARK: - Scope guard

    @Test("an out-of-scope website intent responds honestly without generating")
    func outOfScopeFirstTurnDoesNotGenerate() async {
        let (session, stub) = session([Self.result(Self.validManifest)])
        let ws = workspace()

        await submit(session, "build me a landing page for the foundation", ws)

        #expect(stub.calls.isEmpty) // no model call burned
        #expect(session.draft == nil)
        #expect(session.isGenerating == false)
        #expect(session.messages.last?.role == .assistant)
        #expect(session.messages.last?.text.contains("data and workflow apps") == true)
    }

    @Test("a connector intent discloses the no-internet limit but STILL generates (non-blocking)")
    func connectorIntentDisclosesButGenerates() async {
        let (session, stub) = session([Self.result(Self.validManifest)])
        let ws = workspace()

        await submit(session, "a ui to manage open PRs in github", ws)

        #expect(stub.calls.count == 1) // generation proceeded — connector notice does NOT block
        #expect(session.draft != nil)
        #expect(session.messages.contains { $0.text.contains("no internet access") })
    }

    // MARK: - Resilient provisional draft (self-healing UX)

    @Test("a UI intent shows a real provisional dynamic UI BEFORE the model returns, then upgrades")
    func provisionalDynamicUIShownThenUpgraded() async {
        let ws = workspace()
        var sessionRef: WorkspaceAppStudioSession?
        var draftDuringGeneration: WorkspaceAppStudioDraft?
        // The model "succeeds" with a bespoke HTML app; capture the draft AT model-call time to prove
        // a real interactive UI was already showing before the (slow) model returned.
        var modelHTML = Self.validManifest
        modelHTML.html = "<main><button onclick=\"void 0\">Go</button></main><script>1;</script>"
        let stub: WorkspaceAppStudioGenerate = { _, _, _, _, _, _ in
            draftDuringGeneration = sessionRef?.draft
            return Self.result(modelHTML)
        }
        let s = WorkspaceAppStudioSession(generate: stub)
        sessionRef = s

        await s.submit(
            "a ui to manage open prs and comments", workspace: ws,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model, availableProviders: []
        )

        // Provisional UI was showing during generation — never a blank wait.
        #expect(draftDuringGeneration != nil)
        #expect(draftDuringGeneration?.manifest.html != nil)
        // …and it upgraded to the model's bespoke UI when generation completed.
        #expect(s.draft?.manifest.html == modelHTML.html)
    }

    @Test("a monitor intent (native, no html baseline) gets NO provisional draft")
    func monitorIntentHasNoProvisional() async {
        let ws = workspace()
        var sessionRef: WorkspaceAppStudioSession?
        var draftDuringGeneration: WorkspaceAppStudioDraft?
        let stub: WorkspaceAppStudioGenerate = { _, _, _, _, _, _ in
            draftDuringGeneration = sessionRef?.draft
            return Self.result(Self.validManifest)
        }
        let s = WorkspaceAppStudioSession(generate: stub)
        sessionRef = s

        // Monitor is the sole remaining native archetype (scheduled automations) → no html baseline →
        // no instant provisional. (Data AND workflow intents are now HTML and DO get a provisional —
        // see firstTurnGenerates / the Phase 5 archetype tests.)
        await s.submit(
            "monitor records and alert when a threshold is crossed", workspace: ws,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model, availableProviders: []
        )

        #expect(draftDuringGeneration == nil)
    }

    // MARK: - Publish gating

    @Test("publish gating mirrors the validator, turn over turn")
    func publishGatingMirrorsValidation() async {
        let (session, _) = session([
            Self.result(Self.invalidManifest, origin: .deterministicFallback, providerFailure: "boom"),
            Self.result(Self.validManifest)
        ])
        let ws = workspace()

        await submit(session, "track groceries", ws)
        #expect(session.canPublish == false)
        #expect(session.messages.last?.text.contains("blocker") == true)

        await submit(session, "fix it", ws)
        #expect(session.canPublish == true)
        #expect(session.messages.last?.text.contains("ready to publish") == true)
    }

    // MARK: - Reset / edit-existing

    @Test("reset with an existing manifest seeds the draft for editing")
    func resetForEditingSeedsDraft() {
        let (session, _) = session([Self.result(Self.validManifest)])
        let ws = workspace()

        session.reset(for: ws, existingManifest: Self.validManifest)
        #expect(session.draft != nil)
        #expect(session.appName == Self.validManifest.app.name)
        // Honest greeting names the source app (it builds a copy; in-place edit isn't wired).
        #expect(session.messages.first?.text.contains(Self.validManifest.app.name) == true)

        session.reset(for: ws) // fresh start clears the draft
        #expect(session.draft == nil)
        #expect(session.messages.count == 1)
        #expect(session.messages.first?.role == .assistant)
    }

    // MARK: - Model-written summary

    @Test("a model-written summary leads the assistant turn, with validation appended")
    func usesModelSummaryWhenPresent() async {
        let (session, _) = session([Self.result(Self.validManifest, summary: "A tidy lab sample tracker")])
        let ws = workspace()
        await submit(session, "track lab samples", ws)
        let last = session.messages.last
        #expect(last?.role == .assistant)
        #expect(last?.text.hasPrefix("A tidy lab sample tracker") == true)
        #expect(last?.text.contains("ready to publish") == true)
    }

    // MARK: - Stale-completion guard

    @Test("a turn cancelled mid-generation is discarded instead of clobbering state")
    func staleCompletionIsDiscarded() async {
        let ws = workspace()
        var session: WorkspaceAppStudioSession?
        let stub: WorkspaceAppStudioGenerate = { _, _, _, _, _, _ in
            // Simulate the user leaving the Studio (or switching workspaces) mid-generation.
            session?.cancelGeneration()
            return Self.result(Self.validManifest)
        }
        let s = WorkspaceAppStudioSession(generate: stub)
        session = s

        // A native monitor intent (no provisional) so the assertion isolates the stale-result guard.
        await s.submit(
            "monitor records and alert when a threshold is crossed", workspace: ws,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model, availableProviders: []
        )

        #expect(s.draft == nil)          // stale result dropped — no draft applied
        #expect(s.isGenerating == false) // cancel cleared the in-flight flag
        #expect(!s.messages.contains { $0.role == .assistant && $0.kind == .summary })
    }

    @Test("reset invalidates an in-flight generation so its result is dropped")
    func resetInvalidatesInFlight() async {
        let ws = workspace()
        var session: WorkspaceAppStudioSession?
        let stub: WorkspaceAppStudioGenerate = { _, _, _, _, _, _ in
            session?.reset(for: ws)  // a brand-new conversation started mid-flight
            return Self.result(Self.validManifest)
        }
        let s = WorkspaceAppStudioSession(generate: stub)
        session = s

        await s.submit(
            "first idea", workspace: ws,
            runtimeID: TaskExecutionDefaults.runtime.rawValue,
            model: TaskExecutionDefaults.model, availableProviders: []
        )

        // After reset, the session is the fresh greeting state; the stale turn applied nothing.
        #expect(s.draft == nil)
        #expect(s.messages.count == 1)
        #expect(s.messages.first?.role == .assistant)
    }

    // MARK: - Honest summary wording

    @Test("the fallback summary names the real failure reason")
    func fallbackSummaryIsHonest() {
        let line = StudioTurnSummary.line(
            for: Self.result(Self.validManifest, origin: .deterministicFallback, providerFailure: "provider offline"),
            isEditing: false
        )
        #expect(line.contains("template"))
        #expect(line.contains("provider offline"))
    }

    @Test("a UI-intent fallback reads as an interactive HTML starting point, not a template")
    func htmlScaffoldFallbackMessage() {
        let scaffold = WorkspaceAppStudioBuilder.htmlAppScaffoldManifest(intent: "a ui to manage PRs")
        let line = StudioTurnSummary.line(
            for: Self.result(scaffold, origin: .deterministicFallback, providerFailure: "Process timed out after 180 seconds"),
            isEditing: false
        )
        #expect(line.contains("interactive HTML starting point"))
        #expect(!line.contains("template"))
        #expect(line.contains("180 seconds"))
    }
}
