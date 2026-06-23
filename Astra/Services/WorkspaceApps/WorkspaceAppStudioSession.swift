import Combine
import Foundation

/// The conversational engine behind App Studio. Instead of a form, the user builds an
/// app by chatting: the first message generates a draft, later messages refine it, and a
/// docked live preview re-renders after every turn. This is the UI-agnostic state +
/// behavior — `WorkspaceAppStudioChatView` renders it and `ShelfWorkspaceAppPreviewView`
/// renders its `draft`. All the heavy lifting is reused: generation runs through
/// `WorkspaceAppStudioGenerator` (which already accepts an `existingManifest` and emits a
/// full manifest OR an `ASTRA_APP_PATCH`, so multi-turn refinement is just "pass the prior
/// manifest as the base"); refinements are the pure `WorkspaceAppStudioRefinement`
/// transforms; the scope guard is `WorkspaceAppStudioScope`.
///
/// The generator is injected (`generate`) so tests drive turns with canned results and
/// never spawn a provider CLI.

/// One turn in the build conversation. `Codable` (with stable string raws) so the conversation
/// survives across Studio sessions via the on-disk journal (`studio/journal.json`).
struct StudioMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable { case user, assistant }
    /// `summary` marks an assistant turn that reports the result of a generation/refinement
    /// (so the view can style it distinctly from a plain note).
    enum Kind: String, Equatable, Codable { case message, summary }

    let id: UUID
    let role: Role
    let kind: Kind
    let text: String

    init(id: UUID = UUID(), role: Role, kind: Kind = .message, text: String) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
    }
}

/// The one model call a turn makes. Mirrors `WorkspaceAppStudioGenerator.generate`'s
/// inputs/outputs so the default is a thin pass-through and tests inject a stub.
typealias WorkspaceAppStudioGenerate = (
    _ intent: String,
    _ workspaceName: String,
    _ workspacePath: String,
    _ existingManifest: WorkspaceAppManifest?,
    _ configuration: AgentUtilityRuntimeConfiguration,
    _ availableProviders: Set<String>
) async -> WorkspaceAppStudioGenerationResult

/// Grounded post-turn verification: run the produced app in the sandbox and report whether the
/// change behaves as asked. Injected (like `generate`) so tests verify turns without a provider CLI.
typealias WorkspaceAppStudioVerify = (
    _ intent: String,
    _ manifest: WorkspaceAppManifest,
    _ workspacePath: String,
    _ configuration: AgentUtilityRuntimeConfiguration
) async -> WorkspaceAppStudioVerification

@MainActor
final class WorkspaceAppStudioSession: ObservableObject {
    @Published private(set) var messages: [StudioMessage] = []
    /// The work-in-progress app. `nil` until the first turn produces one — the preview
    /// shows an empty state meanwhile.
    @Published private(set) var draft: WorkspaceAppStudioDraft?
    @Published private(set) var isGenerating = false
    /// True while a FIRST build is generating and the draft is still the instant deterministic
    /// provisional (not yet the model's result). The preview shows a "building" status during this
    /// window instead of the generic provisional shell — which otherwise reads as a finished (or
    /// different) app. False for refinements, where the established app stays visible while it updates.
    @Published private(set) var isBuildingFirstDraft = false
    /// Bumped whenever `draft` changes so the preview shelf can key its sandbox on it and
    /// re-render (a regen is a fresh disposable preview, by design).
    @Published private(set) var draftRevision = 0
    /// The per-turn generation event log — the "strong logs" half of the journal (one record per
    /// generate/refine turn: origin, attempts, validation, the resulting manifest digest). Persisted
    /// alongside `messages` so a published app's build history is durable and auditable.
    @Published private(set) var generationEvents: [StudioGenerationEvent] = []
    /// True while a turn's grounded verification is running in the sandbox (after the result is shown,
    /// before the verdict lands). The view shows a subtle "checking your change…" indicator; the user
    /// can already see and act on the app — verification is informational, never a publish gate.
    @Published private(set) var isVerifying = false

