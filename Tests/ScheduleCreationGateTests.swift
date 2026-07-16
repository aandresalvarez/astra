import Testing
import ASTRAModels
@testable import ASTRA

// Regression coverage for issue #322: showNewSchedule() must never be able to
// present a sheet that builds ScheduleEditorView(workspace:) without a
// workspace to pass it.
@Suite("Schedule creation gate")
struct ScheduleCreationGateTests {
    @Test("No effective workspace cannot present the schedule sheet")
    func noEffectiveWorkspaceCannotPresent() {
        #expect(!ScheduleCreationGate.canPresent(effectiveWorkspace: nil))
    }

    @MainActor
    @Test("An effective workspace can present the schedule sheet")
    func effectiveWorkspaceCanPresent() {
        let workspace = Workspace(name: "WS", primaryPath: "/tmp/schedule-gate")
        #expect(ScheduleCreationGate.canPresent(effectiveWorkspace: workspace))
    }
}
