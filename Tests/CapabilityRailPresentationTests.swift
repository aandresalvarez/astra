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

    @Test("rail leads with setup while pending and with capabilities once configured")
    func railLeadsWithSetupWhilePendingAndCapabilitiesOnceConfigured() {
        // Onboarding: setup stays directly under the repository.
        #expect(
            WorkspaceRightRailPresentation.sectionOrder(hasPendingSetup: true)
                == WorkspaceRightRailPresentation.primarySectionOrder
        )
        // Steady state: capabilities rise above the now-compact configured setup.
        let steady = WorkspaceRightRailPresentation.sectionOrder(hasPendingSetup: false)
        #expect(steady == WorkspaceRightRailPresentation.steadyStateSectionOrder)
        let capabilities = steady.firstIndex(of: CapabilityRailSectionPresentation.sectionTitle)
        let setup = steady.firstIndex(of: WorkspaceSetupChecklistPresentation.sectionTitle)
        #expect(capabilities != nil && setup != nil && capabilities! < setup!)
        #expect(steady.first == "Repository")
    }

    @Test("summary disclosures name how many rows they reveal")
    func summaryDisclosuresNameHowManyRowsTheyReveal() {
        // The N >= 2 rule: the verb states its payload count, so a lone item is
        // never hidden behind a "Show all (1)".
        #expect(CapabilityRailSectionPresentation.showAllActionTitle(count: 3) == "Show all (3)")
        #expect(WorkspaceSetupChecklistPresentation.showAllActionTitle(2) == "Show all (2)")
        #expect(WorkspaceSetupChecklistPresentation.configuredCountSubtitle(4) == "4 configured")
        #expect(CapabilityRailSectionPresentation.readySummarySubtitle(count: 2) == "Ready · 2")
        #expect(CapabilityRailSectionPresentation.draftSummarySubtitle(count: 1) == "Draft · 1")
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

    @Test("workspace setup checklist summary stays compact")
    func workspaceSetupChecklistSummaryStaysCompact() {
        #expect(WorkspaceSetupChecklistPresentation.summary(configured: 0, total: 4) == "Empty")
        #expect(WorkspaceSetupChecklistPresentation.summary(configured: 1, total: 4) == "1 of 4 configured")
        #expect(WorkspaceSetupChecklistPresentation.State.configured.label == "Configured")
        #expect(WorkspaceSetupChecklistPresentation.State.reference.label == "Reference")
        #expect(WorkspaceSetupChecklistPresentation.State.missing.label == "Missing")
    }

    @Test("workspace setup rows disclose configuration details inline")
    func workspaceSetupRowsDiscloseConfigurationDetailsInline() {
        #expect(WorkspaceSetupChecklistPresentation.sectionTitle == "Workspace setup")
        #expect(WorkspaceSetupChecklistPresentation.missingGroupTitle == "Needs setup")
        #expect(WorkspaceSetupChecklistPresentation.referenceGroupTitle == "Reference")
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

    @Test("workspace folder setup treats primary path as reference")
    func workspaceFolderSetupTreatsPrimaryPathAsReference() {
        #expect(WorkspaceSetupChecklistPresentation.folderAccessTitle == "Folder access")
        #expect(WorkspaceSetupChecklistPresentation.addFolderActionTitle == "Add folder")
        #expect(WorkspaceSetupChecklistPresentation.workspaceRootReferenceTitle == "Workspace root")
        #expect(WorkspaceSetupChecklistPresentation.workspaceRootReferenceRole == "Reference")
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount([]) == 0)
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount(["  "]) == 0)
        #expect(WorkspaceSetupChecklistPresentation.folderState(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: []
        ) == .reference)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
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
        let rootRow = WorkspaceSetupChecklistPresentation.folderDetailRow(for: rootDescriptor)

        #expect(rootRow.title == "git")
        #expect(rootRow.subtitle == "Workspace root")
        #expect(rootRow.path == "/Users/alvaro/Documents/Astra Dev/Workspaces/git")
        #expect(rootRow.copyPathHelp == "Copy folder path")
        #expect(rootRow.canRemove == false)
        #expect(rootRow.showsPathInBody == false)

        let additionalDescriptor = WorkspaceSetupChecklistPresentation.userConfiguredFolderDescriptors([
            "/Users/alvaro/Documents/Code/MacTools"
        ])[0]
        let additionalRow = WorkspaceSetupChecklistPresentation.folderDetailRow(for: additionalDescriptor)

        #expect(additionalRow.title == "MacTools")
        #expect(additionalRow.subtitle == "Additional folder")
        #expect(additionalRow.path == "/Users/alvaro/Documents/Code/MacTools")
        #expect(additionalRow.copyPathHelp == "Copy folder path")
        #expect(additionalRow.canRemove == true)
        #expect(additionalRow.showsPathInBody == false)
    }

    @Test("workspace folder setup counts only added paths")
    func workspaceFolderSetupCountsOnlyAddedPaths() {
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount([
            "/Users/alvaro/Documents/Code/astra",
            " /Users/alvaro/Documents/Code/artana-evidence-platform "
        ]) == 2)
        #expect(WorkspaceSetupChecklistPresentation.folderState(
            primaryPath: "/Users/alvaro/Documents/Astra Dev/Workspaces/pr",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == .configured)
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

    @Test("workspace folder setup normalizes added paths before counting")
    func workspaceFolderSetupNormalizesAddedPathsBeforeCounting() {
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount([
            "/tmp/astra-review/docs",
            "/tmp/astra-review/./docs",
            " /tmp/astra-review/docs/ "
        ]) == 1)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
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
        let descriptors = WorkspaceSetupChecklistPresentation.userConfiguredFolderDescriptors(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./",
                " /tmp/astra-review/docs/ "
            ]
        )

        #expect(descriptors.map(\.path) == ["/tmp/astra-review/docs"])
        #expect(WorkspaceSetupChecklistPresentation.userConfiguredFolderCount(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./"
            ]
        ) == 0)
        #expect(WorkspaceSetupChecklistPresentation.folderState(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./"
            ]
        ) == .reference)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
            primaryPath: primaryPath,
            additionalPaths: [
                "/tmp/astra-review",
                "/tmp/astra-review/./"
            ]
        ) == "Workspace root only")
    }

    @Test("workspace folder removal drops every normalized duplicate path")
    func workspaceFolderRemovalDropsEveryNormalizedDuplicatePath() {
        let remaining = WorkspaceSetupChecklistPresentation.remainingAdditionalPaths(
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
        #expect(WorkspaceSetupChecklistPresentation.shouldShowWorkspaceRootMissingMessage(primaryPath: " ") == true)
        #expect(WorkspaceSetupChecklistPresentation.folderState(
            primaryPath: " ",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == .missing)
        #expect(WorkspaceSetupChecklistPresentation.folderSubtitle(
            primaryPath: " ",
            additionalPaths: ["/Users/alvaro/Documents/Code/astra"]
        ) == "No workspace root selected.")
    }
}