    private(set) var workspaceID: UUID?
    private let generate: WorkspaceAppStudioGenerate
    private let verify: WorkspaceAppStudioVerify
    private let journalStore: WorkspaceAppStudioJournalStoring
    /// Set on Edit of an existing app: each turn persists to that app's on-disk journal so the
    /// conversation + events survive across Studio sessions. nil for a not-yet-published app (no app
    /// directory exists yet) — the journal is flushed on publish by the caller instead.
    private var persistenceTarget: (appID: String, workspacePath: String)?
    /// Monotonic guard so a slow generation that finishes after the user leaves, switches
    /// workspaces, or starts a new turn can't overwrite newer state. Bumped on every
    /// submit/reset/cancel; a turn only applies its result if the token is still current.
    private var generationToken = 0

    /// App-builder generation is a heavier one-shot than a typical utility prompt, and a dynamic
    /// HTML app is the heaviest case: the model emits a whole HTML/CSS/JS blob, and `codex exec`
    /// buffers its output to the end, so the provider's WALL-CLOCK timeout (not idle) can kill an
    /// in-progress UI mid-write and force the static template fallback — the failure the user hit
    /// ("Process timed out after 120 seconds"). HTML generation is output-bound, so the prompt hard-
    /// bounds UI size ("ship a working minimal version") to keep generation fast, and this ceiling is
    /// the safety net for the occasional larger UI: 240s. (codex utility runs at low reasoning, so
    /// this is headroom, not a hang ceiling, and `cancelGeneration()` lets the user bail early.)
    private static let generationTimeoutSeconds: TimeInterval = 240
    /// Verification authors + runs a tiny acceptance check — a fraction of a generation. A shorter
    /// ceiling keeps the post-turn verdict snappy and bails fast if the provider stalls.
    private static let verificationTimeoutSeconds: TimeInterval = 90

    init(
        generate: @escaping WorkspaceAppStudioGenerate = WorkspaceAppStudioSession.defaultGenerate,
        verify: @escaping WorkspaceAppStudioVerify = WorkspaceAppStudioSession.defaultVerify,
        journalStore: WorkspaceAppStudioJournalStoring = WorkspaceAppStudioJournalService()
    ) {
        self.generate = generate
        self.verify = verify
        self.journalStore = journalStore
    }

    /// The current conversation + event log, for per-turn persistence and the publish-time flush
    /// (a not-yet-published app has no on-disk target, so the caller writes this to the new app dir).
    var journal: WorkspaceAppStudioJournal {
        WorkspaceAppStudioJournal(messages: messages, events: generationEvents)
    }

    // MARK: - Derived

    /// App name for the chat header / shelf title.
    var appName: String? { draft?.manifest.app.name }

    /// Publish is gated on the validator (blockers only — warnings never block).
    var canPublish: Bool { draft?.canPublish ?? false }

    /// Refinements offered as tappable chips: only those that can still apply to the draft.
    var availableSuggestions: [WorkspaceAppStudioRefinement] {
        guard let manifest = draft?.manifest else { return [] }
        return WorkspaceAppStudioRefinement.allCases.filter { $0.isAvailable(for: manifest) }
    }

    // MARK: - Lifecycle

    /// Start (or restart) a conversation. With `existingManifest`, seed the draft from it so
    /// "Edit in Studio" continues from the current app instead of a blank slate.
    func reset(for workspace: Workspace, existingManifest: WorkspaceAppManifest? = nil) {
        workspaceID = workspace.id
        isGenerating = false
        isBuildingFirstDraft = false
        isVerifying = false
        generationToken &+= 1  // invalidate any in-flight generation from a prior session
        generationEvents = []
        persistenceTarget = nil
        if let existingManifest {
            draft = WorkspaceAppStudioBuilder.draft(intent: "", workspace: workspace, existingManifest: existingManifest)
            // Editing an existing app: target its on-disk journal so every turn from here persists,
            // and RESUME prior history if any (so Edit continues the conversation instead of a fresh
            // greeting). A pre-feature app has no journal → fall back to the greeting.
            var resumed = false
            if !workspace.primaryPath.isEmpty, !existingManifest.app.id.isEmpty {
                persistenceTarget = (existingManifest.app.id, workspace.primaryPath)
                let saved = journalStore.load(appID: existingManifest.app.id, workspacePath: workspace.primaryPath)
                if !saved.messages.isEmpty {
                    messages = saved.messages
                    generationEvents = saved.events
                    resumed = true
                }
            }
            if !resumed {
                // Honest about scope: publishing saves a new app, so don't promise "I'll update it".
                messages = [StudioMessage(
                    role: .assistant,
                    text: "Starting from \(existingManifest.app.name). Tell me what to change — add a field, a chart, an approval step — and I'll rebuild it. Publishing saves it as a new app."
                )]
            }
        } else {
            draft = nil
            messages = [StudioMessage(
                role: .assistant,
                text: "Describe the app you want — what you need to track, review, or report on — and I'll build it. You can refine it by chatting."
            )]
        }
        draftRevision &+= 1
    }

