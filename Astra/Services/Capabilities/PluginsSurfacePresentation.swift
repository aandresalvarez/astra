import Foundation
import ASTRACore
import ASTRAModels

/// The Plugins 2.0 surface as plain values: one list in three groups, status
/// carried by the group heading, one verb per row (Plugins 2.0 spec, UI).
///
/// Pure, so ordering and copy are pinned by `PluginsSurfacePresentationTests`
/// without a view.
struct PluginsSurfaceRow: Equatable, Identifiable {
    enum Verb: Equatable {
        case add
        /// The workspace still runs an earlier definition (a reconcile that
        /// could not finish): bring it up to the library's.
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

/// One plugin as the surface acts on it, built once per render with its
/// display row: Expand, Add, Update, Turn off and Remove all take this, so
/// nothing resolves the package or the activation again by ID.
struct PluginRow: Identifiable {
    let package: PluginPackage
    let activation: PluginActivation?
    let display: PluginsSurfaceRow

    var id: String { package.id }
}

struct PluginsSurfaceState: Equatable {
    var actionNeeded: [PluginsSurfaceRow] = []
    var ready: [PluginsSurfaceRow] = []
    var available: [PluginsSurfaceRow] = []

    var isEmpty: Bool { actionNeeded.isEmpty && ready.isEmpty && available.isEmpty }
    var allRows: [PluginsSurfaceRow] { actionNeeded + ready + available }
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
        var needsUpdate: Bool = false
        /// Why it can't be added whatever the policy says; shown instead of Add.
        var unavailableReason: String? = nil
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
                verb: input.unavailableReason != nil ? nil : (!input.isEnabled ? .add : (input.needsUpdate ? .update : nil))
            )
            if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 || input.needsUpdate || input.unavailableReason != nil {
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
        if let reason = input.unavailableReason { return reason }
        if input.isEnabled, input.needsUpdate {
            return contents.isEmpty ? "Update to \(input.package.version)" : "Update to \(input.package.version) · \(contents)"
        }
        guard input.isEnabled, input.pendingSteps > 0 else {
            return contents.isEmpty ? input.package.description : contents
        }
        let pending = input.pendingSteps == 1 ? "1 step pending" : "\(input.pendingSteps) steps pending"
        return contents.isEmpty ? pending : "\(pending) · \(contents)"
    }

    /// Why a plugin can't be added on this build whatever the policy says:
    /// one that needs an OAuth account sign-in, which ASTRA does not offer
    /// (owner decision: the Google OAuth stack is deleted), would add and then
    /// never work.
    static func unavailableReason(for package: PluginPackage) -> String? {
        guard package.setupRequirements.contains(where: { $0.kind == .oauthAccount }) else { return nil }
        return "Needs an account sign-in that ASTRA can't do."
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
/// Turning a plugin off deletes nothing, so it needs none.
enum PluginsSurfaceConfirmation: Equatable {
    /// Removing it from ASTRA turns it off in every workspace.
    case remove(packageID: String)
    /// Deleting an account removes it, and its saved keys, everywhere.
    case deleteAccount(packageID: String, accountID: UUID)

    var packageID: String {
        switch self {
        case .remove(let id), .deleteAccount(let id, _): id
        }
    }

    func copy(name: String, workspaces: [String] = []) -> (message: String, verb: String) {
        switch self {
        case .remove:
            return (
                "Remove \(name) from ASTRA? It turns off in every workspace and its settings there are deleted. Its accounts stay; delete them separately. You can add it again later.",
                "Remove"
            )
        case .deleteAccount:
            let reach = workspaces.isEmpty
                ? ""
                : " \(workspaces.count == 1 ? "It is used in" : "It is used in \(workspaces.count) workspaces:") \(workspaces.joined(separator: ", "))."
            return ("Delete the account \(name) and its saved keys?\(reach)", "Delete")
        }
    }
}
