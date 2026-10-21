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
    /// An activation of a plugin the library has no readable entry for:
    /// nothing of it runs, and Remove forgets it
    /// (`CapabilityUninstaller.forgetMissing`).
    var isMissing = false
}

/// One plugin as the surface acts on it, built once per render with its
/// display row: Expand, Add, Update, Turn off and Remove all take this, so
/// nothing resolves the package or the activation again by ID.
struct PluginRow: Identifiable {
    let package: PluginPackage
    let activation: PluginActivation?
    let display: PluginsSurfaceRow

    var id: String { package.id }

    var canChangeAccountBindings: Bool {
        guard let activation, activation.isEnabled else { return false }
        return !PluginRuntimeProjection.awaitsUpdate(activation, to: package)
    }
}

struct PluginsSurfaceState: Equatable {
    var actionNeeded: [PluginsSurfaceRow] = []
    var ready: [PluginsSurfaceRow] = []
    var available: [PluginsSurfaceRow] = []

    var isEmpty: Bool { actionNeeded.isEmpty && ready.isEmpty && available.isEmpty }
    var allRows: [PluginsSurfaceRow] { actionNeeded + ready + available }
}

enum PluginsSurfacePresentation {
    /// The settings that affect the skill this activation actually runs.
    /// An authored replacement owns its own settings instead.
    static func settingKeys(of skill: PluginSkill, in activation: PluginActivation?, package: PluginPackage? = nil) -> [String] {
        guard let activation, PluginRuntimeProjection.packageSkillOwnsSettings(skill, activation: activation) else { return [] }
        // The installer places these fields on each connector account and
        // runtime account values take precedence over skill environment values.
        guard package?.connectors.isEmpty != false else { return [] }
        return skill.environmentKeys
    }

    static func showsRemove(_ row: PluginRow) -> Bool {
        row.display.isRemovable && (!row.display.isEnabled || row.display.isMissing)
    }

    static func expandedSetupComponents(for row: PluginRow) -> [(component: PluginComponent, position: Int?)] {
        let manifest = PluginManifestConverter.manifest(from: row.package)
        return manifest.components.enumerated()
            .filter { $0.element.kind != .skill && (row.activation == nil || $0.element.kind != .connector) }
            .map { ($0.element, PluginManifestConverter.prerequisitePosition(ofComponentAt: $0.offset, in: manifest)) }
    }

    static func confirmationCopy(
        _ confirmation: PluginsSurfaceConfirmation, account: Connector?,
        packageName: String, in workspace: Workspace, workspaces: [String]
    ) -> (message: String, verb: String) {
        confirmation.copy(name: account.map { accountTitle($0, in: workspace) } ?? packageName, workspaces: workspaces)
    }

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
        /// Why a plugin that is not on can't be added, when approval would
        /// not clear it: shown in place of Add, which could only fail.
        var blocker: String?
        /// On, but the installed definition is not the one this workspace
        /// accepted (`CapabilityPackageState.awaitsUpdate`): nothing of it
        /// runs here until Update accepts it, so the row needs action and
        /// offers Update.
        var awaitsUpdate = false
        /// An activation whose plugin the library no longer has.
        var isMissing = false
    }

    static let missingMessage = "Not installed anymore. Add it again from its file, or Remove it to forget its settings here."

    /// The row of an activation whose plugin the library has no readable
    /// entry for, built from what the activation names: its plugin ID.
    static func missingInput(pluginID: String, isEnabled: Bool) -> Input {
        Input(
            package: PluginPackage(
                id: pluginID, name: pluginID, icon: "puzzlepiece", description: "", author: "", category: "",
                tags: [], version: "", skills: [], connectors: [], localTools: [], templates: []
            ),
            isEnabled: isEnabled, pendingSteps: 0, isVisible: true, isRemovable: true, isMissing: true
        )
    }

    static let awaitsUpdateMessage = "A new version is installed. Update it to use it here."

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
            // An activation awaiting the installed definition is one Update
            // settles, so it offers Update rather than Add again.
            let offersUpdate = input.needsUpdate || input.awaitsUpdate
            let row = PluginsSurfaceRow(
                id: input.package.id,
                name: input.package.name,
                icon: input.package.icon,
                subtitle: subtitle(for: input),
                pendingSteps: input.pendingSteps,
                isEnabled: input.isEnabled,
                isRemovable: input.isRemovable,
                verb: input.isMissing ? nil : !input.isEnabled ? (input.blocker == nil ? .add : nil) : (offersUpdate ? .update : nil),
                isMissing: input.isMissing
            )
            if input.isMissing {
                state.actionNeeded.append(row)
            } else if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 || offersUpdate {
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
        if input.isMissing { return missingMessage }
        if !input.isEnabled, let blocker = input.blocker { return blocker }
        if input.isEnabled, input.awaitsUpdate { return awaitsUpdateMessage }
        let contents = input.package.contentParts.joined(separator: ", ")
        if input.isEnabled, input.needsUpdate {
            return contents.isEmpty ? "Update to \(input.package.version)" : "Update to \(input.package.version) · \(contents)"
        }
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

    /// The setup checks an added plugin's prerequisites failed, a pending step
    /// each. A check the read-only policy refused (`notChecked`) is pending
    /// too: it never passed. A missing result remains pending while scanning.
    static func pendingSetupChecks(for package: PluginPackage, statuses: [String: HealthStatus]) -> Int {
        package.prerequisites.filter { statuses[$0.id].map { !$0.isUsable } ?? true }.count
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

    /// The name `workspace` knows `account` by, as the runtime names it:
    /// its binding alias there when a shared account's name collides, else
    /// the row's name. Two accounts never read the same next to Edit, Make
    /// default and Delete.
    static func accountTitle(_ account: Connector, in workspace: Workspace) -> String {
        WorkspaceCapabilityActivation.alias(of: account, in: workspace)
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
/// Turning a plugin off deletes nothing, so it needs none.
enum PluginsSurfaceConfirmation: Equatable {
    /// Removing it from ASTRA turns it off in every workspace.
    case remove(packageID: String)
    /// Deleting an account removes it everywhere; accepted tasks may retain access.
    case deleteAccount(packageID: String, accountID: UUID)

    var packageID: String {
        switch self {
        case .remove(let id), .deleteAccount(let id, _): id
        }
    }

    func copy(name: String, workspaces: [String] = []) -> (message: String, verb: String) {
        switch self {
        case .remove:
            // Remove deletes activations (settings, secret settings); the
            // accounts and their credentials stay until deleted one by one.
            return (
                "Remove \(name) from ASTRA? It turns off in every workspace and its settings there are deleted. Its accounts and their saved keys stay; delete an account to clear it. You can add it again later.",
                "Remove"
            )
        case .deleteAccount:
            let reach = workspaces.isEmpty
                ? ""
                : " \(workspaces.count == 1 ? "It is used in" : "It is used in \(workspaces.count) workspaces:") \(workspaces.joined(separator: ", "))."
            return ("Delete the account \(name) and its saved keys?\(reach) Tasks already accepted may keep access until they finish or are cancelled. To revoke access, revoke the credentials with the provider.", "Delete")
        }
    }
}