    /// Invalidate any in-flight generation (on Cancel / leaving the Studio / workspace switch),
    /// so a late result can't resume into a session that's no longer active.
    func cancelGeneration() {
        generationToken &+= 1
        isGenerating = false
        isBuildingFirstDraft = false
        isVerifying = false
    }

    // MARK: - Turns

    /// Run one conversation turn: generate the first app, or refine the current one.
    func submit(
        _ rawText: String,
        workspace: Workspace,
        runtimeID: String,
        model: String,
        availableProviders: Set<String>
    ) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        workspaceID = workspace.id
        messages.append(StudioMessage(role: .user, text: text))

        // Honest scope guard, first build only: a website/marketing intent can't be expressed
        // by the data-app schema, so say so instead of shipping a mislabeled data shell.
        if draft == nil, let notice = WorkspaceAppStudioScope.outOfScopeNotice(for: text) {
            messages.append(StudioMessage(role: .assistant, text: notice))
            return
        }
        // Connector/live-data intents (GitHub, Jira, …) can't pull real data in the sandbox, but
        // the interactive UI IS buildable with sample data — disclose the limit honestly, then
        // proceed (non-blocking, first build only).
        if draft == nil, let connectorNotice = WorkspaceAppStudioScope.needsConnectorNotice(for: text) {
            messages.append(StudioMessage(role: .assistant, text: connectorNotice))
        }

