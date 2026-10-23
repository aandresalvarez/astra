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

/// A held import (`RetiredPluginActivation.pendingImport`): settings an
/// imported workspace file, or a recovery, kept for a plugin copy this Mac
/// doesn't have yet. Listed under "Action needed" with Discard, and Add
/// when the installed copy is the one it waits for.
struct PluginsSurfaceHeldImport: Equatable, Identifiable {
    let pluginID: String
    let name: String
    let subtitle: String
    /// The installed copy is the one it waits for and the plugin isn't on
    /// here: Add brings the settings back.
    let canAdd: Bool

    var id: String { "held-import:\(pluginID)" }
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
        if let package, PluginRuntimeProjection.awaitsUpdate(activation, to: package) { return [] }
        guard let package, !package.connectors.isEmpty,
              let primary = package.skills.first,
              CapabilityResourceOrigin.componentID(for: primary) == CapabilityResourceOrigin.componentID(for: skill)
        else { return skill.environmentKeys }
        // Runtime associates the package accounts with its first skill only.
        // A secondary skill's activation values can execute without those accounts.
        // Hide only fields the shared account layout actually stores. A
        // skill-only secret remains owned by this activation even when the
        // package also declares unrelated connector accounts.
        let accountKeys = Set(package.connectors.flatMap { connector in
            let stored = PluginConnectorFieldTrust.asStored(connector, in: package)
            return stored.credentialHints.map(\.key)
                + PluginAccountFieldLayout.configurationKeys(hints: stored.configHints)
                + connector.configHints.filter(\.isAccountStructure).map(\.key)
        })
        return skill.environmentKeys.filter { !accountKeys.contains($0) }
    }

    static func showsRemove(_ row: PluginRow) -> Bool {
        row.display.isRemovable && (!row.display.isEnabled || row.display.isMissing)
    }

    static func expandedSetupComponents(for row: PluginRow, in workspace: Workspace? = nil) -> [(component: PluginComponent, position: Int?)] {
        let manifest = PluginManifestConverter.manifest(from: row.package)
        return manifest.components.enumerated()
            .filter { entry in
                guard entry.element.kind != .skill else { return false }
                guard entry.element.kind == .connector, let activation = row.activation else { return true }
                guard let workspace, let connector = entry.element.connector else { return false }
                return activation.accounts(forComponent: CapabilityResourceOrigin.componentID(for: connector)).contains {
                    $0.isGlobal && !WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs.contains($0.id.uuidString)
                }
            }
            .map { ($0.element, PluginManifestConverter.prerequisitePosition(ofComponentAt: $0.offset, in: manifest)) }
    }

    static func confirmationCopy(
        _ confirmation: PluginsSurfaceConfirmation, account: Connector?,
        packageName: String, in workspace: Workspace
    ) -> (message: String, verb: String) {
        confirmation.copy(name: account.map { accountTitle($0, in: workspace) } ?? packageName)
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
        /// Why it can't be added whatever the policy says; shown instead of Add.
        var unavailableReason: String? = nil
        /// The source an installed plugin came from (plugin sources, T14).
        var origin: String? = nil
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
                verb: input.isMissing || input.unavailableReason != nil ? nil : (!input.isEnabled ? (input.blocker == nil ? .add : nil) : (offersUpdate ? .update : nil)),
                isMissing: input.isMissing
            )
            if input.isMissing {
                state.actionNeeded.append(row)
            } else if !input.isEnabled {
                state.available.append(row)
            } else if input.pendingSteps > 0 || offersUpdate || input.unavailableReason != nil {
                state.actionNeeded.append(row)
            } else {
                state.ready.append(row)
            }
        }
        return state
    }

    /// Each held import in `workspace`, by name. `installed` is the library;
    /// `source(of:)` names where the installed copy came from
    /// (`plugin-source:<id>`, nil when local), `matches` whether it is the
    /// copy a held import waits for (`PluginPendingImport.matches`), and
    /// `sourceName` turns a recorded source into what the screen shows.
    static func heldImports(
        in workspace: Workspace,
        installed: [PluginPackage],
        source: (PluginPackage) -> String?,
        matches: (RetiredPluginActivation.PendingImport, PluginPackage) -> Bool,
        sourceName: (String?) -> String
    ) -> [PluginsSurfaceHeldImport] {
        WorkspaceCapabilityActivation.retiredActivations(of: workspace).compactMap { entry in
            guard let pending = entry.pendingImport else { return nil }
            let package = installed.first { $0.id == entry.pluginID }
            let added = WorkspaceCapabilityActivation.activation(for: entry.pluginID, in: workspace)?.isEnabled == true
            let kept = pending.recovered == true ? "Settings this workspace had" : "Settings from an imported workspace file"
            let subtitle: String
            var canAdd = false
            if let package {
                func identity(_ value: String?) -> String? { value == "local" || value?.isEmpty == true ? nil : value }
                if matches(pending, package) {
                    canAdd = !added
                    subtitle = added
                        ? "\(kept) come back the next time ASTRA starts, or discard them."
                        : "\(kept). Add it to bring them back, or discard them."
                } else if identity(pending.source) != identity(source(package)) {
                    subtitle = "\(kept) are for its copy from \(sourceName(pending.source)), and the one installed is from \(sourceName(source(package))). Discard them, or install that copy."
                } else {
                    subtitle = "\(kept) are for another version of it. Discard them, or install that version."
                }
            } else {
                subtitle = "\(kept), waiting for it from \(sourceName(pending.source)). Install it to bring them back, or discard them."
            }
            return PluginsSurfaceHeldImport(pluginID: entry.pluginID, name: package?.name ?? entry.pluginID, subtitle: subtitle, canAdd: canAdd)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "1 step pending · 1 skill, 3 tools" for an added plugin with work left;
    /// the contents alone otherwise.
    static func subtitle(for input: Input) -> String {
        if input.isMissing { return missingMessage }
        if let reason = input.unavailableReason { return reason }
        if !input.isEnabled, let blocker = input.blocker { return blocker }
        if input.isEnabled, input.awaitsUpdate { return awaitsUpdateMessage }
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

    /// The accounts this workspace sees (its own rows and the shared ones it
    /// lists) that no listed plugin row shows under a connector component:
    /// kept by Remove, released by an Update that dropped their component,
    /// or bound to a component the listed definition no longer declares.
    /// Delete account is the only operation that clears their credentials,
    /// so the surface lists them on their own. A row attached to a skill
    /// belongs to that skill's row.
    static func unusedAccounts(
        in workspace: Workspace,
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
                    guard !binding.isDeleted, let activation = binding.activation, !activation.isDeleted,
                          activation.workspace?.id == workspace.id else { return false }
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
    /// (`CapabilityCatalogActionService.validateAccountSupport`), so the row never offers
    /// Reconnect for an account Add can't sign in to (a provider other than
    /// Google), and the two can't drift.
    @MainActor
    static func pendingAccountAction(for package: PluginPackage) -> PendingAccountAction {
        do {
            try CapabilityCatalogActionService.validateAccountSupport(for: package)
            return .reconnect
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }
}

/// Consent belongs to the displayed definition and removal mode. An import,
/// update or activation change requires a fresh confirmation.
struct PluginRemovalSource: Equatable {
    let packageID: String
    let isMissing: Bool
    private let definitionDigest: String
    private let activationID: UUID?
    private let activationRevision: Int?

    init(row: PluginRow) {
        packageID = row.id
        isMissing = row.display.isMissing
        definitionDigest = PluginDefinitionDigest.content(of: row.package)
        activationID = row.activation?.id
        activationRevision = row.activation?.revision
    }

    func matches(_ row: PluginRow) -> Bool { self == Self(row: row) }
}

/// The second tap before a destructive row action: it names what goes and
/// what stays (`docs/design-system/lean-ui-system.md`, Interaction Rules).
/// Turning a plugin off deletes nothing, so it needs none.
enum PluginsSurfaceConfirmation: Equatable {
    /// Removing it from ASTRA turns it off in every workspace.
    case remove(source: PluginRemovalSource, scope: PluginRemovalScope)
    /// Deleting an account removes it everywhere; accepted tasks may retain access.
    case deleteAccount(packageID: String, scope: PluginAccountDeletionScope)

    var packageID: String {
        switch self {
        case .remove(let source, _): source.packageID
        case .deleteAccount(let id, _): id
        }
    }

    func copy(name: String) -> (message: String, verb: String) {
        switch self {
        case .remove:
            return (
                "Remove \(name) from ASTRA? It turns off in every workspace and its settings there are deleted. Its accounts and their saved keys stay; delete an account to clear it. You can add it again later.",
                "Remove"
            )
        case .deleteAccount(_, let scope):
            return Self.deleteAccountCopy(name: name, scope: scope)
        }
    }

    /// The account delete's copy, also asked by an account no plugin row
    /// shows (`PluginAccountsSection`).
    static func deleteAccountCopy(name: String, scope: PluginAccountDeletionScope) -> (message: String, verb: String) {
        let workspaces = scope.workspaces.map(\.name)
        let reach = workspaces.isEmpty
            ? ""
            : " \(workspaces.count == 1 ? "It is used in" : "It is used in \(workspaces.count) workspaces:") \(workspaces.joined(separator: ", "))."
        return ("Delete the account \(name) and its saved keys?\(reach) Tasks already accepted may keep access until they finish or are cancelled. To revoke access, revoke the credentials with the provider.", "Delete")
    }
}
