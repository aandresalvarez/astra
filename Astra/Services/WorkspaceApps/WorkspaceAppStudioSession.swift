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

/// One turn in the build conversation.
struct StudioMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    /// `summary` marks an assistant turn that reports the result of a generation/refinement
    /// (so the view can style it distinctly from a plain note).
    enum Kind: Equatable { case message, summary }

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

    private(set) var workspaceID: UUID?
    private let generate: WorkspaceAppStudioGenerate
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

    init(generate: @escaping WorkspaceAppStudioGenerate = WorkspaceAppStudioSession.defaultGenerate) {
        self.generate = generate
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
        generationToken &+= 1  // invalidate any in-flight generation from a prior session
        if let existingManifest {
            draft = WorkspaceAppStudioBuilder.draft(intent: "", workspace: workspace, existingManifest: existingManifest)
            // Honest about scope: in-place editing of the published app isn't wired yet, so
            // publishing saves a new app. Don't promise "I'll update it".
            messages = [StudioMessage(
                role: .assistant,
                text: "Starting from \(existingManifest.app.name). Tell me what to change — add a field, a chart, an approval step — and I'll rebuild it. Publishing saves it as a new app."
            )]
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
        isGenerating = false
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
            // Editing: the fallback is the user's unchanged app, not a template.
            let degraded = isEditing ? "kept your current app unchanged" : "started you from a template"
            return "I couldn't build that from the model, so I \(degraded)\(why). " + validationLine(result.validationReport)
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