        isGenerating = true
        // Clear any leftover verification indicator from a prior turn whose check is still in flight:
        // that stale verifier sees the bumped token and bows out without touching `isVerifying`, so
        // this is the single owner that resets it per turn (no stuck "checking…" across turns).
        isVerifying = false
        generationToken &+= 1
        let token = generationToken
        let existing = draft?.manifest
        // A first build (no existing draft) shows a "building" status in the preview until the result
        // lands, instead of the generic provisional shell.
        isBuildingFirstDraft = existing == nil
        // Resilient, self-healing UX: for a FIRST build whose deterministic baseline is an HTML app
        // (now almost everything — interactive tools AND data apps, which render as data-backed HTML
        // via the astra.* bridge), show that real UI IMMEDIATELY so the preview is never blank while
        // the model works (which can take minutes, or time out). If the model succeeds it UPGRADES
        // this draft; if it times out/fails the fallback is the same baseline — the user always ends
        // up with a dynamic UI, never a downgrade. Governed-workflow intents (native, no html) get no
        // provisional. `existing` is captured above, so generation still treats this as a first build.
        if existing == nil {
            let baseline = WorkspaceAppStudioBuilder.baseManifest(intent: text)
            if baseline.html != nil {
                draft = WorkspaceAppStudioBuilder.draft(intent: text, workspace: workspace, existingManifest: baseline)
                draftRevision &+= 1
            }
        }
        let configuration = AgentUtilityRuntimeConfiguration(
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID),
            model: model,
            timeoutSeconds: Self.generationTimeoutSeconds
        )
        let result = await generate(text, workspace.name, workspace.primaryPath, existing, configuration, availableProviders)
        // Stale-completion guard: if the user reset, cancelled, switched workspaces, or started
        // a newer turn while this was in flight, drop the result instead of clobbering newer state.
        guard token == generationToken else { return }
        // The result manifest is always valid (model or deterministic fallback); rebuild the
        // draft so validation + publish-gating recompute from it.
        draft = WorkspaceAppStudioBuilder.draft(intent: text, workspace: workspace, existingManifest: result.manifest)
        draftRevision &+= 1
        isBuildingFirstDraft = false   // the real result is in — show the app, not the building status
        // Prefer the model's own one-line summary (more natural); always append the honest
        // validation status. Fall back to the fully deterministic summary when absent.
        let assistantText: String
        if let modelSummary = result.summary, !modelSummary.isEmpty {
            assistantText = modelSummary + " " + StudioTurnSummary.validationLine(result.validationReport)
        } else {
            assistantText = StudioTurnSummary.line(for: result, isEditing: existing != nil)
        }
        messages.append(StudioMessage(role: .assistant, kind: .summary, text: assistantText))
        recordEvent(
            kind: .generation, intent: text, origin: result.origin.rawValue,
            attemptCount: result.attemptCount, accepted: result.canPublish,
            blockerCount: result.validationReport.blockers.count, providerFailure: result.providerFailure,
            manifest: result.manifest, runtimeID: runtimeID, model: model
        )
        // The turn's app is in and the user can act on it — verification is informational.
        isGenerating = false
        await verifyTurn(intent: text, result: result, workspacePath: workspace.primaryPath,
                         runtimeID: runtimeID, model: model, token: token)
    }

    /// Grounded post-turn verification: run the produced app in the sandbox and surface an honest
    /// verdict. Best-effort and NON-BLOCKING — it never gates publish and never alters the draft; it
    /// only appends a chat message. Skipped when the result wasn't usable or has no runnable action
    /// to exercise (a pure-UI app). Token-guarded so a slow check can't post into a newer turn.
    private func verifyTurn(
        intent: String,
        result: WorkspaceAppStudioGenerationResult,
        workspacePath: String,
        runtimeID: String,
        model: String,
        token: Int
    ) async {
        // Only an ACCEPTED change is worth verifying. A no-op/fallback turn (accepted == false) keeps
        // the user's UNCHANGED app — verifying it would run the OLD app and contradict the honest
        // "your app is unchanged" message with a "Verified" against the wrong thing. `canPublish`
        // alone isn't enough: the unchanged app is still valid, so it must be gated on `accepted`.
        guard result.accepted, result.canPublish, !result.manifest.actions.isEmpty else { return }
        isVerifying = true
        let configuration = AgentUtilityRuntimeConfiguration(
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID),
            model: model,
            timeoutSeconds: Self.verificationTimeoutSeconds
        )
        let verification = await verify(intent, result.manifest, workspacePath, configuration)
        // The user may have moved on while the check ran (new turn / reset / publish bumped the token).
        // Leave `isVerifying` to whoever owns the current token — clobbering it here could clear a
        // NEWER turn's indicator. submit() resets it at the start of every turn, so it never sticks.
        guard token == generationToken else { return }
        isVerifying = false
        guard verification.status != .notApplicable, !verification.chatLine.isEmpty else { return }
        messages.append(StudioMessage(role: .assistant, kind: .summary, text: verification.chatLine))
        persistJournal()
    }

    /// Apply a refinement chip — a pure, instant manifest transform (no model call). Shown in
    /// the thread as if the user asked for it, so the conversation reads naturally.
    func applyRefinement(_ refinement: WorkspaceAppStudioRefinement, workspace: Workspace) {
        guard let current = draft, refinement.isAvailable(for: current.manifest) else { return }
        let updated = refinement.apply(to: current.manifest)
        let rebuilt = WorkspaceAppStudioBuilder.draft(intent: current.intent, workspace: workspace, existingManifest: updated)
        draft = rebuilt
        draftRevision &+= 1
        messages.append(StudioMessage(role: .user, text: refinement.label))
        messages.append(StudioMessage(
            role: .assistant,
            kind: .summary,
            text: "Done — \(refinement.label.lowercased()). \(StudioTurnSummary.validationLine(rebuilt.validationReport))"
        ))
        recordEvent(
            kind: .refinement, intent: refinement.label, origin: "refinement",
            attemptCount: 0, accepted: rebuilt.canPublish,
            blockerCount: rebuilt.validationReport.blockers.count, providerFailure: nil,
            manifest: rebuilt.manifest, runtimeID: "", model: ""
        )
    }

    // MARK: - Journal (durable conversation + event log)

    /// Append a turn to the event log and persist the journal (when editing an app with an on-disk
    /// target). `manifestDigest` is the canonical digest of the resulting manifest — the same digest
    /// `versions/index.json` records — so a turn links to the version it produced.
    private func recordEvent(
        kind: StudioGenerationEvent.Kind,
        intent: String,
        origin: String,
        attemptCount: Int,
        accepted: Bool,
        blockerCount: Int,
        providerFailure: String?,
        manifest: WorkspaceAppManifest,
        runtimeID: String,
        model: String
    ) {
        let digest = (try? WorkspaceAppService.encodeManifest(manifest)).map(WorkspaceAppService.digest(for:)) ?? ""
        generationEvents.append(StudioGenerationEvent(
            kind: kind, intent: intent, origin: origin, attemptCount: attemptCount,
            accepted: accepted, blockerCount: blockerCount, providerFailure: providerFailure,
            manifestDigest: digest, runtimeID: runtimeID, model: model
        ))
        persistJournal()
    }

    private func persistJournal() {
        guard let target = persistenceTarget else { return }
        journalStore.save(journal, appID: target.appID, workspacePath: target.workspacePath)
    }

    /// Save authored test checks onto the current draft (from the "Test" sheet) so they
    /// travel with the app when published.
    func applyChecks(_ checks: [WorkspaceAppCheck], workspace: Workspace) {
        guard let current = draft else { return }
        var manifest = current.manifest
        manifest.checks = checks.isEmpty ? nil : checks
        draft = WorkspaceAppStudioBuilder.draft(intent: current.intent, workspace: workspace, existingManifest: manifest)
        draftRevision &+= 1
    }

    // MARK: - Default generator

    /// Real generation: the existing model-backed generator, read-only tool mode.
    static let defaultGenerate: WorkspaceAppStudioGenerate = { intent, name, path, existing, configuration, providers in
        await WorkspaceAppStudioGenerator.generate(
            intent: intent,
            workspaceName: name,
            workspacePath: path,
            existingManifest: existing,
            configuration: configuration,
            availableProviders: providers
        )
    }

    /// Real verification: run the produced app in the sandbox (Tier-1 auto-exercise + an intent-
    /// authored Tier-3 scenario), read-only tool mode via the scenario author's default runner.
    static let defaultVerify: WorkspaceAppStudioVerify = { intent, manifest, path, configuration in
        await WorkspaceAppStudioVerifier.verify(
            intent: intent,
            manifest: manifest,
            workspacePath: path,
            configuration: configuration
        )
    }
}

