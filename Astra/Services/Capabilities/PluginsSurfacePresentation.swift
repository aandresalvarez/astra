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
                verb: input.isEnabled ? nil : .add
            )
            if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 {
                state.actionNeeded.append(row)
            } else {
                state.ready.append(row)
            }
        }
        return state
    }

    /// "1 step pending · 1 skill, 3 tools" for an added plugin with work left;
    /// the contents alone otherwise.
    static func subtitle(for input: Input) -> String {
        let contents = input.package.contentParts.joined(separator: ", ")
        guard input.isEnabled, input.pendingSteps > 0 else {
            return contents.isEmpty ? input.package.description : contents
        }
        let pending = input.pendingSteps == 1 ? "1 step pending" : "\(input.pendingSteps) steps pending"
        return contents.isEmpty ? pending : "\(pending) · \(contents)"
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

/// The second tap before a destructive row action: it names what goes and
/// what stays (`docs/design-system/lean-ui-system.md`, Interaction Rules).
enum PluginsSurfaceConfirmation: Equatable {
    /// Turning a plugin off here removes the accounts and keys it created in
    /// this workspace.
    case turnOff(packageID: String)
    /// Removing it from ASTRA turns it off in every workspace.
    case remove(packageID: String)

    var packageID: String {
        switch self {
        case .turnOff(let id), .remove(let id): id
        }
    }

    func copy(name: String, hasAccounts: Bool) -> (message: String, verb: String) {
        switch self {
        case .turnOff:
            let detail = hasAccounts
                ? " Its accounts and saved keys in this workspace are deleted; turning it on again asks for them."
                : " Turning it on again restores it."
            return ("Turn off \(name) in this workspace?" + detail, "Turn off")
        case .remove:
            return (
                "Remove \(name) from ASTRA? It turns off in every workspace, and the accounts and saved keys it created there are deleted. You can add it again later.",
                "Remove"
            )
        }
    }
}
