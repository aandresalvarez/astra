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
}
