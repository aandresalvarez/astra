import Testing
@testable import ASTRA
import ASTRACore

@Suite("Repetition signature for path-only file tools")
struct RepetitionSignatureTests {
    @Test("Distinct file-tool calls with the same path summary are not a repetition")
    func distinctToolCallsWithTheSameSummaryAreNotRepeats() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        // A provider that keeps only a path for an edit gives every edit to one
        // file the same input; the call ids are what tell them apart.
        for index in 1...6 {
            let shouldKill = monitor.processEvent(
                .toolUse(name: "edit", id: "call_\(index)", input: ["summary": "/tmp/plan.md"]),
                process: nil
            )
            #expect(shouldKill == false)
        }
        for index in 1...6 {
            let shouldKill = monitor.processEvent(
                .toolResult(toolId: "call_\(index)", content: "File /tmp/plan.md updated with changes."),
                process: nil
            )
            #expect(shouldKill == false)
        }

        #expect(monitor.repetitionKilled == false)
    }

    @Test("A command repeated under fresh ids is still a repetition when only its summary is kept")
    func repeatedCommandUnderFreshIDsStillRepeats() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for index in 1...2 {
            #expect(monitor.processEvent(.toolUse(name: "bash", id: "call_\(index)", input: ["summary": "pwd"]), process: nil) == false)
        }
        #expect(monitor.processEvent(.toolUse(name: "bash", id: "call_3", input: ["summary": "pwd"]), process: nil) == true)
        #expect(monitor.repetitionKilled == true)
    }

    @Test("The same file-tool call and result repeated under one id still trip the breaker")
    func sameIDToolEventsStillRepeat() {
        let use = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for _ in 1...2 {
            #expect(use.processEvent(.toolUse(name: "edit", id: "call_1", input: ["summary": "/tmp/plan.md"]), process: nil) == false)
        }
        #expect(use.processEvent(.toolUse(name: "edit", id: "call_1", input: ["summary": "/tmp/plan.md"]), process: nil) == true)
        #expect(use.repetitionKilled == true)

        let result = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)
        for _ in 1...2 {
            #expect(result.processEvent(.toolResult(toolId: "call_1", content: "same output"), process: nil) == false)
        }
        #expect(result.processEvent(.toolResult(toolId: "call_1", content: "same output"), process: nil) == true)
        #expect(result.repetitionKilled == true)
    }

    @Test("A file tool with a full input keeps its own signature rule")
    func fullInputFileToolsAreUnchanged() {
        let a = AgentRuntimeWorker.ProcessMonitor.repetitionSignature(
            .toolUse(name: "edit", id: "a", input: ["path": "/tmp/p.md", "new_str": "x"]),
            toolNameForResult: { _ in nil }
        )
        let b = AgentRuntimeWorker.ProcessMonitor.repetitionSignature(
            .toolUse(name: "edit", id: "b", input: ["path": "/tmp/p.md", "new_str": "x"]),
            toolNameForResult: { _ in nil }
        )
        #expect(a == b)
    }
}
