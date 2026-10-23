import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The Plugins 2.0 surface: three groups with status on the heading, search
/// over what a plugin contains, and a one-step Add that approves before it
/// enables.
@Suite("Plugins surface")
@MainActor
struct PluginsSurfaceTests {
    @Test("Missing pending legacy plugins stay visible before and after Turn off")
    func missingPendingLegacyRows() throws {
        let env = try PluginOperationsTests.Environment()
        env.workspace.legacyEnabledCapabilityIDs = ["gone-on", "gone-on", "known"]
        env.workspace.legacyInstalledPluginIDs = ["gone-off", "gone-on", "listed"]
        env.workspace.legacyInstalledPluginVersions = ["1", "2", "3"]
        try env.context.save()
        func inputs() -> [PluginsSurfacePresentation.Input] {
            PluginsSurfacePresentation.missingInputs(in: env.workspace, libraryIDs: ["known"], listedIDs: ["listed"])
        }
        let rows = inputs()
        #expect(Set(rows.map { $0.package.id }) == ["gone-on", "gone-off"])
        #expect(rows.count == 2)
        #expect(rows.first { $0.package.id == "gone-on" }?.isEnabled == true)
        #expect(rows.first { $0.package.id == "gone-off" }?.isEnabled == false)
        let missing = PluginsSurfacePresentation.missingInput(pluginID: "gone-on", isEnabled: true)
        let result = CapabilityActivationDisabler().disable(missing.package, in: env.workspace,
            modelContext: env.context, library: env.library, rewriteMirror: { _ in true })
        #expect(result.persisted)
        #expect(inputs().first { $0.package.id == "gone-on" }?.isEnabled == false)
        #expect(!env.workspace.enabledCapabilityIDs.contains("gone-on"))
    }