/// Deterministic, conversational summaries of a generation/refinement turn. No second model
/// call — honest about validation and about model-unavailable fallbacks.
enum StudioTurnSummary {
    static func line(for result: WorkspaceAppStudioGenerationResult, isEditing: Bool) -> String {
        switch result.origin {
        case .model:
            let lead = isEditing ? "Updated your app." : "Here's your app."
            return lead + " " + validationLine(result.validationReport)
        case .modelRepaired:
            let lead = isEditing
                ? "Updated your app (refined over \(result.attemptCount) passes)."
                : "Built your app (refined over \(result.attemptCount) passes)."
            return lead + " " + validationLine(result.validationReport)
        case .deterministicFallback:
            let why = result.providerFailure.map { " (\($0))" } ?? ""
            // For a UI-centric intent the fallback is a dynamic HTML scaffold, not a data shell —
            // say so honestly instead of "a template". A DATA-backed HTML fallback (declares its own
            // storage) persists through the astra.* bridge, so don't claim it "can't sync live data";
            // a pure-UI fallback is a sample with no persistence.
            if !isEditing, result.manifest.html != nil {
                if result.manifest.storage?.tables.isEmpty == false {
                    return "I couldn't finish that from the model, so I started you from a working records app\(why) — a real add/edit UI that saves to this app's own local storage. Refine it by chatting. " + validationLine(result.validationReport)
                }
                return "I couldn't finish that from the model, so I started you from an interactive HTML starting point\(why). It's a sample UI you can refine by chatting (it can't sync live data yet). " + validationLine(result.validationReport)
            }
            // Editing: the fallback is the user's UNCHANGED app. Don't append the "ready to publish"
            // validation line — the app was already valid; the point is the edit didn't land. Invite
            // a more specific instruction so the next turn can actually change something.
            if isEditing {
                return "I wasn't able to apply that change\(why) — your app is unchanged. Tell me more "
                    + "specifically what to change (which button, field, or text) and I'll edit it."
            }
            return "I couldn't build that from the model, so I started you from a template\(why). " + validationLine(result.validationReport)
        }
    }

    static func validationLine(_ report: WorkspaceAppManifestValidationReport) -> String {
        guard report.isValid else {
            let blockers = report.blockers.count
            return "It has \(blockers) blocker\(blockers == 1 ? "" : "s") to resolve before publishing."
        }
        let warnings = report.warnings.count
        if warnings == 0 { return "It's valid and ready to publish." }
        return "It's valid (\(warnings) warning\(warnings == 1 ? "" : "s")) and ready to publish."
    }
}
