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
        let workspace = Workspace(name: "Add", primaryPath: "/tmp/plugins-add")
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