    @Test("A secondary skill keeps account-name collisions editable because runtime attaches accounts only to the primary skill")
    func secondarySkillSettingOwnership() throws {
        let env = try PluginOperationsTests.Environment()
        var candidate = PluginOperationsTests.package(version: "1.0.0")
        candidate.connectors[0].configHints = [.init(key: "PROJECT", hint: "Account project", isList: false)]
        var secondary = candidate.skills[0]
        secondary.id = "secondary"
        secondary.name = "Secondary"
        candidate.skills.append(secondary)
        try env.install(candidate)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: candidate.id, in: env.workspace))
        #expect(PluginsSurfacePresentation.settingKeys(of: candidate.skills[0], in: activation, package: candidate).isEmpty)
        #expect(PluginsSurfacePresentation.settingKeys(of: secondary, in: activation, package: candidate) == ["PROJECT"])
        try PluginOperations.setSetting("PROJECT", to: "secondary-project", of: secondary,
            package: candidate, in: env.workspace, modelContext: env.context)
        let projection = PluginRuntimeProjection.project(workspace: env.workspace, packages: [candidate],
            connectorMode: .runtimeCopies, definitions: [candidate])
        let skill = try #require(projection.skills.first { $0.name == secondary.name })
        #expect(skill.environmentVariables["PROJECT"] == "secondary-project")
        #expect(!projection.connectors.contains { $0.skill?.id == skill.id })
    }

    @Test("A successor skill cannot expose editable settings before Update")
    func renamedSkillSettingsWaitForUpdate() throws {
        let env = try PluginOperationsTests.Environment()
        var initial = PluginOperationsTests.package(version: "1.0.0")
        initial.connectors = []
        try env.install(initial)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: initial.id, in: env.workspace))
        var next = initial
        next.skills[0].id = "successor"
        next.skills[0].replaces = [CapabilityResourceOrigin.componentID(for: initial.skills[0])]
        #expect(PluginsSurfacePresentation.settingKeys(of: next.skills[0], in: activation, package: next).isEmpty)
    }

    @Test("An inactive bound shared account keeps its Turn on setup row")
    func inactiveSharedBindingKeepsSetupRow() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.bindings.first?.account)
        account.isGlobal = true
        let row = PluginRow(package: package, activation: activation, display: .init(id: package.id, name: package.name,
            icon: package.icon, subtitle: "Action needed", pendingSteps: 1, isEnabled: true, isRemovable: true, verb: nil))
        #expect(PluginsSurfacePresentation.expandedSetupComponents(for: row, in: env.workspace).contains { $0.component.kind == .connector })
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalConnector(account.id.uuidString) }
        #expect(!PluginsSurfacePresentation.expandedSetupComponents(for: row, in: env.workspace).contains { $0.component.kind == .connector })
    }

    @Test("Account binding actions wait for the installed definition to be accepted")
    func accountActionsWaitForUpdate() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let display = PluginsSurfaceRow(id: package.id, name: package.name, icon: package.icon, subtitle: "Ready", pendingSteps: 0,
            isEnabled: true, isRemovable: true, verb: nil)
        #expect(PluginRow(package: package, activation: activation, display: display).canChangeAccountBindings)
        var changed = package
        changed.connectors[0].id = "renamed"
        changed.connectors[0].replaces = [CapabilityResourceOrigin.componentID(for: package.connectors[0])]
        #expect(!PluginRow(package: changed, activation: activation, display: display).canChangeAccountBindings)
        #expect(!PluginRow(package: package, activation: nil, display: display).canChangeAccountBindings)
        WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
        #expect(!PluginRow(package: package, activation: activation, display: display).canChangeAccountBindings)
    }

    @Test("Plugins with connectors keep activation-owned skill secrets editable")
    func activationOwnedSecretsRemainEditableBesideAccounts() throws {
        var candidate = PluginOperationsTests.package(version: "1.0.0")
        candidate.skills[0].environmentKeys = ["PROJECT", "API_TOKEN", "TRACKER_TOKEN"]
        candidate.skills[0].environmentValues = ["default-project", "", ""]
        let activation = PluginActivation(pluginID: candidate.id)
        #expect(PluginsSurfacePresentation.settingKeys(of: candidate.skills[0], in: activation,
            package: candidate) == ["PROJECT", "API_TOKEN"])
        var second = candidate.connectors[0]
        second.id = "another-api"
        second.credentialHints = [.init(key: "API_TOKEN", hint: "Account token")]
        candidate.connectors.append(second)
        #expect(PluginsSurfacePresentation.settingKeys(of: candidate.skills[0], in: activation,
            package: candidate) == ["PROJECT"])
        candidate.connectors = []
        #expect(PluginsSurfacePresentation.settingKeys(of: candidate.skills[0], in: activation,
            package: candidate) == candidate.skills[0].environmentKeys)
    }

    @Test("Account-owned environment fields are edited on the account, never as ineffective skill overrides")
    func accountOwnedSettingsStayOnAccounts() throws {
        var candidate = PluginOperationsTests.package(version: "1.0.0")
        candidate.connectors[0].configHints = [.init(key: "PROJECT", hint: "Account project", isList: false)]
        let skill = try #require(candidate.skills.first)
        let activation = PluginActivation(pluginID: candidate.id)
        #expect(!skill.environmentKeys.isEmpty)
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation, package: candidate).isEmpty)
        var standalone = candidate
        standalone.connectors = []
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation, package: standalone) == skill.environmentKeys)
    }

    @Test("A legacy enabled row cannot offer Remove before migration finishes")
    func removeUsesEffectiveEnablement() throws {
        let candidate = package("legacy", name: "Legacy")
        let display = try #require(PluginsSurfacePresentation.makeState([
            input(candidate, isEnabled: true)
        ], query: "").allRows.first)
        var row = PluginRow(package: candidate, activation: nil, display: display)
        #expect(!PluginsSurfacePresentation.showsRemove(row))
        var missing = display
        missing.isMissing = true
        row = PluginRow(package: candidate, activation: nil, display: missing)
        #expect(PluginsSurfacePresentation.showsRemove(row) == missing.isRemovable)
    }

    @Test("An unreadable secret draft has no saveable empty replacement, while other fields remain available")
    func unreadableSecretCannotBecomeAnEmptyDraft() throws {
        var candidate = package("draft-read", name: "Draft read")
        candidate.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        let activation = PluginActivation(pluginID: candidate.id)
        let component = CapabilityResourceOrigin.componentID(for: candidate.skills[0])
        let snapshot = PluginSettingDrafts.load(package: candidate, activation: activation) { key, _, _ in
            if key == "API_TOKEN" { throw PluginOperations.OperationError.secretReadFailed(key: key) }
            return "visible-project"
        }
        let secret = PluginActivation.settingKey(componentID: component, key: "API_TOKEN")
        let project = PluginActivation.settingKey(componentID: component, key: "PROJECT")
        #expect(snapshot.values[secret] == nil)
        #expect(snapshot.failures[secret] != nil)
        #expect(snapshot.values[project] == "visible-project")
        #expect(snapshot.failures[project] == nil)
        #expect(!snapshot.canSave(secret, in: activation))
        #expect(snapshot.canSave(project, in: activation))
    }

    @Test("Switching workspaces invalidates drafts even when activations have the same revision")
    func activationIdentityInvalidatesDrafts() {
        var candidate = package("draft-workspaces", name: "Workspace drafts")
        candidate.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        let first = PluginActivation(pluginID: candidate.id)
        let second = PluginActivation(pluginID: candidate.id)
        #expect(first.id != second.id)
        #expect(first.revision == second.revision)
        let oldSource = PluginSettingDrafts.source(package: candidate, activation: first)
        let newSource = PluginSettingDrafts.source(package: candidate, activation: second)
        #expect(oldSource != newSource)
        let firstDrafts = PluginSettingDrafts.load(package: candidate, activation: first) { _, _, _ in "first-workspace" }
        let secondDrafts = PluginSettingDrafts.load(package: candidate, activation: second) { _, _, _ in "second-workspace" }
        #expect(Set(firstDrafts.values.values) == ["first-workspace"])
        #expect(Set(secondDrafts.values.values) == ["second-workspace"])
    }

    @Test("Unsaved edits survive a refresh only within the same activation")
    func unsavedDraftsStayWithTheirActivation() throws {
        var candidate = package("draft-owner", name: "Owned drafts")
        candidate.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        let first = PluginActivation(pluginID: candidate.id)
        let second = PluginActivation(pluginID: candidate.id)
        let component = CapabilityResourceOrigin.componentID(for: candidate.skills[0])
        let field = PluginActivation.settingKey(componentID: component, key: "PROJECT")
        let token = PluginActivation.settingKey(componentID: component, key: "API_TOKEN")
        var edited = PluginSettingDrafts.load(package: candidate, activation: first) { _, _, _ in "first-saved" }
        #expect(edited.belongs(to: first))
        #expect(!edited.belongs(to: second))
        #expect(!edited.belongs(to: nil))
        edited.values[field] = "first-unsaved"
        edited.values[token] = "first-secret-unsaved"
        let refreshed = PluginSettingDrafts.load(package: candidate, activation: first) { _, _, _ in "first-refreshed" }
        #expect(edited.reloading(from: refreshed).values[field] == "first-unsaved")
        let switched = PluginSettingDrafts.load(package: candidate, activation: second) { _, _, _ in "second-saved" }
        let rebound = edited.reloading(from: switched)
        #expect(rebound.belongs(to: second))
        #expect(!rebound.belongs(to: first))
        #expect(rebound.values[field] == "second-saved")
        #expect(rebound.values[token] == "second-saved")
        let unavailable = PluginSettingDrafts.load(package: candidate, activation: second) { _, _, _ in
            throw PluginOperations.OperationError.secretReadFailed(key: "API_TOKEN")
        }
        let failedRebound = edited.reloading(from: unavailable)
        #expect(failedRebound.values[field] == nil)
        #expect(failedRebound.values[token] == nil)
        #expect(failedRebound.failures[token] != nil)
        #expect(edited.reloading(from: PluginSettingDrafts.load(package: candidate, activation: nil) { _, _, _ in "" }).values.isEmpty)
    }

    @Test("A same-version default change invalidates unchanged setting drafts")
    func definitionDefaultsInvalidateDrafts() {
        var candidate = package("draft-default", name: "Draft default")
        candidate.skills[0].environmentKeys = ["PROJECT"]
        candidate.skills[0].environmentValues = ["before"]
        let activation = PluginActivation(pluginID: candidate.id)
        let before = PluginSettingDrafts.source(package: candidate, activation: activation)
        let version = candidate.version
        candidate.skills[0].environmentValues = ["after"]
        #expect(candidate.version == version)
        #expect(PluginSettingDrafts.source(package: candidate, activation: activation) != before)
    }

    @Test("Only the skill currently used by an activation exposes its package settings")
    func overriddenSkillSettingsStayHidden() throws {
        let candidate = package("settings", name: "Settings")
        var skill = try #require(candidate.skills.first)
        skill.environmentKeys = ["PROJECT", "API_TOKEN"]
        let activation = PluginActivation(pluginID: candidate.id)
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: nil).isEmpty)
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation) == skill.environmentKeys)
        activation.overriddenComponentIDs = [CapabilityResourceOrigin.componentID(for: skill)]
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation).isEmpty)
        activation.overriddenComponentIDs = []
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation) == skill.environmentKeys)
    }

    @Test("A deleted authored override returns settings to the package, matching runtime")
    func deletedOverrideReturnsPackageSettings() throws {
        let env = try PluginOperationsTests.Environment()
        var candidate = PluginOperationsTests.package(version: "1.0.0")
        candidate.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
        try env.install(candidate)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: candidate.id, in: env.workspace))
        let skill = try #require(candidate.skills.first)
        let authored = Skill(name: "My replacement", allowedTools: ["Read"])
        authored.workspace = env.workspace
        env.context.insert(authored)
        WorkspaceCapabilityActivation.setOverridden(true, componentID: CapabilityResourceOrigin.componentID(for: skill), rowID: authored.id, on: activation)
        try env.context.save()
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation).isEmpty)
        let before = PluginSettingDrafts.source(package: candidate, activation: activation)
        let revision = activation.revision
        let hidden = PluginSettingDrafts.load(package: candidate, activation: activation) { _, _, _ in "saved-value" }
        #expect(hidden.values.isEmpty)
        let field = PluginActivation.settingKey(componentID: CapabilityResourceOrigin.componentID(for: skill), key: "PROJECT")
        #expect(!hidden.canSave(field, in: activation))
        env.context.delete(authored)
        try env.context.save()
        #expect(PluginsSurfacePresentation.settingKeys(of: skill, in: activation) == skill.environmentKeys)
        #expect(activation.revision == revision)
        #expect(PluginSettingDrafts.source(package: candidate, activation: activation) != before)
        let fresh = hidden.reloading(from: PluginSettingDrafts.load(package: candidate, activation: activation) { _, _, _ in "saved-value" })
        #expect(fresh.values[field] == "saved-value")
        #expect(fresh.canSave(field, in: activation))
    }

    @Test("Removal consent expires when an absent plugin is imported or its definition or activation changes")
    func removalConsentTracksDisplayedState() {
        let candidate = package("consent", name: "Consent")
        var display = PluginsSurfacePresentation.makeState([input(candidate, isEnabled: true)], query: "").allRows[0]
        display.isMissing = true
        let activation = PluginActivation(pluginID: candidate.id)
        let absent = PluginRow(package: candidate, activation: activation, display: display)
        let source = PluginRemovalSource(row: absent)
        #expect(source.matches(absent))
        display.isMissing = false
        let installed = PluginRow(package: candidate, activation: activation, display: display)
        #expect(!source.matches(installed))
        let installedConsent = PluginRemovalSource(row: installed)
        var updated = candidate
        updated.skills[0].environmentValues = ["changed-without-version-bump"]
        #expect(!installedConsent.matches(PluginRow(package: updated, activation: activation, display: display)))
        activation.revision += 1
        #expect(!installedConsent.matches(installed))
        #expect(!installedConsent.matches(PluginRow(package: candidate,
            activation: PluginActivation(pluginID: candidate.id), display: display)))
    }

    @Test("Delete confirmation names the workspace alias of a colliding shared account")
    func accountConfirmationUsesWorkspaceAlias() throws {
        let env = try PluginOperationsTests.Environment()
        let candidate = PluginOperationsTests.package(version: "1.0.0")
        try env.install(candidate)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: candidate.id, in: env.workspace))
        let component = CapabilityResourceOrigin.componentID(for: candidate.connectors[0])
        let first = try #require(activation.accounts(forComponent: component).first)
        let second = Connector(name: first.name, serviceType: first.serviceType, baseURL: first.baseURL, authMethod: first.authMethod)
        second.isGlobal = true
        env.context.insert(second)
        WorkspaceCapabilityActivation.bind(second, toComponent: component, of: activation, alias: "Tracker 2")
        let copy = PluginsSurfacePresentation.confirmationCopy(.deleteAccount(packageID: candidate.id, scope: try PluginAccountDeletionScope.capture(second)),
            account: second, packageName: candidate.name, in: env.workspace)
        #expect(copy.message.hasPrefix("Delete the account Tracker 2 and its saved keys?"))
        #expect(copy.verb == "Delete")
    }

    private static var retained: [ModelContainer] = []
    @Test("A prerequisite without a completed health check remains pending")
    func uncheckedPrerequisitesArePending() {
        var candidate = package("unchecked", name: "Unchecked")
        candidate.prerequisites = [CLIPrerequisite(binary: "fixture-server", livenessArgs: [], displayName: "Fixture", purpose: "Fixture", installHint: "Install it")]
        #expect(PluginsSurfacePresentation.pendingSetupChecks(for: candidate, statuses: [:]) == 1)
    }

    @Test("Added plugins with work left need action, the rest are ready, the others are available to add")
    func groupsByWhatIsLeft() {
        let state = PluginsSurfacePresentation.makeState([
            input(package("zeta", name: "Zeta"), isEnabled: false),
            input(package("jira", name: "Jira"), isEnabled: true, pendingSteps: 1),
            input(package("github", name: "GitHub"), isEnabled: true),
            input(package("hidden", name: "Hidden"), isEnabled: false, isVisible: false),
            input(package("alpha", name: "Alpha"), isEnabled: false)
        ], query: "")

        #expect(state.actionNeeded.map(\.id) == ["jira"])
        #expect(state.actionNeeded.first?.subtitle == "1 step pending · 1 skill")
        #expect(state.actionNeeded.first?.verb == nil)
        #expect(state.ready.map(\.id) == ["github"])
        #expect(state.available.map(\.id) == ["alpha", "zeta"])
        #expect(state.available.allSatisfy { $0.verb == .add })
    }

    @Test("A draft plugin with a blocker approval can't clear names the blocker instead of offering Add")
    func hardBlockersReplaceAdd() {
        let workspace = Workspace(name: "Blocked", primaryPath: "/tmp/plugins-blocked")
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        let reviewable = package("draft", name: "Draft", governance: .localDraft())
        var blocked = package("blocked", name: "Blocked", governance: .localDraft())
        blocked.requires = ["base-capability"]
        let blockedDecision = CapabilityCatalogPolicy.decision(for: blocked, context: policy)
        #expect(blockedDecision.requiresApproval && blockedDecision.hasNonApprovalBlockers)

        let inputs = [reviewable, blocked].map { package in
            let listing = PluginsSurfacePresentation.listing(
                for: CapabilityCatalogPolicy.decision(for: package, context: policy), isEnabled: false
            )
            return PluginsSurfacePresentation.Input(
                package: package, isEnabled: false, pendingSteps: 0,
                isVisible: listing.isVisible, isRemovable: true, blocker: listing.blocker
            )
        }
        let state = PluginsSurfacePresentation.makeState(inputs, query: "")

        #expect(state.available.map(\.id) == ["blocked", "draft"])
        let blockedRow = state.available.first { $0.id == "blocked" }
        #expect(blockedRow?.verb == nil)
        #expect(blockedRow?.subtitle == "Capability requires base-capability to be installed or enabled first.")
        // Approval alone is what Add grants, so a plain draft still offers it.
        #expect(state.available.first { $0.id == "draft" }?.verb == .add)
    }

    /// The rescan lives in the view's lifecycle (no hosted view here), so
    /// its trigger is pinned in the source.
    @Test("A new working path rescans the surface's health")
    func workingPathChangeRescansHealth() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains(".onChange(of: workspace.resolvedWorkingPath) { _, _ in refreshStatuses() }"))
    }

    /// Docker Desktop stopping or a logout in Terminal fires no ASTRA event:
    /// both mounted surfaces rescan when ASTRA comes back to the front, once
    /// per burst of focus flips.
    @Test("Coming back to ASTRA rescans prerequisite health, at most once per interval")
    func activationRescansHealthThrottled() throws {
        var throttle = PrerequisiteActivationRescan()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = PrerequisiteActivationRescan.minimumInterval
        let decisions = [0, 1, interval - 1, interval, interval + 1].map { throttle.shouldRescan(at: start.addingTimeInterval($0)) }
        #expect(decisions == [true, false, false, true, false])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let surface = try String(contentsOf: root.appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift"), encoding: .utf8)
        #expect(surface.contains(".rescansPrerequisitesOnActivation { refreshStatuses() }"))
        let rail = try String(contentsOf: root.appendingPathComponent("Astra/Views/WorkspaceRightRailView.swift"), encoding: .utf8)
        #expect(rail.contains(".rescansPrerequisitesOnActivation { refreshCapabilityPrerequisiteStatuses() }"))
    }

    @Test("A repair that runs nothing shows its guidance before Check; one with a command shows the command")
    func proseOnlyRepairShowsGuidance() throws {
        let prose = RepairAction(
            strategy: .terminal, componentName: "Docker", title: "Docker", verb: "Check",
            detail: "Start Docker Desktop if the daemon is unreachable.", checkBinary: "docker"
        )
        let guidance = PluginsSurfacePresentation.repairGuidance(prose)
        #expect(guidance.text == "Start Docker Desktop if the daemon is unreachable.")
        #expect(!guidance.isCommand)
        var signIn = prose
        signIn.command = "gh auth login"
        #expect(PluginsSurfacePresentation.repairGuidance(signIn).text == "gh auth login")
        #expect(PluginsSurfacePresentation.repairGuidance(signIn).isCommand)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("let guidance = PluginsSurfacePresentation.repairGuidance(repair)"))
        #expect(!source.contains("if let command = repair.command {"))
    }

    @Test("Removing and deleting an account ask first; removing keeps accounts")
    func destructiveActionsConfirm() {
        let candidate = package("jira", name: "Jira")
        let display = PluginsSurfacePresentation.makeState([input(candidate, isEnabled: true)], query: "").allRows[0]
        let row = PluginRow(package: candidate, activation: nil, display: display)
        let remove = PluginsSurfaceConfirmation.remove(source: PluginRemovalSource(row: row), scope: PluginRemovalScope(pluginID: row.id, workspaces: [])).copy(name: "Jira")
        #expect(remove.verb == "Remove")
        #expect(remove.message.contains("every workspace"))
        #expect(remove.message.contains("saved keys stay"))
        let scope = PluginAccountDeletionScope(accountID: UUID(), workspaces: [
            .init(id: UUID(), name: "Ops"), .init(id: UUID(), name: "Research")
        ])
        let delete = PluginsSurfaceConfirmation.deleteAccount(packageID: "jira", scope: scope)
            .copy(name: "Jira 2")
        #expect(delete.verb == "Delete")
        #expect(delete.message.contains("saved keys") && delete.message.contains("Ops, Research"))
        #expect(delete.message.contains("Tasks already accepted may keep access until they finish or are cancelled"))
        #expect(delete.message.contains("revoke the credentials with the provider"))
    }

    @Test("A plugin that still runs an earlier definition offers Update and needs action")
    func outdatedPluginOffersUpdate() {
        var outdated = input(package("jira", name: "Jira"), isEnabled: true)
        outdated.needsUpdate = true
        let state = PluginsSurfacePresentation.makeState([outdated], query: "")
        #expect(state.actionNeeded.map(\.id) == ["jira"])
        #expect(state.actionNeeded.first?.verb == .update)
        #expect(state.actionNeeded.first?.subtitle.hasPrefix("Update to") == true)
    }

    @Test("Expanded plugin rows are remembered per workspace")
    func expansionIsRemembered() throws {
        let defaults = InMemoryDefaults()
        let first = UUID()
        let second = UUID()
        PluginsSurfacePreferences.setExpandedPluginIDs(["jira", "github"], workspaceID: first, in: defaults)
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: first, in: defaults) == ["jira", "github"])
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: second, in: defaults).isEmpty)
        PluginsSurfacePreferences.setExpandedPluginIDs([], workspaceID: first, in: defaults)
        #expect(PluginsSurfacePreferences.expandedPluginIDs(workspaceID: first, in: defaults).isEmpty)
    }

    @Test("A row projected from a standalone skill is not a library plugin, so it offers no Remove")
    @MainActor
    func projectedSkillRowsAreNotRemovable() {
        var synthetic = package("skill.1234", name: "My skill")
        synthetic.sourceMetadata = CapabilitySourceMetadata(id: "workspace", displayName: "Workspace", kind: "workspace", trustLevel: "local")
        #expect(!PluginsSurfaceView.isRemovable(synthetic))
        #expect(PluginsSurfaceView.isRemovable(package("imported.plugin", name: "Imported")))
    }

    @Test("A standalone skill's row turns off deleting nothing, and a workspace's own skill offers no Turn off")
    func standaloneSkillRowsTurnOffWithoutDeleting() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(container)
        let context = container.mainContext
        let workspace = Workspace(name: "Standalone", primaryPath: "/tmp/plugins-standalone")
        context.insert(workspace)
        let own = Skill(name: "Local Analyst", allowedTools: ["Read"])
        own.workspace = workspace
        // The shared row's connector matches this workspace's own one by
        // service, which the legacy disabler would delete with it.
        let sharedNotes = Connector(name: "Notes", serviceType: "notes")
        sharedNotes.isGlobal = true
        let shared = Skill(name: "Shared Analyst", allowedTools: ["Read"])
        shared.isGlobal = true
        let workspaceNotes = Connector(name: "Notes", serviceType: "notes")
        workspaceNotes.workspace = workspace
        [own, shared].forEach { context.insert($0) }
        [sharedNotes, workspaceNotes].forEach { context.insert($0) }
        shared.connectors = [sharedNotes]
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableGlobalSkill(shared.id.uuidString)
            $0.enableGlobalConnector(sharedNotes.id.uuidString)
        }
        try context.save()
        let capabilities = WorkspaceCapabilities(workspace: workspace, globalSkills: [shared], globalConnectors: [sharedNotes])
        let rows = CapabilityCatalogInventory.configuredPackages(catalogPackages: [], capabilities: capabilities, workspace: workspace)
        let ownRow = try #require(rows.first { $0.id == "skill.\(own.id.uuidString.lowercased())" })
        let sharedRow = try #require(rows.first { $0.id == "skill.\(shared.id.uuidString.lowercased())" })
        let setup = PluginRow(package: sharedRow, activation: nil,
            display: PluginsSurfaceRow(id: sharedRow.id, name: sharedRow.name, icon: sharedRow.icon,
                subtitle: "", pendingSteps: 1, isEnabled: true, isRemovable: false, verb: nil))
        let attached = CapabilityPackageState(package: sharedRow, workspace: workspace, capabilities: capabilities)
        #expect(attached.linkedConnectors.map(\.id).contains(sharedNotes.id))
        #expect(PluginsSurfacePresentation.expandedSetupComponents(for: setup).contains { $0.component.kind == .connector })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-standalone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CapabilityCatalogActionService(library: CapabilityLibrary(directory: root))

        #expect(!PluginsSurfacePresentation.offersTurnOff(ownRow))
        #expect(!service.disable(ownRow, workspace: workspace, modelContext: context).persisted)
        #expect(PluginsSurfacePresentation.offersTurnOff(sharedRow))
        #expect(service.disable(sharedRow, workspace: workspace, modelContext: context).persisted)

        #expect(!workspace.enabledGlobalSkillIDs.contains(shared.id.uuidString))
        #expect(Set(try context.fetch(FetchDescriptor<Skill>()).map(\.id)) == [own.id, shared.id])
        #expect(Set(try context.fetch(FetchDescriptor<Connector>()).map(\.id)) == [sharedNotes.id, workspaceNotes.id])
    }

    @Test("Search reaches inside a plugin: bigquery finds Google Cloud through its bq tool")
    func searchReachesComponents() throws {
        let gcloud = try builtIn("gcloud-workflow")
        #expect(PluginsSurfacePresentation.matches(gcloud, query: "bigquery"))
        #expect(PluginsSurfacePresentation.matches(gcloud, query: "gsutil"))
        #expect(!PluginsSurfacePresentation.matches(gcloud, query: "redcap"))
        let workspace = try builtIn("google-workspace")
        #expect(PluginsSurfacePresentation.matches(workspace, query: "gmail"))
    }

    @Test("Adding a draft plugin writes the person's approval, then enables it here")
    func addApprovesThenEnables() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Add", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root.appendingPathComponent("library"))
        let approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals"))
        let draft = package("draft-plugin", name: "Draft Plugin", governance: .localDraft())
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        #expect(!CapabilityCatalogPolicy.decision(for: draft, context: policy).canEnable)

        try CapabilityCatalogActionService(library: library).add(
            draft, workspace: workspace, modelContext: context,
            policyContext: policy, approvalStore: approvals, traceID: "trace-add"
        )

        let record = try #require(approvals.records().first { $0.packageID == draft.id })
        #expect(record.status == .approved)
        #expect(record.approvedBy == "user")
        #expect(WorkspaceCapabilityActivation.state(of: workspace).capabilityIDs == [draft.id])
        withExtendedLifetime(container) {}
    }

    @Test("Add's one-step approval is audited with its digest, and so is a failed one")
    func addAuditsTheApprovalItGrants() throws {
        let workspace = Workspace(name: "Audit", primaryPath: "/tmp/plugins-add-audit")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-add-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = package("draft-audited", name: "Draft Audited", governance: .localDraft())
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [])
        let service = CapabilityCatalogActionService(library: CapabilityLibrary(directory: root.appendingPathComponent("library")))
        func audits(_ traceID: String) -> [String] {
            AppLogger.flushForTesting()
            return AppLogger.entries.map(\.message).filter {
                $0.contains(AuditEvent.capabilityApprovalChanged.rawValue) && $0.contains("trace_id=\(traceID)")
            }
        }

        let granted = AuditTrace.make("grant")
        let approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals"))
        _ = try service.grantPendingApproval(
            for: draft, workspace: workspace, policyContext: policy, approvalStore: approvals,
            source: "plugins_add_connect_account", traceID: granted
        )
        let record = try #require(approvals.records().first { $0.packageID == draft.id })
        let success = try #require(audits(granted).first)
        for field in [
            "status=approved", "package_id=draft-audited", "workspace_id=\(workspace.id.uuidString)",
            "digest_prefix=\(record.sourceDigest.prefix(12))", "source=plugins_add_connect_account"
        ] {
            #expect(success.contains(field), "missing \(field)")
        }
        #expect(!success.contains("result=failed"))

        // A store it can't write to: the attempt is audited as failed.
        let failed = AuditTrace.make("grant-failed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) {
            try service.grantPendingApproval(
                for: draft, workspace: workspace, policyContext: policy,
                approvalStore: CapabilityApprovalStore(directory: blocker), source: "plugins_add", traceID: failed
            )
        }
        let failure = try #require(audits(failed).first)
        #expect(failure.contains("result=failed"))
        #expect(failure.contains("package_id=draft-audited"))
    }

    @Test("Turning a plugin off in Plugins is audited like Configure's disable")
    func turnOffIsAudited() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-turn-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Turn Off", primaryPath: root.path)
        context.insert(workspace)
        let plugin = package("turn-off-plugin", name: "Turn Off Plugin")
        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs = [plugin.id, "kept-plugin"] }
        try context.save()
        let traceID = AuditTrace.make("turn-off")

        let result = CapabilityCatalogActionService().disable(
            plugin, workspace: workspace,
            modelContext: context, traceID: traceID
        )

        #expect(result.persisted)
        AppLogger.flushForTesting()
        let audit = try #require(AppLogger.entries.map(\.message).first {
            $0.contains(AuditEvent.capabilityDisabled.rawValue) && $0.contains("trace_id=\(traceID)")
        })
        for field in [
            "source=plugins_turn_off", "package_id=turn-off-plugin", "package_version=1.0.0",
            "workspace_id=\(workspace.id.uuidString)", "removed_workspace_skills_count=0", "enabled_capability_ids=kept-plugin"
        ] {
            #expect(audit.contains(field), "missing \(field)")
        }
        withExtendedLifetime(container) {}
    }

    @Test("Add connects a supported account first, and refuses one ASTRA can't sign in to")
    func addRefusesUnsupportedOAuthProviders() throws {
        #expect(try CapabilityCatalogActionService.addRoute(for: builtIn("google-workspace")) == .connectAccount)
        #expect(try CapabilityCatalogActionService.addRoute(for: builtIn("jira-workflow")) == .enable)
        let google = try #require(try builtIn("google-workspace").setupRequirements.first)
        for provider in ["salesforce", nil] {
            let account = PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: provider)
            for requirements in [[account], [google, account]] {
                var imported = package("imported-crm", name: "CRM")
                imported.setupRequirements = requirements
                #expect(throws: CapabilityAccountSetupError.unsupportedProvider(account: "CRM account", provider: provider)) {
                    try CapabilityCatalogActionService.addRoute(for: imported)
                }
            }
        }

        // The one-step Add refuses it too, before approving or enabling.
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Add", primaryPath: "/tmp/plugins-add-oauth")
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-add-oauth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let approvals = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals"))
        var imported = package("imported-crm", name: "CRM", governance: .localDraft())
        imported.setupRequirements = [PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: "salesforce")]
        #expect(throws: CapabilityAccountSetupError.self) {
            try CapabilityCatalogActionService(library: CapabilityLibrary(directory: root.appendingPathComponent("library"))).add(
                imported, workspace: workspace, modelContext: context,
                policyContext: .currentUser(workspace: workspace, approvalRecords: []),
                approvalStore: approvals, traceID: "trace-add-oauth"
            )
        }
        #expect(approvals.records().isEmpty)
        #expect(WorkspaceCapabilityActivation.state(of: workspace).capabilityIDs.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("The legacy catalog's enable refuses an account ASTRA can't sign in to")
    func legacyEnableRefusesUnsupportedOAuthProviders() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Legacy", primaryPath: "/tmp/plugins-legacy-oauth")
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-legacy-oauth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root.appendingPathComponent("library"))
        var imported = package("imported-crm", name: "CRM")
        imported.setupRequirements = [PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: "salesforce")]
        // `PluginInstallSheet` (the router's fallback) and Configure call this.
        #expect(throws: CapabilityAccountSetupError.self) {
            try CapabilityCatalogActionService(library: library).enable(
                imported, workspace: workspace, modelContext: context,
                policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
                source: "setup_sheet", traceID: "trace-legacy-oauth"
            )
        }
        #expect(library.installedPackages().isEmpty)
        #expect(WorkspaceCapabilityActivation.state(of: workspace).capabilityIDs.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("An optional account neither sends Add through account setup nor refuses it")
    func addIgnoresOptionalOAuthRequirements() throws {
        let google = try #require(try builtIn("google-workspace").setupRequirements.first)
        for provider in [google.provider, "salesforce"] {
            var imported = package("imported-optional", name: "Optional")
            imported.setupRequirements = [
                PluginSetupRequirement(id: "acct", kind: .oauthAccount, displayName: "Account", provider: provider, required: false)
            ]
            #expect(try CapabilityCatalogActionService.addRoute(for: imported) == .enable)
        }
    }

    @Test("A pending account offers Reconnect only when Add can sign in to it")
    func pendingAccountOffersReconnectOnlyForSupportedProviders() throws {
        let google = try builtIn("google-workspace")
        #expect(PluginsSurfacePresentation.pendingAccountAction(for: google) == .reconnect)
        let googleAccount = try #require(google.setupRequirements.first)
        for provider in ["salesforce", nil] {
            let account = PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: provider)
            // Alone, or beside a Google account Add could connect: Add
            // refuses the plugin, so the row says why and offers nothing.
            for requirements in [[account], [googleAccount, account]] {
                var crm = package("imported-crm", name: "CRM")
                crm.setupRequirements = requirements
                #expect(!PluginsSurfacePresentation.pendingAccounts(for: crm, googleAccountConnected: false).isEmpty)
                let expected = CapabilityAccountSetupError.unsupportedProvider(account: "CRM account", provider: provider)
                #expect(PluginsSurfacePresentation.pendingAccountAction(for: crm) == .unsupported(try #require(expected.errorDescription)))
                #expect(throws: expected) { try CapabilityCatalogActionService.addRoute(for: crm) }
            }
        }
        // The row reads it from that rule, not a copy of it.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("switch PluginsSurfacePresentation.pendingAccountAction(for: package) {"))
        #expect(source.components(separatedBy: "Button(\"Reconnect\")").count == 2)
    }

    @Test("A required account with no working sign-in is a pending step")
    func requiredOAuthAccountsArePendingUntilConnected() throws {
        let google = try builtIn("google-workspace")
        #expect(PluginsSurfacePresentation.pendingAccounts(for: google, googleAccountConnected: false).count == 1)
        #expect(PluginsSurfacePresentation.pendingAccounts(for: google, googleAccountConnected: true).isEmpty)
        var optional = google
        optional.setupRequirements = optional.setupRequirements.map { var r = $0; r.required = false; return r }
        #expect(PluginsSurfacePresentation.pendingAccounts(for: optional, googleAccountConnected: false).isEmpty)
        var crm = package("imported-crm", name: "CRM")
        crm.setupRequirements = [PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM", provider: "salesforce")]
        #expect(PluginsSurfacePresentation.pendingAccounts(for: crm, googleAccountConnected: true).map(\.id) == ["crm"])

        // Connected means the runtime can still get a token: an expired one
        // refreshes, a revoked or lost one does not.
        let scopes = GoogleWorkspaceSetupStateFactory.requiredScopes
        let active = GoogleOAuthAccountProfile(subject: "1", email: "a@example.com", grantedScopes: scopes)
        #expect(GoogleWorkspaceCapability.isAccountConnected(active, credentialStatus: .expiredToken, hasRefreshToken: true))
        #expect(GoogleWorkspaceCapability.isAccountConnected(active, credentialStatus: nil, hasRefreshToken: true))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(active, credentialStatus: .missingAccount, hasRefreshToken: true))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(active, credentialStatus: .revokedToken, hasRefreshToken: true))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(nil, credentialStatus: nil, hasRefreshToken: true))
        for state in [GoogleOAuthAccountAuthState.needsReauth, .revoked] {
            let stale = GoogleOAuthAccountProfile(subject: "2", email: "b@example.com", grantedScopes: scopes, authState: state)
            #expect(!GoogleWorkspaceCapability.isAccountConnected(stale, credentialStatus: .expiredToken, hasRefreshToken: true))
        }
    }

    @Test("An expired token counts as connected only while a refresh token is stored")
    func expiredTokenWithoutRefreshTokenIsNotConnected() throws {
        let scopes = GoogleWorkspaceSetupStateFactory.requiredScopes
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for refreshToken in ["1//refresh", nil] {
            let profile = GoogleOAuthAccountProfile(subject: "1", email: "a@example.com", grantedScopes: scopes)
            let vault = GoogleOAuthCredentialVault(secretStore: MockSecretStore())
            try vault.save(
                GoogleOAuthTokenSet(accessToken: "ya29.access", refreshToken: refreshToken, expiresAt: now, grantedScopes: scopes),
                for: profile, now: now
            )
            let status = vault.credentialStatus(for: profile, now: now.addingTimeInterval(60))
            #expect(status == .expiredToken)
            #expect(vault.hasRefreshToken(for: profile) == (refreshToken != nil))
            let connected = GoogleWorkspaceCapability.isAccountConnected(
                profile, credentialStatus: status, hasRefreshToken: vault.hasRefreshToken(for: profile)
            )
            #expect(connected == (refreshToken != nil), "refresh token: \(refreshToken ?? "none")")
        }
    }

    @Test("A cached access token that has since expired counts only while a refresh token is stored")
    func cachedStatusExpiresWithItsToken() throws {
        let scopes = GoogleWorkspaceSetupStateFactory.requiredScopes
        let profile = GoogleOAuthAccountProfile(subject: "1", email: "a@example.com", grantedScopes: scopes)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = GoogleOAuthCredentialStatus.available(expiresAt: now, grantedScopes: scopes)
        #expect(GoogleWorkspaceCapability.isAccountConnected(profile, credentialStatus: cached, hasRefreshToken: false, now: now.addingTimeInterval(-60)))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(profile, credentialStatus: cached, hasRefreshToken: false, now: now))
        #expect(GoogleWorkspaceCapability.isAccountConnected(profile, credentialStatus: cached, hasRefreshToken: true, now: now.addingTimeInterval(60)))
        // The surface reads the Keychain again when the cached token expires.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains(".task(id: googleCredentialExpiry) { await refreshGoogleCredential(at: googleCredentialExpiry) }"))
    }

    @Test("An account missing a newly required Workspace scope is a pending step, not Ready")
    func missingOAuthScopesArePending() throws {
        let google = try builtIn("google-workspace")
        let required = GoogleWorkspaceSetupStateFactory.requiredScopes
        let gmail = try #require(required.first { $0.contains("gmail") })
        let lacking = GoogleOAuthAccountProfile(subject: "1", email: "a@example.com", grantedScopes: required.filter { $0 != gmail })
        let full = GoogleOAuthAccountProfile(subject: "2", email: "b@example.com", grantedScopes: required)
        let expires = Date().addingTimeInterval(3_600)
        // The runtime refuses a token without the scope, whichever side lacks it.
        #expect(!GoogleWorkspaceCapability.isAccountConnected(lacking, credentialStatus: .available(expiresAt: expires, grantedScopes: required), hasRefreshToken: true))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(lacking, credentialStatus: nil, hasRefreshToken: true))
        #expect(!GoogleWorkspaceCapability.isAccountConnected(full, credentialStatus: .available(expiresAt: expires, grantedScopes: []), hasRefreshToken: true))
        #expect(GoogleWorkspaceCapability.isAccountConnected(full, credentialStatus: .available(expiresAt: expires, grantedScopes: required), hasRefreshToken: true))
        let connected = GoogleWorkspaceCapability.isAccountConnected(lacking, credentialStatus: .expiredToken, hasRefreshToken: true)
        #expect(PluginsSurfacePresentation.pendingAccounts(for: google, googleAccountConnected: connected).count == 1)
    }

    @Test("The preview is on by default in development builds only, and remembers a choice")
    func previewFlagDefaultsByChannel() {
        let defaults = InMemoryDefaults()
        #expect(PluginsSurfacePreferences.isEnabled(in: defaults, channel: .development))
        #expect(!PluginsSurfacePreferences.isEnabled(in: defaults, channel: .production))
        PluginsSurfacePreferences.setEnabled(true, in: defaults)
        #expect(PluginsSurfacePreferences.isEnabled(in: defaults, channel: .production))
    }

    // MARK: - Fixtures

    private func input(
        _ package: PluginPackage,
        isEnabled: Bool,
        pendingSteps: Int = 0,
        isVisible: Bool = true
    ) -> PluginsSurfacePresentation.Input {
        PluginsSurfacePresentation.Input(
            package: package, isEnabled: isEnabled, pendingSteps: pendingSteps,
            isVisible: isVisible, isRemovable: true
        )
    }

    private func package(_ id: String, name: String, governance: CapabilityGovernance = .builtInApproved()) -> PluginPackage {
        PluginPackage(
            id: id, name: name, icon: "puzzlepiece.extension", description: "\(name) plugin",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "\(name) Agent", icon: "sparkles", description: "", allowedTools: ["Read"],
                    disallowedTools: [], customTools: [], behaviorInstructions: "Help.",
                    environmentKeys: [], environmentValues: []
                )
            ],
            connectors: [], localTools: [], templates: [], governance: governance
        )
    }

    private func builtIn(_ id: String) throws -> PluginPackage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Resources/Capabilities/\(id).json")
        return try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: url))
    }

    @Test("A manifest of another version, or one restricting a runtime ASTRA can't enforce, is refused")
    func manifestsFailClosed() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var future = PluginManifestConverter.manifest(from: jira)
        future.manifestVersion = 2
        #expect(throws: PluginManifestError.unsupportedVersion(2)) { try PluginManifestConverter.checkedPackage(from: future) }
        var restricted = PluginManifestConverter.manifest(from: jira)
        restricted.worksOn["cursor_cli"] = .unsupported
        #expect(throws: PluginManifestError.unenforcedRuntimeRestriction(runtime: "cursor_cli")) {
            try PluginManifestConverter.checkedPackage(from: restricted)
        }
        #expect((try? PluginManifestConverter.checkedPackage(from: PluginManifestConverter.manifest(from: jira))) != nil)
    }

    @Test("A runtime the manifest's support matrix leaves out counts as unsupported, so the manifest is refused")
    func incompleteRuntimeMatrixIsRefused() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var incomplete = PluginManifestConverter.manifest(from: jira)
        incomplete.worksOn["cursor_cli"] = nil
        #expect(throws: PluginManifestError.unenforcedRuntimeRestriction(runtime: "cursor_cli")) {
            try PluginManifestConverter.checkedPackage(from: incomplete)
        }
        // A runtime this build doesn't know neither restricts nor refuses.
        var extra = PluginManifestConverter.manifest(from: jira)
        extra.worksOn["future_cli"] = .unsupported
        #expect(throws: Never.self) { try PluginManifestConverter.checkedPackage(from: extra) }
    }

    @Test("A manifest that conditions a runtime on a recent CLI where ASTRA derives full is refused")
    func recentCLIConditionIsNotDropped() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var conditional = PluginManifestConverter.manifest(from: jira)
        #expect(conditional.worksOn["cursor_cli"] == .full)
        conditional.worksOn["cursor_cli"] = .fullWithRecentCLI
        #expect(throws: PluginManifestError.unenforcedRuntimeRestriction(runtime: "cursor_cli")) {
            try PluginManifestConverter.checkedPackage(from: conditional)
        }
    }

    @Test("A manifest component must carry exactly its kind's definition")
    func manifestPayloadsMatchKinds() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var manifest = PluginManifestConverter.manifest(from: jira)
        let skillIndex = try #require(manifest.components.firstIndex { $0.kind == .skill })
        manifest.components[skillIndex].skill = nil
        #expect(throws: PluginManifestError.self) { try PluginManifestConverter.checkedPackage(from: manifest) }
        var extra = PluginManifestConverter.manifest(from: jira)
        extra.components[skillIndex].tool = PluginLocalTool(name: "x", description: "", icon: "terminal", toolType: "cli", command: "x", arguments: "")
        #expect(throws: PluginManifestError.self) { try PluginManifestConverter.checkedPackage(from: extra) }
    }

    @Test("A repair or install link opens only an https page")
    func repairURLsAreWebPages() throws {
        #expect(RepairAction.isSafeRepairURL(try #require(URL(string: "https://cloud.google.com/sdk"))))
        for unsafe in ["file:///etc/passwd", "smb://share/x", "x-custom://open", "http://example.com"] {
            #expect(!RepairAction.isSafeRepairURL(try #require(URL(string: unsafe))), "\(unsafe)")
        }
        var package = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        package.prerequisites[0].installURL = URL(string: "file:///Applications/Calculator.app")
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Unsafe install link" })
    }

    @Test("Importing a Plugins 2.0 manifest file decodes it as a package")
    func manifestFilesImport() throws {
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let data = try JSONEncoder().encode(PluginManifestConverter.manifest(from: jira))
        let report = CapabilityPackageValidator.validate(data: data, installedPackages: [], checkPrerequisites: false)
        #expect(report.package?.id == "jira-workflow")
        #expect(report.package?.connectors.count == jira.connectors.count)
    }
}
