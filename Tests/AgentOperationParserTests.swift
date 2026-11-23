import Foundation
import Testing
import ASTRACore

/// The parser-level reproductions from issue #477: what each provider says
/// about an operation apart from its output has to survive normalization.
@Suite("Agent operation parsing")
struct AgentOperationParserTests {
    // MARK: - Copilot

    @Test("A Copilot shell-completion notice is a background job, not assistant text")
    func copilotShellCompletionIsABackgroundJob() {
        let line = #"{"type":"system.notification","data":{"content":"<system_notification>Shell completed</system_notification>","kind":{"type":"shell_completed","shellId":"job-1","exitCode":1}}}"#

        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events == [.operation(.backgroundJobFinished(AgentBackgroundJobEvent(
            jobID: "job-1",
            kind: "shell_completed",
            outcome: .failed,
            exitCode: 1,
            summary: "Shell completed"
        )))])
        // The unkeyed path utility prompts use must agree.
        #expect(CopilotStreamEventParser.parseAgentEvents(line: line) == events)
    }

    @Test("A Copilot job notice with no exit code or status has an unknown outcome, never success")
    func copilotJobWithoutOutcomeIsUnknown() throws {
        let line = #"{"type":"system.notification","data":{"content":"<system_notification>Detached shell finished</system_notification>","kind":{"type":"shell_detached_completed","shellId":"job-2"}}}"#

        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line)

        guard case .operation(.backgroundJobFinished(let job)) = try #require(events.first) else {
            Issue.record("expected a background job, got \(events)")
            return
        }
        #expect(job.jobID == "job-2")
        #expect(job.outcome == .unknown)
        #expect(job.exitCode == nil)
    }

    @Test("Any other Copilot notification is a provider notice without its wrapper tags")
    func copilotOtherNotificationIsANotice() {
        let line = #"{"type":"system.notification","data":{"content":"<system_notification>Agent is idle</system_notification>","kind":{"type":"agent_idle","agentId":"a-1"}}}"#

        #expect(CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line) == [.notice(message: "Agent is idle")])
    }

    @Test("A background job ending keeps the process monitor's progress clock running")
    func copilotJobCompletionIsProgressForTheMonitor() {
        let line = #"{"type":"system.notification","data":{"content":"<system_notification>Shell completed</system_notification>","kind":{"type":"shell_completed","shellId":"job-1","exitCode":0}}}"#

        let parsed = CopilotStreamEventParser.parseAll(line: line)

        guard case .control(let type)? = parsed.first, parsed.count == 1 else {
            Issue.record("expected one control frame, got \(parsed)")
            return
        }
        #expect(type == AgentOperationSignal.backgroundJobFinishedControlType)
        #expect(RuntimeProgressSignals.isProgressBearingControl(type))
    }

    @Test("Copilot partial output names its operation and is never a result")
    func copilotPartialOutputNamesItsOperation() {
        let line = #"{"type":"tool.execution_partial_result","data":{"toolCallId":"call-1","partialOutput":"test 7 passed"}}"#

        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events == [
            .control(type: "tool.execution_partial_result"),
            .operation(.progress(operationID: "call-1"))
        ])
        // The monitor still sees exactly the one liveness frame it did.
        let parsed = CopilotStreamEventParser.parseAll(line: line)
        guard case .control("tool.execution_partial_result")? = parsed.first, parsed.count == 1 else {
            Issue.record("expected the partial-result control alone, got \(parsed)")
            return
        }
    }

    @Test("Copilot partial output without a call id stays plain liveness")
    func copilotPartialOutputWithoutIDIsControlOnly() {
        let line = #"{"type":"tool.execution_progress","id":"frame-9","data":{"progressMessage":"still going"}}"#

        #expect(CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line) == [.control(type: "tool.execution_progress")])
    }

    // MARK: - Codex

    @Test("A failed Codex command carries its exit code and status as fields")
    func codexFailedCommandCarriesStructuredOutcome() {
        let line = #"{"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"swift test","exit_code":1,"status":"failed","aggregated_output":"Test failed"}}"#

        let events = CodexStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events.count == 2)
        #expect(events.first == .operation(.finished(
            operationID: "cmd-1", outcome: .failed, exitCode: 1, providerStatus: "failed"
        )))
        guard case .toolResult("cmd-1", _, true)? = events.last else {
            Issue.record("expected a failed result for cmd-1, got \(events)")
            return
        }
    }

    @Test("A successful Codex command reports exit code zero as success")
    func codexSuccessfulCommandReportsSuccess() {
        let line = #"{"type":"item.completed","item":{"id":"cmd-2","type":"command_execution","command":"true","exit_code":0,"status":"completed","aggregated_output":""}}"#

        let events = CodexStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events.first == .operation(.finished(
            operationID: "cmd-2", outcome: .succeeded, exitCode: 0, providerStatus: "completed"
        )))
    }

    @Test("A completed Codex tool item ends its call, with the outcome its status gives")
    func codexCompletedToolItemEndsItsCall() {
        func completed(_ fields: String) -> [AgentEvent] {
            CodexStreamEventParser.parseIdentifiedAgentEvents(
                line: #"{"type":"item.completed","item":{"id":"t1","type":"mcp_tool_call","tool":"search""# + fields + "}}"
            )
        }
        let done = completed(#","status":"completed""#)
        #expect(done.count == 3)
        #expect(done[1] == .operation(.finished(operationID: "t1", outcome: .succeeded, exitCode: nil, providerStatus: "completed")))
        #expect(done[2] == .toolResult(id: "t1", content: "", isError: false))

        let failed = completed(#","status":"failed""#)
        #expect(failed[1] == .operation(.finished(operationID: "t1", outcome: .failed, exitCode: nil, providerStatus: "failed")))
        #expect(failed[2] == .toolResult(id: "t1", content: "", isError: true))

        // Without a status the call ended, and nothing says how.
        let unstated = completed("")
        #expect(unstated[1] == .operation(.finished(operationID: "t1", outcome: .unknown, exitCode: nil, providerStatus: nil)))
    }

    // MARK: - OpenCode

    @Test("An OpenCode tool that completed without output still ends")
    func openCodeEmptyCompletionProducesAResult() {
        let line = #"{"type":"tool_use","part":{"id":"part-1","tool":"bash","state":{"status":"completed","input":{"command":"true"},"output":""}}}"#

        let events = OpenCodeStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events.count == 3)
        guard case .toolUse("bash", "part-1", _)? = events.first else {
            Issue.record("expected the bash call first, got \(events)")
            return
        }
        #expect(events[1] == .operation(.finished(
            operationID: "part-1", outcome: .succeeded, exitCode: nil, providerStatus: "completed"
        )))
        #expect(events[2] == .toolResult(id: "part-1", content: "", isError: false))
    }

    @Test("An OpenCode tool that is still running has no result")
    func openCodeRunningToolHasNoResult() {
        let line = #"{"type":"tool_use","part":{"id":"part-2","tool":"bash","state":{"status":"running","input":{"command":"sleep 60"}}}}"#

        let events = OpenCodeStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events.count == 1)
        guard case .toolUse("bash", "part-2", _)? = events.first else {
            Issue.record("expected only the call, got \(events)")
            return
        }
    }

    @Test("An OpenCode tool that errored without a message is a failure")
    func openCodeErrorWithoutMessageIsAFailure() {
        let line = #"{"type":"tool_use","part":{"id":"part-3","tool":"bash","state":{"status":"error","input":{"command":"false"}}}}"#

        let events = OpenCodeStreamEventParser.parseIdentifiedAgentEvents(line: line)

        #expect(events.contains(.operation(.finished(
            operationID: "part-3", outcome: .failed, exitCode: nil, providerStatus: "error"
        ))))
        #expect(events.last == .toolResult(id: "part-3", content: "", isError: true))
    }

    // MARK: - Antigravity

    @Test("An Antigravity DONE step without output is still a result for its step")
    func antigravityEmptyDoneIsAResult() {
        let line = #"{"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"DONE","tool_name":"write_file","tool_info":{"name":"write_file"}}}"#

        let events = AntigravityStreamEventParser.parseStructuredAgentEvents(line: line)

        #expect(events == [.toolResult(id: "step-4", content: "", isError: false)])
    }

    // MARK: - Outcome vocabulary

    @Test("An exit code decides the outcome; a status word decides only without one")
    func outcomeFromStatusAndExitCode() {
        #expect(AgentOperationOutcome(providerStatus: nil, exitCode: 0) == .succeeded)
        #expect(AgentOperationOutcome(providerStatus: "completed", exitCode: 2) == .failed)
        #expect(AgentOperationOutcome(providerStatus: "failed", exitCode: 0) == .failed)
        #expect(AgentOperationOutcome(providerStatus: "Completed", exitCode: nil) == .succeeded)
        #expect(AgentOperationOutcome(providerStatus: "error", exitCode: nil) == .failed)
        #expect(AgentOperationOutcome(providerStatus: "cancelled", exitCode: 130) == .cancelled)
    }

    @Test("A status this build does not know is unknown, never success")
    func unrecognizedStatusIsUnknown() throws {
        #expect(AgentOperationOutcome(providerStatus: "deferred", exitCode: nil) == .unknown)
        #expect(AgentOperationOutcome(providerStatus: nil, exitCode: nil) == .unknown)
        // A stored value from a newer build decodes rather than failing the record.
        let decoded = try JSONDecoder().decode([AgentOperationOutcome].self, from: Data(#"["succeeded","paused"]"#.utf8))
        #expect(decoded == [.succeeded, .unknown])
    }
}
