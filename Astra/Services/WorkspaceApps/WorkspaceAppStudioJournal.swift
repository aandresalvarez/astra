import Foundation

/// A durable record of one App Studio turn — the "strong logs" half of the journal. Same intent as
/// the task chat's `TaskEvent` (a categorized, persisted event the conversation can be reconstructed
/// and audited from), but stays on-disk JSON per the App Studio "NO new @Model / no schema version"
/// rule. `manifestDigest` is the canonical digest of the manifest AFTER the turn, so an event JOINS
/// to `versions/index.json` — it links a turn to the version it produced.
struct StudioGenerationEvent: Identifiable, Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case generation   // a model-backed generate/refine turn
        case refinement   // a pure refinement chip (no model call)
    }

    var id: UUID
    var kind: Kind
    /// The user's message (generation turns) or the refinement label (refinement turns).
    var intent: String
    /// `WorkspaceAppStudioGenerationResult.Origin` raw value, or "refinement" for a chip.
    var origin: String
    /// Model calls made this turn (0 for a refinement chip).
    var attemptCount: Int
    /// Whether the resulting manifest is publishable (validation passed).
    var accepted: Bool
    /// Count of validation blockers on the resulting manifest (0 when publishable).
    var blockerCount: Int
    /// Human-readable provider failure when generation degraded to the template; nil otherwise.
    var providerFailure: String?
    /// Canonical digest of the manifest after this turn — the link into `versions/index.json`.
    var manifestDigest: String
    var runtimeID: String
    var model: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        intent: String,
        origin: String,
        attemptCount: Int = 0,
        accepted: Bool,
        blockerCount: Int,
        providerFailure: String? = nil,
        manifestDigest: String,
        runtimeID: String = "",
        model: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.intent = intent
        self.origin = origin
        self.attemptCount = attemptCount
        self.accepted = accepted
        self.blockerCount = blockerCount
        self.providerFailure = providerFailure
        self.manifestDigest = manifestDigest
        self.runtimeID = runtimeID
        self.model = model
        self.createdAt = createdAt
    }
}

/// The on-disk App Studio journal for one app: the full build conversation plus the per-turn event
/// log. Persisted as `studio/journal.json` in the app directory (so it travels with the app and is
/// removed by `deleteApp`'s recursive directory delete), and loaded on Edit so a build conversation
/// resumes with its history instead of a fresh greeting. NOT a `@Model` — pure JSON, the same rule
/// `versions/index.json` follows.
struct WorkspaceAppStudioJournal: Equatable, Codable {
    var schemaVersion: Int
    var messages: [StudioMessage]
    var events: [StudioGenerationEvent]

    init(
        schemaVersion: Int = 1,
        messages: [StudioMessage] = [],
        events: [StudioGenerationEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.messages = messages
        self.events = events
    }

    var isEmpty: Bool { messages.isEmpty && events.isEmpty }
}

/// Persistence boundary the Studio session depends on, so the session stays unit-testable with an
/// in-memory spy while production reads/writes `studio/journal.json` on disk.
protocol WorkspaceAppStudioJournalStoring {
    func load(appID: String, workspacePath: String) -> WorkspaceAppStudioJournal
    func save(_ journal: WorkspaceAppStudioJournal, appID: String, workspacePath: String)
}
