import Foundation

/// The portable `.astra-share` wire format for a workspace's shareable
/// configuration.
///
/// This is an **allowlist** DTO, and that is the entire point: it can *only*
/// represent config that is safe to leave the sending machine and safe to
/// install into a fresh, workspace-scoped context on the receiving one. It is
/// deliberately NOT `WorkspaceConfigManager.WorkspaceConfig` — that type is the
/// bounded *local-recovery mirror* and carries everything (host paths, run
/// history, `isGlobal` flags, enabled-global ID sets, secret-env slots,
/// reachability caches, stable resource UUIDs). Serializing the mirror made
/// "every field travels unless someone remembers to scrub it" the default — a
/// denylist over an ever-growing struct that leaked a new field every review.
///
/// Here the default is inverted. A machine-local/sensitive field (class b) or a
/// local-authority/global-scope/collision-prone identity field (class c) simply
/// has **no property to receive it** — so a new sensitive field added to
/// `WorkspaceConfig` in the future cannot leak through this format, and an
/// importer built from it cannot create global resources, reuse the recipient's
/// catalog, or collide with built-ins. The manifest
/// (`WorkspacePackageManifest`) still owns the readiness *inventory* (apps,
/// capabilities, connector service types, accounts, SSH labels); this document
/// owns only the shareable config *data*.
struct WorkspaceShareDocument: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var name: String
    var icon: String
    var instructions: String
    /// Enable-intent only; the importer reconciles this to
    /// installed-and-approved capabilities (built-in refs + embedded custom
    /// packages), so a draft/unknown/unapproved ID cannot silently activate.
    var capabilityIDs: [String]
    /// Built-in pack references; a missing pack becomes a readiness item.
    /// Custom packs are not embedded yet (a documented follow-up).
    var packIDs: [String]
    var skills: [ShareSkill]
    var connectors: [ShareConnector]
    var localTools: [ShareLocalTool]
    var templates: [ShareTemplate]
    var schedules: [ShareSchedule]
    var sshConnections: [ShareSSHConnection]

    /// The single declared list of resource types a `.astra-share` package can
    /// carry. Each kind must be wired through all four stages — export
    /// projection, validation, import, and review disclosure. The recurring
    /// class of bugs on this feature (a resource the importer creates that the
    /// review never shows, a field validation never guards) is exactly a kind
    /// or field handled in one stage but not the parallel ones, because those
    /// four traversals are hand-written and independent. This enum is the
    /// contract's anchor: `WorkspaceShareStageCoverageTests` asserts every kind
    /// is disclosed in the review planner (the invariant that skills/templates
    /// silently violated), so a new resource type cannot be added to the DTO
    /// without surfacing it for approval. Per-FIELD completeness within a kind
    /// (sanitizing every credential surface, range-checking every value) is
    /// owned by that kind's projection + validator.
    enum ResourceKind: String, CaseIterable, Sendable {
        case skills, connectors, localTools, templates, schedules, sshConnections
        case capabilities, apps, packs, accounts

        /// Substrings, any of which appearing in the review-planner source proves
        /// this kind is surfaced in the pre-import review.
        var disclosureTokens: [String] {
            switch self {
            case .skills: ["document.skills"]
            case .connectors: ["document.connectors"]
            case .localTools: ["document.localTools"]
            case .templates: ["document.templates"]
            case .schedules: ["document.schedules", "quarantinedScheduleCount"]
            case .sshConnections: ["document.sshConnections"]
            case .capabilities: ["capabilityEntries"]
            case .apps: ["appEntries"]
            case .packs: ["document.packIDs", "packs"]
            case .accounts: ["googleAccountsRequiringReauth"]
            }
        }
    }

    init(
        formatVersion: Int = WorkspaceShareDocument.currentFormatVersion,
        name: String,
        icon: String,
        instructions: String,
        capabilityIDs: [String] = [],
        packIDs: [String] = [],
        skills: [ShareSkill] = [],
        connectors: [ShareConnector] = [],
        localTools: [ShareLocalTool] = [],
        templates: [ShareTemplate] = [],
        schedules: [ShareSchedule] = [],
        sshConnections: [ShareSSHConnection] = []
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.icon = icon
        self.instructions = instructions
        self.capabilityIDs = capabilityIDs
        self.packIDs = packIDs
        self.skills = skills
        self.connectors = connectors
        self.localTools = localTools
        self.templates = templates
        self.schedules = schedules
        self.sshConnections = sshConnections
    }
}

