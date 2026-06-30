import Testing
@testable import ASTRA

@Suite("Workspace App Action Status Presentation")
struct WorkspaceAppActionStatusPresentationTests {
    @Test("action failures use localized descriptions instead of debug enum output")
    func actionFailuresUseLocalizedDescriptions() {
        let error = WorkspaceAppActionExecutionError.permissionDenied(
            "External write action 'submit' requires explicit approval before execution."
        )

        #expect(WorkspaceAppActionStatusPresentation.errorMessage(for: error) == error.localizedDescription)
        #expect(WorkspaceAppActionStatusPresentation.errorMessage(for: error) != String(describing: error))
    }
}
