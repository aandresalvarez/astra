import Testing
@testable import ASTRA

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

    @Test("workspace context uses desktop inspector density")
    func workspaceContextUsesDesktopInspectorDensity() {
        #expect(WorkspaceRightRailPresentation.headerTitleFontSize == 16)
        #expect(WorkspaceRightRailPresentation.headerSubtitleFontSize == 12)
        #expect(WorkspaceRightRailPresentation.headerIconFontSize == 15)
        #expect(WorkspaceRightRailPresentation.headerIconFrame == 22)
        #expect(CapabilityRailLayout.sectionTitleFontSize == 15)
        #expect(CapabilityRailLayout.rowTitleFontSize == 14)
        #expect(CapabilityRailLayout.rowSubtitleFontSize == 12)
        #expect(CapabilityRailLayout.rowTitleFontSize < Stanford.chatBodyPointSize)
        #expect(CapabilityRailLayout.sectionTitleFontSize < Stanford.chatBodyPointSize)
        #expect(CapabilityRailLayout.regularSectionPadding == 16)
        #expect(CapabilityRailLayout.regularPanelSpacing == 12)
        #expect(CapabilityRailLayout.regularGroupSpacing == 12)
    }

    @Test("capability rows reserve space without mobile scale")
    func capabilityRowsReserveSpaceWithoutMobileScale() {
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
        #expect(WorkspaceContextIconography.headerIcon == "info.circle")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Bigquery Analyst", fallback: "puzzlepiece") == "cylinder.split.1x2")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Read-Only", fallback: "lock.shield") == "eye")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Safe Bash", fallback: "shield") == "terminal")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Google Cloud", fallback: "cloud") == "cloud")
        #expect(WorkspaceContextIconography.capabilityIcon(name: "Untitled Capability", fallback: "  ") == "puzzlepiece.extension")
    }

    @Test("capability rail treats adding as an action, not an available-count section")
    func capabilityRailTreatsAddingAsActionNotAvailableCountSection() {
        #expect(CapabilityRailSectionPresentation.sectionTitle == "Capabilities")
        #expect(CapabilityRailSectionPresentation.addActionTitle == "Add")
        #expect(CapabilityRailSectionPresentation.addActionSubtitle == "")
        #expect(CapabilityRailSectionPresentation.addActionHelp == "Browse capability library")
        #expect(CapabilityRailSectionPresentation.addActionShowsPlusIcon == false)
        #expect(CapabilityRailSectionPresentation.showsAvailableToAddCount == false)
        #expect(CapabilityRailSectionPresentation.showsBrowseLibraryFooter == false)
        #expect(!CapabilityRailSectionPresentation.addActionSubtitle.localizedCaseInsensitiveContains("available"))
    }

    @Test("capability rail summarizes ready capabilities without expanding the inventory")
    func capabilityRailSummarizesReadyCapabilitiesWithoutExpandingInventory() {
        #expect(CapabilityRailSectionPresentation.readySummaryTitle(count: 1) == "1 ready capability")
        #expect(CapabilityRailSectionPresentation.readySummaryTitle(count: 6) == "6 ready capabilities")
        #expect(
            CapabilityRailSectionPresentation.previewList([
                "Google Cloud",
                "Bigquery Analyst",
                "Code Reviewer",
                "Read-Only",
                "Safe Bash",
                "Test Runner"
            ]) == "Google Cloud, Bigquery Analyst, Code Reviewer +3"
        )
    }

    @Test("single capability summary uses the capability icon presentation")
    func singleCapabilitySummaryUsesCapabilityIconPresentation() {
        let github = CapabilityIconPresentation(kind: .brand(.github), fallbackSystemName: "link")
        let drive = CapabilityIconPresentation(kind: .brand(.googleDrive), fallbackSystemName: "externaldrive")

        #expect(
            CapabilityRailSectionPresentation.summaryIconPresentation(
                for: [github],
                fallbackSystemName: "cloud"
            ) == github
        )
        #expect(
            CapabilityRailSectionPresentation.summaryIconPresentation(
                for: [github, drive],
                fallbackSystemName: "cloud"
            ) == CapabilityIconPresentation(kind: .systemSymbol("cloud"), fallbackSystemName: "cloud")
        )
    }

    @Test("capability health omits low value top summary metrics")
    func capabilityHealthOmitsLowValueTopSummaryMetrics() {
        #expect(CapabilityRailSectionPresentation.showsTopHealthSummaryMetrics == false)
    }

    @Test("attention group header stays neutral because row pill carries setup state")
    func attentionGroupHeaderStaysNeutralBecauseRowPillCarriesSetupState() {
        #expect(CapabilityRailSectionPresentation.attentionGroupShowsWarningIcon == false)
        #expect(CapabilityRailSectionPresentation.attentionGroupUsesWarningTint == false)
    }

    @Test("workspace right rail orders primary work before setup and inventory")
    func workspaceRightRailOrdersPrimaryWorkBeforeSetupAndInventory() {
        #expect(WorkspaceRightRailPresentation.primarySectionOrder == [
            "Repository",
            WorkspaceSetupChecklistPresentation.sectionTitle,
            CapabilityRailSectionPresentation.sectionTitle
        ])
    }

    @Test("repository rail exposes git controls by default")
    func repositoryRailExposesGitControlsByDefault() {
        #expect(WorkspaceGitPanelPresentation.startsCollapsed == false)
        #expect(WorkspaceGitPanelPresentation.collapsedVisibleRowCount == 1)
        #expect(WorkspaceGitPanelPresentation.expandedDetailRowCount == 6)
        #expect(WorkspaceGitPanelPresentation.repositorySelectorRowMinHeight == 50)
        #expect(WorkspaceGitPanelPresentation.detailRowMinHeight == 44)
        #expect(WorkspaceGitPanelPresentation.detailRowMinHeight < CapabilityRailLayout.setupRowMinHeight)
        #expect(WorkspaceGitPanelPresentation.showDetailsActionTitle == "Show all")
        #expect(WorkspaceGitPanelPresentation.hideDetailsActionTitle == "Hide")
    }

    @Test("workspace setup checklist summary stays compact")
    func workspaceSetupChecklistSummaryStaysCompact() {
        #expect(WorkspaceSetupChecklistPresentation.summary(configured: 0, total: 4) == "Empty")
        #expect(WorkspaceSetupChecklistPresentation.summary(configured: 1, total: 4) == "1 of 4 configured")
        #expect(WorkspaceSetupChecklistPresentation.State.configured.label == "Configured")
        #expect(WorkspaceSetupChecklistPresentation.State.missing.label == "Missing")
    }

    @Test("workspace setup rows disclose configuration details inline")
    func workspaceSetupRowsDiscloseConfigurationDetailsInline() {
        #expect(WorkspaceSetupChecklistPresentation.sectionTitle == "Workspace setup")
        #expect(WorkspaceSetupChecklistPresentation.missingGroupTitle == "Needs setup")
        #expect(WorkspaceSetupChecklistPresentation.configuredGroupTitle == "Configured")
        #expect(WorkspaceSetupChecklistPresentation.supportsInlineExpansion == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsInlineEditing == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsMemoryRemoval == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsFolderRemoval == true)
        #expect(WorkspaceSetupChecklistPresentation.usesCapabilitySummaryRowPattern == true)
        #expect(WorkspaceSetupChecklistPresentation.collapsesConfiguredRowsByDefault == true)
        #expect(WorkspaceSetupChecklistPresentation.configuredSummaryTitle == "Configured items")
        #expect(WorkspaceSetupChecklistPresentation.configuredSummaryActionTitle == "Show all")
        #expect(WorkspaceSetupChecklistPresentation.configuredSummaryIcon == "checkmark.circle")
        #expect(WorkspaceSetupChecklistPresentation.showsPerRowStatusInCollapsedState == false)
        #expect(WorkspaceSetupChecklistPresentation.collapsedDisclosureIcon == "chevron.right")
        #expect(WorkspaceSetupChecklistPresentation.expandedDisclosureIcon == "chevron.down")
        #expect(WorkspaceSetupChecklistPresentation.detailPreviewLimit == 4)
        #expect(
            WorkspaceSetupChecklistPresentation.configuredPreview([
                "Memory",
                "Folders",
                "Routines"
            ]) == "Memory, Folders, Routines"
        )
        #expect(
            WorkspaceSetupChecklistPresentation.configuredPreview([
                "Instructions",
                "Memory",
                "Folders",
                "Remote access"
            ]) == "Instructions, Memory, Folders +1"
        )
        #expect(
            WorkspaceSetupChecklistPresentation.configuredPreview([
                " ",
                "Folders"
            ]) == "Folders"
        )
        #expect(WorkspaceSetupChecklistPresentation.configuredPreview([]) == "No configured items")
        #expect(
            WorkspaceSetupChecklistPresentation.overflowSummary(
                total: 6,
                visible: 4,
                singular: "folder",
                plural: "folders"
            ) == "2 more folders"
        )
        #expect(
            WorkspaceSetupChecklistPresentation.overflowSummary(
                total: 1,
                visible: 1,
                singular: "folder",
                plural: "folders"
            ) == nil
        )
    }

    @Test("workspace folder setup treats primary path as reference")
    func workspaceFolderSetupTreatsPrimaryPathAsReference() {
        #expect(WorkspaceSetupChecklistPresentation.workspaceRootReferenceTitle == "Workspace root")
        #expect(WorkspaceSetupChecklistPresentation.workspaceRootReferenceRole == "Reference")
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount([]) == 0)
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount(["  "]) == 0)
        #expect(WorkspaceSetupChecklistPresentation.folderState(additionalPaths: []) == .missing)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: []
        ) == "Add extra folders for this workspace")
    }

    @Test("workspace folder setup counts only added paths")
    func workspaceFolderSetupCountsOnlyAddedPaths() {
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount([
            "/Users/alvaro/Documents/Code/astra",
            " /Users/alvaro/Documents/Code/artana-evidence-platform "
        ]) == 2)
        #expect(WorkspaceSetupChecklistPresentation.folderState(additionalPaths: [
            "/Users/alvaro/Documents/Code/astra"
        ]) == .configured)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == "1 added folder")
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: [
                "/Users/alvaro/Documents/Code/astra",
                "/Users/alvaro/Documents/Code/artana-evidence-platform"
            ]
        ) == "2 added folders")
    }
}