/// A skill definition. No `id`/`isGlobal`/`isBuiltIn`/`origin*` and no UUID
/// resource references — links to connectors/tools are by **name**, resolved
/// within this package's own freshly-created resource set on import.
/// `environmentValues` are already secret-blanked at projection time (via
/// `Skill.exportableEnvironmentValues`); non-secret values travel.
struct ShareSkill: Codable, Sendable, Equatable {
    var name: String
    var icon: String
    var description: String
    var allowedTools: [String]
    var disallowedTools: [String]
    var customTools: [String]
    var behaviorInstructions: String
    var environmentKeys: [String]
    var environmentValues: [String]
    var connectorNames: [String]
    var localToolNames: [String]
}

/// A connector definition. Credential *values* never travel (only key names);
/// `configValues` is deliberately omitted because it can hold non-secret-keyed
/// sensitive data. No `id`/`isGlobal`/`origin*`.
struct ShareConnector: Codable, Sendable, Equatable {
    var name: String
    var serviceType: String
    var icon: String
    var description: String
    var baseURL: String
    var authMethod: String
    var credentialKeys: [String]
    /// Non-secret configuration KEY names (e.g. `JIRA_PROJECTS`, a tenant ID).
    /// Only the names travel — `configValues` is dropped because it can hold
    /// non-secret-keyed sensitive data — so the recipient re-enters the values.
    /// Surfaced as a local-setup readiness item so a connector needing config
    /// isn't shown as immediately Ready.
    var configKeys: [String]
    var notes: String
}

/// A local tool definition. Command/arguments are re-checked against
/// `LocalToolSecurityPolicy` on import. No `id`/`isGlobal`/`origin*`.
struct ShareLocalTool: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var icon: String
    var toolType: String
    var command: String
    var arguments: String
}

/// A task template. `defaultSkillNames` links by name, not UUID.
/// No `id`/`origin*`, and no `hooksJSON`: template hooks run shell commands
/// that `ClaudeSettingsStore.injectTemplateHooks` writes into the workspace's
/// settings and executes on the next task — executable behavior the review
/// sheet never surfaces, so an untrusted share must not carry it.
struct ShareTemplate: Codable, Sendable, Equatable {
    var name: String
    var icon: String
    var description: String
    var beforeGoal: String
    var mainGoal: String
    var afterGoal: String
    var beforeBudget: Int
    var mainBudget: Int
    var afterBudget: Int
    var beforeModel: String
    var mainModel: String
    var afterModel: String
    var variablesJSON: String
    var passContextToMain: Bool
    var passContextToAfter: Bool
    var defaultSkillNames: [String]
}

/// A routine definition. Carries only the recurring *definition*, never run
/// history or timing state: no `nextFireDate`/`lastFiredAt`/`fireCount`/
/// `runResultsJSON`/`conversationContext`/`sourceTaskID`, and no `routinePaths`
/// (absolute sender paths, also stripped from `templateVariablesJSON` at
/// projection). Import recomputes the next fire date from now.
struct ShareSchedule: Codable, Sendable, Equatable {
    var name: String
    var goal: String
    var routineDescription: String
    var routineInstructions: String
    var templateName: String?
    var templateVariablesJSON: String
    var model: String
    var tokenBudget: Int
    var scheduleType: String
    var intervalSeconds: Int
    var dailyHour: Int
    var dailyMinute: Int
    var weeklyDayOfWeek: Int
    var skillNames: [String]
    var resultMode: String?
    var runtimeID: String?
}

/// An SSH connection definition. The absolute private-key path
/// (`keyPath`) and reachability cache (`lastTestedAt`/`lastTestResult`) never
/// travel; the manifest flags which connections need a key re-pointed locally.
struct ShareSSHConnection: Codable, Sendable, Equatable {
    var name: String
    var host: String
    var user: String
    var port: Int
    var remotePath: String
    var configAlias: String
}
