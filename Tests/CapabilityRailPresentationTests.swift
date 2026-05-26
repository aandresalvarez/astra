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

    @Test("compact capability rows reserve space for title and subtitle")
    func compactRowsReserveSpaceForTitleAndSubtitle() {
        #expect(CapabilityRailLayout.minimumTwoLineRowHeight > 34)
        #expect(CapabilityRailLayout.rowMinHeight(isCompact: true) >= CapabilityRailLayout.minimumTwoLineRowHeight)
        #expect(CapabilityRailLayout.rowMinHeight(isCompact: true) >= 64)
        #expect(CapabilityRailLayout.summaryRowMinHeight >= CapabilityRailLayout.rowMinHeight(isCompact: true))
        #expect(CapabilityRailLayout.setupRowMinHeight >= CapabilityRailLayout.rowMinHeight(isCompact: true))
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
        #expect(CapabilityRailSectionPresentation.addActionSubtitle == "Browse library")
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

    @Test("capability health omits low value top summary metrics")
    func capabilityHealthOmitsLowValueTopSummaryMetrics() {
        #expect(CapabilityRailSectionPresentation.showsTopHealthSummaryMetrics == false)
    }

    @Test("attention group header stays neutral because row pill carries setup state")
    func attentionGroupHeaderStaysNeutralBecauseRowPillCarriesSetupState() {
        #expect(CapabilityRailSectionPresentation.attentionGroupShowsWarningIcon == false)
        #expect(CapabilityRailSectionPresentation.attentionGroupUsesWarningTint == false)
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
        #expect(WorkspaceSetupChecklistPresentation.supportsInlineExpansion == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsInlineEditing == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsMemoryRemoval == true)
        #expect(WorkspaceSetupChecklistPresentation.supportsFolderRemoval == true)
        #expect(WorkspaceSetupChecklistPresentation.collapsedDisclosureIcon == "chevron.right")
        #expect(WorkspaceSetupChecklistPresentation.expandedDisclosureIcon == "chevron.down")
        #expect(WorkspaceSetupChecklistPresentation.detailPreviewLimit == 4)
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
}
