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
        /// Why a plugin that is not on can't be added, when approval would
        /// not clear it: shown in place of Add, which could only fail.
        var blocker: String?
        /// On, but the installed definition is not the one this workspace
        /// accepted (`CapabilityPackageState.awaitsUpdate`): nothing of it
        /// runs here until Add accepts it, so the row needs action and
        /// offers Add again.
        var awaitsUpdate = false
    }

    static let awaitsUpdateMessage = "A new version is installed. Add it again to use it here."

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
                verb: (input.isEnabled && !input.awaitsUpdate) || input.blocker != nil ? nil : .add
            )
            if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 || input.awaitsUpdate {
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
        if !input.isEnabled, let blocker = input.blocker { return blocker }
        if input.isEnabled, input.awaitsUpdate { return awaitsUpdateMessage }
        let contents = input.package.contentParts.joined(separator: ", ")
        guard input.isEnabled, input.pendingSteps > 0 else {
            return contents.isEmpty ? input.package.description : contents
        }
        let pending = input.pendingSteps == 1 ? "1 step pending" : "\(input.pendingSteps) steps pending"
        return contents.isEmpty ? pending : "\(pending) · \(contents)"
    }

    /// Whether a row offers Turn off, which never deletes. A standalone
    /// workspace skill (`skill.<uuid>`) is on for as long as it exists, so it
    /// is edited or deleted where it was written, not switched off here.
    static func offersTurnOff(_ package: PluginPackage) -> Bool {
        !(package.id.hasPrefix("skill.") && package.sourceMetadata?.kind == "workspace")
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

    /// The setup checks an added plugin's prerequisites failed, a pending step
    /// each. A check the read-only policy refused (`notChecked`) is pending
    /// too: it never passed. It just offers no repair.
    static func pendingSetupChecks(for package: PluginPackage, statuses: [String: HealthStatus]) -> Int {
        package.prerequisites.filter { statuses[$0.id].map { !$0.isUsable } ?? false }.count
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

    /// What a pending account's row offers.
    enum PendingAccountAction: Equatable {
        /// Add, which routes through the install flow that signs in again.
        case reconnect
        /// Add refuses the plugin: why, with no button that could only fail.
        case unsupported(String)
    }

    /// Decided by the rule Add itself follows
    /// (`CapabilityCatalogActionService.addRoute`), so the row never offers
    /// Reconnect for an account Add can't sign in to (a provider other than
    /// Google), and the two can't drift.
    @MainActor
    static func pendingAccountAction(for package: PluginPackage) -> PendingAccountAction {
        do {
            _ = try CapabilityCatalogActionService.addRoute(for: package)
            return .reconnect
        } catch {
            return .unsupported(error.localizedDescription)
        }
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
            // Turn off deletes nothing: accounts, settings and keys stay. A
            // standalone workspace skill, which only deleting turns off, is
            // not offered it (`PluginsSurfacePresentation.offersTurnOff`).
            return (
                "Turn off \(name) in this workspace? Nothing is deleted: its accounts, settings and saved keys stay, and turning it on again restores it.",
                "Turn off"
            )
        case .remove:
            // Remove deletes activations (settings, secret settings); the
            // accounts and their credentials stay until deleted one by one.
            let accounts = hasAccounts
                ? " Its accounts and their saved keys stay; delete an account from Accounts to clear it."
                : ""
            return (
                "Remove \(name) from ASTRA? It turns off in every workspace and its settings there are deleted.\(accounts) You can add it again later.",
                "Remove"
            )
        }
    }
}
