import Foundation
import SwiftData
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
        /// The source an installed plugin came from (plugin sources, T14).
        var origin: String? = nil
        /// Why a plugin that is not on can't be added, when approval would
        /// not clear it: shown in place of Add, which could only fail.
        var blocker: String?
    }

    /// Whether a package is listed and what keeps it from being added. Listed
    /// when policy shows it and it is on, can be turned on, or needs only the
    /// approval Add grants. One that also has a blocker approval can't clear
    /// (a missing dependency, an unsafe tool) names it instead of offering Add.
    static func listing(
        for decision: CapabilityCatalogDecision,
        isEnabled: Bool
    ) -> (isVisible: Bool, blocker: String?) {
        let isVisible = decision.isVisible && (decision.canEnable || isEnabled || decision.requiresApproval)
        let blocker = isEnabled ? nil : decision.nonApprovalBlockers.first?.message
        return (isVisible, blocker)
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
                verb: input.unavailableReason != nil ? nil : (!input.isEnabled ? (input.blocker == nil ? .add : nil) : (input.needsUpdate ? .update : nil))
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
        if let reason = input.unavailableReason { return reason }
        if !input.isEnabled, let blocker = input.blocker { return blocker }
        var contents = input.package.contentParts.joined(separator: ", ")
        // A plugin from a source always names it (plugin sources, T14).
        if let origin = input.origin {
            contents = contents.isEmpty ? "From \(origin)" : "\(contents) · from \(origin)"
        }
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

    /// Whether a row offers Turn off, which never deletes. A standalone
    /// workspace skill (`skill.<uuid>`) is on for as long as it exists, so it
    /// is edited or deleted where it was written, not switched off here.
    static func offersTurnOff(_ package: PluginPackage) -> Bool {
        !(package.id.hasPrefix("skill.") && package.sourceMetadata?.kind == "workspace")
    }

    /// Whether an expanded row shows the Turn off switch: the row is on here
    /// and may be turned off. A shared standalone skill has no activation,
    /// so the row's own state says whether it is on.
    static func showsTurnOff(_ row: PluginRow) -> Bool {
        (row.activation?.isEnabled ?? row.display.isEnabled) && offersTurnOff(row.package)
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

    /// What a failing component's row shows before its repair button: the
    /// command the button runs, or, for a repair that runs nothing (prose
    /// guidance such as "Start Docker Desktop…"), that guidance, so Check
    /// is never offered without saying what to fix first.
    static func repairGuidance(_ repair: RepairAction) -> (text: String, isCommand: Bool) {
        if let command = repair.command { return (command, true) }
        return (repair.detail, false)
    }

    /// The required accounts an added plugin has no working sign-in for: a
    /// pending step each. Google is the only provider ASTRA signs in to, so
    /// any other stays pending.
    static func pendingAccounts(for package: PluginPackage, googleAccountConnected: Bool) -> [PluginSetupRequirement] {
        package.setupRequirements.filter {
            $0.kind == .oauthAccount && $0.required
                && !($0.provider == GoogleWorkspaceCapability.connectorBinding && googleAccountConnected)
        }
    }

    /// The accounts this workspace sees (its own rows and the shared ones it
    /// lists) that no listed plugin row shows under a connector component:
    /// kept by Remove, released by an Update that dropped their component,
    /// or bound to a component the listed definition no longer declares.
    /// Delete account is the only operation that clears their credentials,
    /// so the surface lists them on their own. A row attached to a skill
    /// belongs to that skill's row.
    static func unusedAccounts(
        workspaceConnectors: [Connector],
        sharedConnectors: [Connector],
        listedPackages: [PluginPackage],
        query: String = ""
    ) -> [Connector] {
        var offered: [String: Set<String>] = [:]
        for package in listedPackages {
            offered[package.id, default: []].formUnion(package.connectors.map(CapabilityResourceOrigin.componentID(for:)))
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<UUID>()
        return (workspaceConnectors + sharedConnectors)
            .filter { account in
                guard !account.isDeleted, account.skill == nil, seen.insert(account.id).inserted else { return false }
                let shown = account.accountBindings.contains { binding in
                    guard !binding.isDeleted, let activation = binding.activation, !activation.isDeleted else { return false }
                    return offered[activation.pluginID]?.contains(binding.componentID) == true
                }
                guard !shown else { return false }
                return needle.isEmpty || [account.name, account.serviceType, account.baseURL]
                    .contains { $0.lowercased().contains(needle) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Jira · Shared · https://example.atlassian.net": the service first.
    static func accountSubtitle(_ account: Connector) -> String {
        let service = account.serviceType.replacingOccurrences(of: "_", with: " ").capitalized
        return [service, account.isGlobal ? "Shared" : "", account.baseURL]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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
                "Remove \(name) from ASTRA? It turns off in every workspace and its settings there are deleted. Its accounts and their saved keys stay; delete an account to clear it. You can add it again later.",
                "Remove"
            )
        case .deleteAccount:
            return Self.deleteAccountCopy(name: name, workspaces: workspaces)
        }
    }

    /// The account delete's copy, also asked by an account no plugin row
    /// shows (`PluginAccountsSection`).
    static func deleteAccountCopy(name: String, workspaces: [String]) -> (message: String, verb: String) {
        let reach = workspaces.isEmpty
            ? ""
            : " \(workspaces.count == 1 ? "It is used in" : "It is used in \(workspaces.count) workspaces:") \(workspaces.joined(separator: ", "))."
        return ("Delete the account \(name) and its saved keys?\(reach)", "Delete")
    }
}
