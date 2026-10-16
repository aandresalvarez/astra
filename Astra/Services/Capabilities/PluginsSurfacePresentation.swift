import Foundation
import ASTRACore

/// The Plugins 2.0 surface as plain values: one list in three groups, status
/// carried by the group heading, one verb per row (Plugins 2.0 spec, UI).
///
/// Pure, so ordering and copy are pinned by `PluginsSurfacePresentationTests`
/// without a view.
struct PluginsSurfaceRow: Equatable, Identifiable {
    enum Verb: Equatable {
        case add
        /// Added, but the library holds a different version than the one
        /// this workspace recorded: re-add to take the new definition.
        case update
    }

    let id: String
    let name: String
    let icon: String
    let subtitle: String
    let pendingSteps: Int
    let isEnabled: Bool
    let isRemovable: Bool
    let verb: Verb?
}

struct PluginsSurfaceState: Equatable {
    var actionNeeded: [PluginsSurfaceRow] = []
    var ready: [PluginsSurfaceRow] = []
    var available: [PluginsSurfaceRow] = []

    var isEmpty: Bool { actionNeeded.isEmpty && ready.isEmpty && available.isEmpty }
}

enum PluginsSurfacePresentation {
    struct Input {
        var package: PluginPackage
        var isEnabled: Bool
        /// Checks that failed, connectors without credentials: what keeps an
        /// added plugin from working.
        var pendingSteps: Int
        /// Hidden or blocked by policy; such packages are not listed.
        var isVisible: Bool
        var isRemovable: Bool
        /// The source a not-yet-added plugin comes from; nil for the catalog.
        var sourceName: String? = nil
        /// Parts of a source plugin ASTRA does not run ("1 agent", "hooks").
        var unsupported: [String] = []
        /// Why it cannot be added, when it cannot.
        var problem: String? = nil
        /// The version this workspace recorded when it was added; nil when it
        /// predates version recording.
        var recordedVersion: String? = nil
        /// Where the plugin runs fully (`worksOn`), shown before adding.
        var worksOn: String? = nil

        var needsUpdate: Bool {
            isEnabled && (recordedVersion ?? "") != package.version
        }
    }

    static func makeState(_ inputs: [Input], query: String) -> PluginsSurfaceState {
        var state = PluginsSurfaceState()
        let sorted = inputs
            .filter { $0.isVisible && matches($0.package, query: query) }
            .sorted { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }
        for input in sorted {
            let row = PluginsSurfaceRow(
                id: input.package.id,
                name: input.package.name,
                icon: input.package.icon,
                subtitle: subtitle(for: input),
                pendingSteps: input.pendingSteps,
                isEnabled: input.isEnabled,
                isRemovable: input.isRemovable,
                verb: verb(for: input)
            )
            if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 || input.needsUpdate {
                state.actionNeeded.append(row)
            } else {
                state.ready.append(row)
            }
        }
        return state
    }

    static func verb(for input: Input) -> PluginsSurfaceRow.Verb? {
        if input.isEnabled { return input.needsUpdate ? .update : nil }
        return input.problem == nil ? .add : nil
    }

    /// "1 step pending · 1 skill, 3 tools" for an added plugin with work left;
    /// "Update to 1.2.0" when the library moved on; for one not yet added, its
    /// contents, source, what it leaves out, and where it runs.
    static func subtitle(for input: Input) -> String {
        if let problem = input.problem { return problem }
        let contents = input.package.contentParts.joined(separator: ", ")
        let summary = contents.isEmpty ? input.package.description : contents
        if !input.isEnabled {
            var parts = [summary]
            if let sourceName = input.sourceName { parts.append("from \(sourceName)") }
            if !input.unsupported.isEmpty { parts.append("without " + input.unsupported.joined(separator: ", ")) }
            if let worksOn = input.worksOn { parts.append(worksOn) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var parts: [String] = []
        if input.needsUpdate { parts.append("Update to \(input.package.version)") }
        if input.pendingSteps > 0 {
            parts.append(input.pendingSteps == 1 ? "1 step pending" : "\(input.pendingSteps) steps pending")
        }
        parts.append(contents)
        let subtitle = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return subtitle.isEmpty ? input.package.description : subtitle
    }

    private static let runtimeOrder: [AgentRuntimeID] = [
        .claudeCode, .codexCLI, .copilotCLI, .cursorCLI, .openCodeCLI, .antigravityCLI
    ]

    /// "works on every provider", or which providers get the whole plugin
    /// when the rest reach it only through the shell relay.
    static func worksOnSummary(_ worksOn: [String: PluginRuntimeSupport]) -> String? {
        let known = runtimeOrder.filter { worksOn[$0.rawValue] != nil }
        guard !known.isEmpty else { return nil }
        let full = known.filter { worksOn[$0.rawValue] == .full || worksOn[$0.rawValue] == .fullWithRecentCLI }
        if full.count == known.count { return "works on every provider" }
        if full.isEmpty { return "shell tools only on every provider" }
        let names = full.map { runtime in
            worksOn[runtime.rawValue] == .fullWithRecentCLI ? "\(shortName(runtime)) (recent)" : shortName(runtime)
        }
        return "full on \(names.joined(separator: ", ")); shell tools elsewhere"
    }

    /// Row subtitles are one line, so providers go by their short names.
    private static func shortName(_ runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: "Claude"
        case .codexCLI: "Codex"
        case .copilotCLI: "Copilot"
        case .cursorCLI: "Cursor"
        case .openCodeCLI: "OpenCode"
        case .antigravityCLI: "Antigravity"
        default: runtime.displayName
        }
    }

    /// Name, summary and tags, plus what is inside: skill names, tool names and
    /// commands, MCP servers, connector services. "bigquery" finds Google Cloud
    /// through its `bq` tool's description.
    static func matches(_ package: PluginPackage, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [package.name, package.description, package.contentSummary]
            + package.tags
            + package.skills.flatMap { [$0.name, $0.description] }
            + package.localTools.flatMap { [$0.name, $0.command, $0.description] }
            + package.mcpServers.flatMap { [$0.displayName, $0.id] }
            + package.connectors.flatMap { [$0.name, $0.serviceType] }
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}
