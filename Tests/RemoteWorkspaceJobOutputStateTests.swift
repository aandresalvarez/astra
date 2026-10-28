import Foundation
import Testing
@testable import ASTRA

@Suite("Remote job output selection")
struct RemoteWorkspaceJobOutputStateTests {
    @Test("A delayed reply cannot overwrite the selected job")
    func outOfOrderReplies() throws {
        var state = RemoteWorkspaceJobOutputState()
        let taskID = UUID()
        let first = state.begin(taskID: taskID, jobID: "a", label: "First")
        state.complete(requestID: first, text: "Old output")
        let second = state.begin(taskID: taskID, jobID: "b", label: "Second")
        #expect(state.visible(for: taskID)?.text == nil)
        state.complete(requestID: second, text: "Selected output")
        state.complete(requestID: first, text: "Late output")
        let visible = try #require(state.visible(for: taskID))
        #expect(visible.jobID == "b")
        #expect(visible.label == "Second")
        #expect(visible.text == "Selected output")
    }

    @Test("Refreshing the same job ignores its previous request")
    func sameJobRefresh() {
        var state = RemoteWorkspaceJobOutputState()
        let taskID = UUID()
        let first = state.begin(taskID: taskID, jobID: "a", label: "Job")
        let second = state.begin(taskID: taskID, jobID: "a", label: "Job")
        state.complete(requestID: first, text: "Stale")
        #expect(state.visible(for: taskID)?.text == nil)
        state.complete(requestID: second, text: "Current")
        #expect(state.visible(for: taskID)?.text == "Current")
    }

    @Test("Switching tasks never presents another task's output")
    func changedTask() {
        var state = RemoteWorkspaceJobOutputState()
        let firstTask = UUID(), secondTask = UUID()
        let first = state.begin(taskID: firstTask, jobID: "a", label: "First")
        state.complete(requestID: first, text: "First output")
        #expect(state.visible(for: secondTask) == nil)
        let second = state.begin(taskID: secondTask, jobID: "b", label: "Second")
        state.complete(requestID: first, text: "Late first output")
        #expect(state.visible(for: secondTask)?.text == nil)
        state.complete(requestID: second, text: "Second output")
        #expect(state.visible(for: firstTask) == nil)
        #expect(state.visible(for: secondTask)?.text == "Second output")
    }
}
