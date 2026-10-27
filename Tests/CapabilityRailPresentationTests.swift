import Foundation
import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels

@Suite("Capability Rail Presentation")
struct CapabilityRailPresentationTests {
    @Test("ready enabled package uses details action without noisy default badge")
    func readyEnabledPackageUsesDetailsActionWithoutDefaultBadge() {
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: true,
            readinessLevel: .ready,
            workspaceName: "Jira Support",
            sharedResourceCount: 2,
            workspaceResourceCount: 1,
            declaredResourceCount: 3,
            contentSummary: "1 skill, 1 connector, 1 browser adapter"
        )

        #expect(presentation.statusLabel == nil)
        #expect(presentation.actionTitle == "Details")
        #expect(presentation.rowSubtitle == "1 skill, 1 connector, 1 browser adapter")
        #expect(presentation.scopeValues == [
            "Enabled for Jira Support",
            "Uses 2 shared resources reusable in other workspaces",
            "Uses 1 workspace resource that can differ here"
        ])
    }

    @Test("package with missing setup keeps row-level setup badge")
    func needsAttentionKeepsRowLevelSetupBadge() {
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: true,
            readinessLevel: .needsAttention,
            workspaceName: "Secure Workspace",
            sharedResourceCount: 1,
            workspaceResourceCount: 0,
            declaredResourceCount: 1,
            contentSummary: "1 connector"
        )

        #expect(presentation.statusLabel == "Needs setup")
        #expect(presentation.actionTitle == "Details")
        #expect(presentation.scopeValues == [
            "Enabled for Secure Workspace",
            "Uses 1 shared resource reusable in other workspaces"
        ])
    }

    @Test("disabled package is available but not active in workspace")
    func disabledPackageIsAvailableNotActive() {
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: false,
            readinessLevel: .inactive,
            workspaceName: "Research",
            sharedResourceCount: 0,
            workspaceResourceCount: 0,
            declaredResourceCount: 2,
            contentSummary: ""
        )

        #expect(presentation.statusLabel == "Available")
        #expect(presentation.actionTitle == "Details")
        #expect(presentation.rowSubtitle == "2 declared resources")
        #expect(presentation.scopeValues == [
            "Available in the library; not active here",
            "Installing links the declared package resources to this workspace"
        ])
    }

    @Test("blank workspace name falls back to this workspace")
    func blankWorkspaceNameUsesFallbackScopeLabel() {
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: true,
            readinessLevel: .ready,
            workspaceName: "  ",
            sharedResourceCount: 0,
            workspaceResourceCount: 0,
            declaredResourceCount: 0,
            contentSummary: ""
        )

        #expect(presentation.scopeValues == ["Enabled for this workspace"])
        #expect(presentation.rowSubtitle == "Capability available to tasks")
    }

    @Test("capability composition summary includes MCP servers")
    func capabilityCompositionSummaryIncludesMCPServers() {
        let package = PluginPackage(
            id: "mcp-visible",
            name: "MCP Visible",
            icon: "server.rack",
            description: "MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "github",
                    displayName: "GitHub MCP",
                    transport: .stdio,
                    command: "github-mcp-server"
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )
        let item = RailCapabilityItem(
            id: "package:mcp-visible",
            name: "MCP Visible",
            icon: "server.rack",
            summary: "MCP package",
            color: Stanford.lagunita,
            isEnabled: true,
            readiness: .ready,
            presentation: CapabilityRailPackagePresentation.make(
                isEnabled: true,
                readinessLevel: .ready,
                workspaceName: "Workspace",
                sharedResourceCount: 0,
                workspaceResourceCount: 0,
                declaredResourceCount: 1,
                contentSummary: "1 MCP server"
            ),
            source: .package(package),
            skillNames: [],
            connectorNames: [],
            toolNames: [],
            mcpServerNames: ["GitHub MCP"],
            browserAdapterNames: [],
            templateNames: [],
            requirementNames: []
        )

        #expect(WorkspaceRightRailPresentation.compositionSummary(for: item) == "1 MCP server")
    }

    @Test("workspace context uses desktop inspector density")
    func workspaceContextUsesDesktopInspectorDensity() {
        // The Repository and Container cards share the v2 box title size until
        // the Environment box absorbs them.
        #expect(CapabilityRailLayout.sectionTitleFontSize == 13)
        #expect(CapabilityRailLayout.sectionTitleFontSize == WorkspaceRailSectionPresentation.Layout.boxTitleFontSize)
        #expect(CapabilityRailLayout.rowTitleFontSize == 14)
        #expect(CapabilityRailLayout.rowSubtitleFontSize == 12)
        #expect(CapabilityRailLayout.rowTitleFontSize < Stanford.chatBodyPointSize)
        #expect(CapabilityRailLayout.sectionTitleFontSize < Stanford.chatBodyPointSize)
        #expect(CapabilityRailLayout.regularSectionPadding == 16)
        #expect(CapabilityRailLayout.regularPanelSpacing == 12)
        #expect(CapabilityRailLayout.regularGroupSpacing == 12)
    }

    @Test("repository and container rows keep their v1 density until the Environment box absorbs them")
    func repositoryAndContainerRowsKeepV1Density() {
        #expect(CapabilityRailLayout.minimumTwoLineRowHeight > 34)
        #expect(CapabilityRailLayout.rowMinHeight(isCompact: true) >= CapabilityRailLayout.minimumTwoLineRowHeight)
        #expect(CapabilityRailLayout.rowMinHeight(isCompact: false) == 56)
        #expect(CapabilityRailLayout.rowMinHeight(isCompact: true) == 60)
        #expect(CapabilityRailLayout.summaryRowMinHeight == 58)
        #expect(CapabilityRailLayout.setupRowMinHeight == 56)
        #expect(CapabilityRailLayout.leadingIconFontSize == 16)
        #expect(CapabilityRailLayout.leadingIconFrame == 30)
        #expect(CapabilityRailLayout.dividerLeadingPadding(isCompact: false) == CapabilityRailLayout.leadingIconFrame)
    }

    @Test("capability groups use full section width without nested table chrome")
    func capabilityGroupsUseFullSectionWidthWithoutNestedTableChrome() {
        #expect(CapabilityRailLayout.usesNestedGroupChrome == false)
        #expect(CapabilityRailLayout.groupHorizontalPadding(isCompact: true) == 0)
        #expect(CapabilityRailLayout.groupHorizontalPadding(isCompact: false) == 0)
    }

    @Test("workspace context panel uses simple semantic icons")
    func workspaceContextPanelUsesSimpleSemanticIcons() {
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Bigquery Analyst", fallback: "puzzlepiece") == "cylinder.split.1x2")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Read-Only", fallback: "lock.shield") == "eye")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Safe Bash", fallback: "shield") == "terminal")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Google Cloud", fallback: "cloud") == "cloud")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Untitled Capability", fallback: "  ") == "puzzlepiece.extension")
    }

    @Test("a new working path rescans the rail's contextual repairs")
    func workingPathChangeRescansRailPrerequisites() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Astra/Views/WorkspaceRightRailView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains(".onChange(of: workspace.resolvedWorkingPath) { _, _ in refreshCapabilityPrerequisiteStatuses() }"))
    }

    @Test("repository rail exposes git controls by default")
    func repositoryRailExposesGitControlsByDefault() {
        #expect(WorkspaceGitPanelPresentation.startsCollapsed == false)
        #expect(WorkspaceGitPanelPresentation.collapsedVisibleRowCount == 1)
        #expect(WorkspaceGitPanelPresentation.expandedDetailRowCount == 6)
        #expect(WorkspaceGitPanelPresentation.repositorySelectorRowMinHeight == 50)
        #expect(WorkspaceGitPanelPresentation.detailRowMinHeight == 44)
        #expect(WorkspaceGitPanelPresentation.detailRowMinHeight < CapabilityRailLayout.setupRowMinHeight)
        #expect(WorkspaceGitPanelPresentation.showDetailsActionTitle == "Show controls")
        #expect(WorkspaceGitPanelPresentation.hideDetailsActionTitle == "Hide")
    }

    @Test("workspace instruction editor distinguishes draft from saved guidance")
    func workspaceInstructionEditorDistinguishesDraftFromSavedGuidance() {
        #expect(WorkspaceInstructionEditorPresentation.saveActionTitle == "Save")
        #expect(WorkspaceInstructionEditorPresentation.clearActionTitle == "Clear")
        #expect(WorkspaceInstructionEditorPresentation.savedStatusTitle == "Saved")
        #expect(WorkspaceInstructionEditorPresentation.unsavedStatusTitle == "Unsaved changes")
        #expect(
            WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
                draft: "  Run focused tests before full suites.  ",
                persisted: ""
            ) == true
        )
        #expect(
            WorkspaceInstructionEditorPresentation.persistedInstructions(
                fromDraft: "  Run focused tests before full suites.  "
            ) == "Run focused tests before full suites."
        )
        #expect(
            WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
                draft: "Run focused tests before full suites.",
                persisted: "Run focused tests before full suites."
            ) == false
        )
        #expect(
            WorkspaceInstructionEditorPresentation.statusTitle(
                draft: "Run focused tests before full suites.",
                persisted: "Run focused tests before full suites.",
                didRecentlySave: true
            ) == "Saved"
        )
        #expect(
            WorkspaceInstructionEditorPresentation.statusTitle(
                draft: "Prefer root-cause fixes.",
                persisted: "Run focused tests before full suites.",
                didRecentlySave: true
            ) == "Unsaved changes"
        )
        #expect(
            WorkspaceInstructionEditorPresentation.statusTitle(
                draft: "",
                persisted: "",
                didRecentlySave: false
            ) == nil
        )
    }

    @Test("workspace instruction editor renders persisted instructions before draft sync")
    func workspaceInstructionEditorRendersPersistedInstructionsBeforeDraftSync() {
        #expect(
            WorkspaceInstructionEditorPresentation.effectiveDraft(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: false
            ) == "Existing workspace guidance"
        )
        #expect(
            WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: false
            ) == false
        )
        #expect(
            WorkspaceInstructionEditorPresentation.statusTitle(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: false,
                didRecentlySave: false
            ) == "Saved"
        )

        #expect(
            WorkspaceInstructionEditorPresentation.effectiveDraft(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: true
            ) == ""
        )
        #expect(
            WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: true
            ) == true
        )
    }

    @Test("workspace instruction editor shows clear action for visible persisted draft before sync")
    func workspaceInstructionEditorShowsClearActionForVisiblePersistedDraftBeforeSync() {
        #expect(
            WorkspaceInstructionEditorPresentation.shouldShowClearAction(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: false
            ) == true
        )
        #expect(
            WorkspaceInstructionEditorPresentation.shouldShowClearAction(
                localDraft: "",
                persisted: "Existing workspace guidance",
                isSynced: true
            ) == false
        )
        #expect(
            WorkspaceInstructionEditorPresentation.shouldShowClearAction(
                localDraft: "Draft guidance",
                persisted: "",
                isSynced: true
            ) == true
        )
    }

    @Test("workspace folder helpers count only added paths, never the root")
    func workspaceFolderSetupTreatsPrimaryPathAsReference() {
        #expect(WorkspaceFolderPresentation.folderAccessTitle == "Folder access")
        #expect(WorkspaceFolderPresentation.addFolderActionTitle == "Add folder")
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount([]) == 0)
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount(["  "]) == 0)
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: []
        ) == 0)
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: []
        ) == "Workspace root only")
    }

    @Test("workspace folder detail rows show folder names instead of paths")
    func workspaceFolderDetailRowsShowFolderNamesInsteadOfPaths() {
        let rootDescriptor = WorkspacePathPresentation.descriptors(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/git",
            additionalPaths: []
        )[0]
        let rootRow = WorkspaceFolderPresentation.folderDetailRow(for: rootDescriptor)

        #expect(rootRow.title == "git")
        #expect(rootRow.subtitle == "Workspace root")
        #expect(rootRow.path == "/Users/alvaro/Documents/Astra Dev/Workspaces/git")
        #expect(rootRow.copyPathHelp == "Copy folder path")
        #expect(rootRow.canRemove == false)
        #expect(rootRow.showsPathInBody == false)

        let additionalDescriptor = WorkspaceFolderPresentation.userConfiguredFolderDescriptors([
            "/Users/alvaro/Documents/Code/MacTools"
        ])[0]
        let additionalRow = WorkspaceFolderPresentation.folderDetailRow(for: additionalDescriptor)

        #expect(additionalRow.title == "MacTools")
        #expect(additionalRow.subtitle == "Additional folder")
        #expect(additionalRow.path == "/Users/alvaro/Documents/Code/MacTools")
        #expect(additionalRow.copyPathHelp == "Copy folder path")
        #expect(additionalRow.canRemove == true)
        #expect(additionalRow.showsPathInBody == false)
    }

    @Test("workspace folder setup counts only added paths")
    func workspaceFolderSetupCountsOnlyAddedPaths() {
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount([
            "/Users/alvaro/Documents/Code/astra",
            " /Users/alvaro/Documents/Code/artana-evidence-platform "
        ]) == 2)
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == 1)
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == "1 added folder")
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: [
                "/Users/alvaro/Documents/Code/astra",
                "/Users/alvaro/Documents/Code/artana-evidence-platform"
            ]
        ) == "2 added folders")
    }

    @Test("workspace folder setup normalizes added paths before counting")
    func workspaceFolderSetupNormalizesAddedPathsBeforeCounting() {
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount([
            "/tmp/astra-review/docs",
            "/tmp/astra-review/./docs",
            " /tmp/astra-review/docs/ "
        ]) == 1)
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: [
                "/tmp/astra-review/docs",
                "/tmp/astra-review/./docs",
                " /tmp/astra-review/docs/ "
            ]
        ) == "1 added folder")
    }

    @Test("workspace folder setup ignores additional paths matching root")
    func workspaceFolderSetupIgnoresAdditionalPathsMatchingRoot() {
        let primaryPath = "/tmp/astra-review"
        let descriptors = WorkspaceFolderPresentation.userConfiguredFolderDescriptors(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./",
                " /tmp/astra-review/docs/ "
            ]
        )

        #expect(descriptors.map(\.path) == ["/tmp/astra-review/docs"])
        #expect(WorkspaceFolderPresentation.userConfiguredFolderCount(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./"
            ]
        ) == 0)
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./"
            ]
        ) == "Workspace root only")
    }

    @Test("workspace folder removal drops every normalized duplicate path")
    func workspaceFolderRemovalDropsEveryNormalizedDuplicatePath() {
        let remaining = WorkspaceFolderPresentation.remainingAdditionalPaths(
            afterRemovingFolderMatching: "/tmp/astra-review/docs",
            from: [
                "/tmp/astra-review/docs",
                "/tmp/astra-review/./docs",
                " /tmp/astra-review/docs/ ",
                "/tmp/astra-review/notes"
            ]
        )

        #expect(remaining == ["/tmp/astra-review/notes"])
    }

    @Test("workspace folder setup surfaces missing root even with added paths")
    func workspaceFolderSetupSurfacesMissingRootEvenWithAddedPaths() {
        #expect(WorkspaceFolderPresentation.shouldShowWorkspaceRootMissingMessage(primaryPath: " ") == true)
        #expect(WorkspaceFolderPresentation.folderSubtitle(
            primaryPath: " ",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == "No workspace root selected.")
    }

    @Test("pending connector permission highlights the owning capability without secret labels")
    func pendingConnectorPermissionHighlightsOwningCapabilityWithoutSecretLabels() {
        let workspace = Workspace(name: "JSL", primaryPath: "/tmp/jsl")
        let connector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        connector.workspace = workspace
        let task = AgentTask(title: "Review Jira", goal: "Review Jira issues", workspace: workspace)
        let secretLabel = "connector:\(connector.id.uuidString):JIRA_API_TOKEN"
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .connectorCredentials(
                connectorID: connector.id,
                displayName: "Jira-new connector credentials (2 configured credentials)",
                labels: [secretLabel, "connector:\(connector.id.uuidString):JIRA_EMAIL"]
            ),
            reason: "Connector credential access requires approval.",
            grants: [.credential(label: secretLabel)],
            requestID: "jira-permission"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
        let jira = railItem(name: "Jira", connectorNames: ["Jira-new"])
        let google = railItem(name: "Google Cloud", connectorNames: ["GCloud"])

        let attentions = CapabilityRuntimePermissionAttention.pending(for: task)
        let items = CapabilityRuntimePermissionAttention.applying(
            attentions,
            to: [jira, google],
            connectors: [connector]
        )

        #expect(attentions.count == 1)
        #expect(items[0].runtimePermissionAttention?.connectorID == connector.id)
        #expect(items[0].readiness.level == .needsAttention)
        #expect(items[0].presentation.statusLabel == "Approval needed")
        #expect(items[0].presentation.rowSubtitle == "Jira-new: permission to use 2 configured credentials for this task")
        #expect(items[0].presentation.rowSubtitle.contains("JIRA_API_TOKEN") == false)
        #expect(items[1].runtimePermissionAttention == nil)
        #expect(items[1].readiness.level == .ready)

        let decision = RuntimePermissionDecisionPresentation(payload: payload)
        #expect(decision.title == "Jira-new connector needs permission")
        #expect(decision.summary == "ASTRA wants to use 2 saved credentials from the Jira-new connector for this task.")
        #expect(decision.summary.contains("JIRA_API_TOKEN") == false)
    }

    @Test("one approval naming two connectors highlights both capabilities")
    func oneApprovalNamingTwoConnectorsHighlightsBothCapabilities() throws {
        let workspace = Workspace(name: "JSL", primaryPath: "/tmp/jsl")
        let jiraConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        let redcapConnector = Connector(
            name: "REDCap",
            serviceType: "redcap",
            baseURL: "https://redcap.example.test/api/",
            authMethod: "bearer"
        )
        jiraConnector.workspace = workspace
        redcapConnector.workspace = workspace
        let task = AgentTask(title: "Compare records", goal: "Compare Jira tickets with REDCap records", workspace: workspace)
        let merged = try #require(ConnectorRuntimeProjection.CredentialApprovalRequest.merged([
            .init(connectorID: jiraConnector.id, connectorName: "Jira-new", serviceType: "jira", labels: [
                ConnectorRuntimeProjection.credentialLabel(for: jiraConnector, key: "JIRA_API_TOKEN"),
                ConnectorRuntimeProjection.credentialLabel(for: jiraConnector, key: "JIRA_EMAIL")
            ]),
            .init(connectorID: redcapConnector.id, connectorName: "REDCap", serviceType: "redcap", labels: [
                ConnectorRuntimeProjection.credentialLabel(for: redcapConnector, key: "REDCAP_API_TOKEN")
            ])
        ]))
        let request = PermissionRequest.connectorCredentials(
            connectorID: merged.connectorID,
            displayName: merged.displayName,
            labels: merged.labels
        )
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: request,
            reason: "Connector credential access requires approval.",
            grants: PermissionBroker.approvalGrants(for: request)
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
        let jira = railItem(name: "Jira", connectorNames: ["Jira-new"])
        let redcap = railItem(name: "REDCap", connectorNames: ["REDCap"])

        let attentions = CapabilityRuntimePermissionAttention.pending(for: task)
        let items = CapabilityRuntimePermissionAttention.applying(
            attentions,
            to: [jira, redcap],
            connectors: [jiraConnector, redcapConnector]
        )

        #expect(merged.displayName == "Jira-new and REDCap connector credentials (3 configured credentials)")
        #expect(attentions.count == 2)
        #expect(items[0].presentation.rowSubtitle == "Jira-new: permission to use 2 configured credentials for this task")
        #expect(items[1].presentation.rowSubtitle == "REDCap: permission to use 1 configured credential for this task")

        let decision = RuntimePermissionDecisionPresentation(payload: payload)
        #expect(decision.title == "Jira-new and REDCap connectors need permission")
        #expect(decision.summary == "ASTRA wants to use 3 saved credentials from the Jira-new and REDCap connectors for this task.")
        #expect(decision.allowSimilarLabel == "Allow these connectors for task")
    }

    @Test("connector origin selects one capability when connector names collide")
    func connectorOriginSelectsOneCapabilityWhenConnectorNamesCollide() {
        let workspace = Workspace(name: "Shared", primaryPath: "/tmp/shared")
        let connector = Connector(
            name: "Shared Jira",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.originPackageID = "jira-workflow"
        let task = AgentTask(title: "Shared Jira", goal: "Review Jira", workspace: workspace)
        let label = "connector:\(connector.id.uuidString):JIRA_API_TOKEN"
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .connectorCredentials(
                connectorID: connector.id,
                displayName: "Shared Jira connector credential (1 configured credential)",
                labels: [label]
            ),
            reason: "Connector credential access requires approval.",
            grants: [.credential(label: label)],
            requestID: "shared-jira-permission"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
        let unrelated = railItem(id: "other-package", name: "Other Jira", connectorNames: ["Shared Jira"])
        let owner = railItem(id: "jira-workflow", name: "Jira", connectorNames: ["Shared Jira"])

        let items = CapabilityRuntimePermissionAttention.applying(
            CapabilityRuntimePermissionAttention.pending(for: task),
            to: [unrelated, owner],
            connectors: [connector]
        )

        #expect(items[0].runtimePermissionAttention == nil)
        #expect(items[0].readiness.level == .ready)
        #expect(items[1].runtimePermissionAttention?.connectorID == connector.id)
        #expect(items[1].presentation.statusLabel == "Approval needed")

        let otherConnector = Connector(
            name: "Disabled Shared Jira",
            serviceType: "jira",
            baseURL: "https://other.atlassian.net",
            authMethod: "basic"
        )
        let ownershipConnectors = CapabilityRuntimePermissionAttention.ownershipConnectors(
            workspaceConnectors: [connector],
            availableGlobalConnectors: [connector, otherConnector]
        )
        #expect(ownershipConnectors.map(\.id) == [connector.id, otherConnector.id])
    }

    private func railItem(id: String? = nil, name: String, connectorNames: [String]) -> RailCapabilityItem {
        let package = PluginPackage(
            id: id ?? name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name,
            icon: "puzzlepiece.extension",
            description: "Test capability",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved()
        )
        return RailCapabilityItem(
            id: "package:\(package.id)",
            name: name,
            icon: package.icon,
            summary: package.description,
            color: Stanford.lagunita,
            isEnabled: true,
            readiness: .ready,
            presentation: CapabilityRailPackagePresentation.make(
                isEnabled: true,
                readinessLevel: .ready,
                workspaceName: "JSL",
                sharedResourceCount: 0,
                workspaceResourceCount: connectorNames.count,
                declaredResourceCount: connectorNames.count,
                contentSummary: "\(connectorNames.count) connector"
            ),
            source: .package(package),
            skillNames: [],
            connectorNames: connectorNames,
            toolNames: [],
            mcpServerNames: [],
            browserAdapterNames: [],
            templateNames: [],
            requirementNames: []
        )
    }
}
