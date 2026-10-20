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
    private static var retained: [ModelContainer] = []

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

    @Test("A held import is a row under Action needed: named, saying what it waits for, with Add only for the copy it waits for")
    func heldImportsArePresented() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(container)
        let workspace = Workspace(name: "Held", primaryPath: "/tmp/plugins-held")
        container.mainContext.insert(workspace)
        let installed = package("notes", name: "Notes")
        func hold(_ id: String, digest: String, source: String?, recovered: Bool? = nil) {
            var pending = RetiredPluginActivation.PendingImport(
                digest: digest, source: source, settings: nil, overriddenComponentIDs: nil,
                overridingRowIDs: nil, accounts: nil, knownComponentIDs: nil
            )
            pending.recovered = recovered
            WorkspaceCapabilityActivation.recordPendingImport(pending, pluginID: id, in: workspace)
        }
        hold("notes", digest: "same", source: "plugin-source:a")
        hold("absent", digest: "x", source: nil)
        func rows(installedSource: String?) -> [PluginsSurfaceHeldImport] {
            PluginsSurfacePresentation.heldImports(
                in: workspace, installed: [installed],
                source: { _ in installedSource },
                matches: { pending, package in pending.digest == "same" && pending.source == installedSource },
                sourceName: { $0 == nil ? "a local file" : "Acme Plugins" }
            )
        }
        var listed = rows(installedSource: "plugin-source:a")
        #expect(listed.map(\.id) == ["held-import:absent", "held-import:notes"])
        #expect(listed[0].name == "absent" && !listed[0].canAdd)
        #expect(listed[0].subtitle == "Settings from an imported workspace file, waiting for it from a local file. Install it to bring them back, or discard them.")
        #expect(listed[1].name == "Notes" && listed[1].canAdd)
        #expect(listed[1].subtitle == "Settings from an imported workspace file. Add it to bring them back, or discard them.")
        // The installed copy is from elsewhere: no Add, and both places named.
        listed = rows(installedSource: nil)
        #expect(!listed[1].canAdd)
        #expect(listed[1].subtitle == "Settings from an imported workspace file are for its copy from Acme Plugins, and the one installed is from a local file. Discard them, or install that copy.")
        // Another version from the same source.
        hold("notes", digest: "other", source: "plugin-source:a")
        listed = rows(installedSource: "plugin-source:a")
        #expect(!listed[1].canAdd && listed[1].subtitle.contains("another version"))
        // Already on here, and the copy matches: it comes back at launch.
        hold("notes", digest: "same", source: "plugin-source:a", recovered: true)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("notes")
            $0.recordInstalledPlugin(id: "notes", version: "1.0.0")
        }
        listed = rows(installedSource: "plugin-source:a")
        #expect(!listed[1].canAdd)
        #expect(listed[1].subtitle == "Settings this workspace had come back the next time ASTRA starts, or discard them.")
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
        let remove = PluginsSurfaceConfirmation.remove(packageID: "jira").copy(name: "Jira")
        #expect(remove.verb == "Remove")
        #expect(remove.message.contains("every workspace"))
        #expect(remove.message.contains("saved keys stay"))
        let delete = PluginsSurfaceConfirmation.deleteAccount(packageID: "jira", accountID: UUID())
            .copy(name: "Jira 2", workspaces: ["Ops", "Research"])
        #expect(delete.verb == "Delete")
        #expect(delete.message.contains("saved keys") && delete.message.contains("Ops, Research"))
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
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-plugins-standalone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CapabilityCatalogActionService(library: CapabilityLibrary(directory: root))

        #expect(!PluginsSurfacePresentation.offersTurnOff(ownRow))
        #expect(!service.disable(ownRow, workspace: workspace, capabilities: capabilities, modelContext: context).persisted)
        #expect(PluginsSurfacePresentation.offersTurnOff(sharedRow))
        #expect(service.disable(sharedRow, workspace: workspace, capabilities: capabilities, modelContext: context).persisted)

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
        let traceID = AuditTrace.make("turn-off")

        let result = CapabilityCatalogActionService().disable(
            plugin, workspace: workspace,
            capabilities: WorkspaceCapabilities(workspace: workspace, globalSkills: []),
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

    @Test("Add refuses a plugin that needs an account sign-in, which this build has none of")
    func addRefusesUnsupportedOAuthProviders() throws {
        #expect(throws: CapabilityAccountSetupError.self) {
            try CapabilityCatalogActionService.validateAccountSupport(for: builtIn("google-workspace"))
        }
        try CapabilityCatalogActionService.validateAccountSupport(for: builtIn("jira-workflow"))
        for provider in ["salesforce", nil] {
            var imported = package("imported-crm", name: "CRM")
            imported.setupRequirements = [PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: provider)]
            #expect(throws: CapabilityAccountSetupError.unsupportedProvider(account: "CRM account", provider: provider)) {
                try CapabilityCatalogActionService.validateAccountSupport(for: imported)
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
            try CapabilityCatalogActionService.validateAccountSupport(for: imported)
        }
    }

    @Test("A pending account offers Reconnect only when Add can sign in to it")
    func pendingAccountOffersReconnectOnlyForSupportedProviders() throws {
        // R4 has no sign-in flow for any provider (`supportedOAuthProviders`
        // is empty), so even the Google account gets the reason, no button.
        let google = try builtIn("google-workspace")
        let googleAccount = try #require(google.setupRequirements.first)
        let googleRefused = CapabilityAccountSetupError.unsupportedProvider(
            account: googleAccount.displayName, provider: googleAccount.provider
        )
        #expect(PluginsSurfacePresentation.pendingAccountAction(for: google) == .unsupported(try #require(googleRefused.errorDescription)))
        for provider in ["salesforce", nil] {
            let account = PluginSetupRequirement(id: "crm", kind: .oauthAccount, displayName: "CRM account", provider: provider)
            // Alone, or beside a Google account Add could connect: Add
            // refuses the plugin, so the row says why and offers nothing.
            for requirements in [[account], [googleAccount, account]] {
                var crm = package("imported-crm", name: "CRM")
                crm.setupRequirements = requirements
                #expect(!PluginsSurfacePresentation.pendingAccounts(for: crm, googleAccountConnected: false).isEmpty)
                // Add names the first account it can't sign in to.
                let expected = requirements.first?.id == googleAccount.id
                    ? googleRefused
                    : CapabilityAccountSetupError.unsupportedProvider(account: "CRM account", provider: provider)
                #expect(PluginsSurfacePresentation.pendingAccountAction(for: crm) == .unsupported(try #require(expected.errorDescription)))
                #expect(throws: expected) { try CapabilityCatalogActionService.validateAccountSupport(for: crm) }
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
