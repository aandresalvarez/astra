import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task canvas refresh signature")
struct TaskCanvasRefreshSignatureTests {
    @Test("Signature is driven by task-level refresh inputs, not live run relationships")
    func signatureIgnoresRunOnlyRelationshipChanges() {
        let task = AgentTask(title: "Build report", goal: "Generate HTML")
        task.updatedAt = Date(timeIntervalSince1970: 100)

        let original = TaskCanvasRefreshSignature(task: task)

        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 200)
        task.runs.append(run)

        #expect(TaskCanvasRefreshSignature(task: task) == original)

        task.updatedAt = Date(timeIntervalSince1970: 300)

        #expect(TaskCanvasRefreshSignature(task: task) != original)
    }

    @Test("Signature changes when task inputs, events, and file changes update the scalar token")
    func signatureTracksScalarTaskRefreshToken() {
        let task = AgentTask(title: "Build report", goal: "Generate HTML")
        task.updatedAt = Date(timeIntervalSince1970: 100)
        let original = TaskCanvasRefreshSignature(task: task)

        task.inputs.append("/tmp/report.html")
        #expect(TaskCanvasRefreshSignature(task: task) != original)

        let withInput = TaskCanvasRefreshSignature(task: task)
        task.events.append(TaskEvent(task: task, type: "tool.use", payload: "Write"))
        #expect(TaskCanvasRefreshSignature(task: task) != withInput)

        let withEvent = TaskCanvasRefreshSignature(task: task)
        let run = TaskRun(task: task)
        task.runs.append(run)
        run.appendFileChange(StoredFileChange(
            path: "/tmp/report.html",
            changeType: "Write",
            content: "<html></html>",
            oldString: nil,
            newString: nil,
            timestamp: Date()
        ))
        #expect(TaskCanvasRefreshSignature(task: task) != withEvent)
    }
}
