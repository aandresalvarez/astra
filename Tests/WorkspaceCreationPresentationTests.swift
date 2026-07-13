import Testing
@testable import ASTRA

@Suite("Workspace creation presentation")
struct WorkspaceCreationPresentationTests {
    @Test("Both entry points use the same creation vocabulary")
    func entryPointsShareCreationVocabulary() {
        let onboarding = WorkspaceSetupFormMode.onboarding.presentation
        let standard = WorkspaceSetupFormMode.standard.presentation

        #expect(onboarding.headerSubtitle == standard.headerSubtitle)
        #expect(onboarding.namePlaceholder == standard.namePlaceholder)
        #expect(onboarding.guidanceDescription == standard.guidanceDescription)
        #expect(onboarding.guidancePlaceholder == standard.guidancePlaceholder)
        #expect(onboarding.capabilitiesTitle == standard.capabilitiesTitle)
        #expect(onboarding.capabilitiesSummary == standard.capabilitiesSummary)
        #expect(onboarding.capabilitiesExpandedDescription == standard.capabilitiesExpandedDescription)
    }

    @Test("Onboarding adds only the workspace concept primer")
    func onboardingAddsOnlyConceptPrimer() {
        #expect(WorkspaceSetupFormMode.onboarding.presentation.showsWorkspacePrimer)
        #expect(!WorkspaceSetupFormMode.standard.presentation.showsWorkspacePrimer)
        #expect(WorkspaceCreationPresentation.primerTitle == "Keep one body of work together")
        #expect(WorkspaceCreationPresentation.primerDescription.contains("tasks share a goal"))
    }

    @Test("Optional capabilities start collapsed in both entry points")
    func capabilitiesStartCollapsed() {
        #expect(!WorkspaceSetupFormMode.onboarding.presentation.expandsCapabilitiesInitially)
        #expect(!WorkspaceSetupFormMode.standard.presentation.expandsCapabilitiesInitially)
    }

    @Test("Empty workspace name is presented as a requirement, not an error")
    func emptyNameUsesCalmRequirementCopy() {
        #expect(WorkspaceCreationPresentation.emptyNameRequirement == "Enter a workspace name to continue.")
    }

    @Test("Capability validation keeps entry-point trace sources distinct")
    func validationSourcesRemainDistinct() {
        #expect(WorkspaceSetupFormMode.onboarding.validationSource == "onboarding_workspace_validation")
        #expect(WorkspaceSetupFormMode.standard.validationSource == "new_workspace_validation")
    }
}
