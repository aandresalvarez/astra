import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider completion safety")
struct RuntimeProviderCompletionEvidenceTests {
    private func observe(_ line: String, runtime: AgentRuntimeID, evidence: RuntimeExecutionProcessEvidence) {
        evidence.observeFrame(line, parsesJSONLines: true,
            events: AgentRuntimeAdapterRegistry.adapter(for: runtime).parseProcessEvents(line: line, parsesJSONLines: true))
    }

    @Test("Copilot intermediate usage cannot end a run")
    func copilotUsageIsNotTerminal() {
        let events = CopilotStreamEventParser.parseAll(line: #"{"type":"usage","input_tokens":1,"output_tokens":2}"#)
        #expect(!events.contains { if case .result = $0 { true } else { false } })
        #expect(events.contains { if case .usage = $0 { true } else { false } })
    }

    @Test("A provider's result can end its turn without granting tool cleanup")
    func terminalWithToolUsage() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .claudeCode)
        let result = #"{"type":"result","is_error":false,"result":"Finished","usage":{"server_tool_use":{"web_search_requests":1}}}"#
        observe(result, runtime: .claudeCode, evidence: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.providerTurnEnded)
        #expect(!evidence.toolsStopped)
    }

    @Test("An invalid Copilot exit code cannot complete the turn or release the workspace")
    func invalidCopilotExitCode() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(#"{"type":"result","sessionId":"s","exitCode":true,"result":"partial"}"#, runtime: .copilotCLI, evidence: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.providerTurnEnded)
        #expect(!evidence.toolsStopped)
    }

    @Test("Copilot result envelopes without a session receipt can finish the turn only", arguments: [
        #"{"type":"result","data":{"usage":{"input_tokens":4,"output_tokens":5}}}"#,
        #"{"type":"result","data":{"content":"done"}}"#,
        #"{"type":"result","data":{"content":"done"},"usage":{"input_tokens":4,"output_tokens":5}}"#,
        #"{"type":"result","data":{},"usage":{"input_tokens":4,"output_tokens":5}}"#,
        #"{"type":"result","payload":{"summary":"done"}}"#
    ])
    func copilotSummaryWithoutSession(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(line, runtime: .copilotCLI, evidence: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.providerTurnEnded)
        #expect(!evidence.toolsStopped)
    }

    @Test("Only a current native terminal can arm the structured provider's terminal reap", arguments: [
        #"{"type":"result","is_error":0,"result":"mistyped"}"#,
        #"{"type":"result","is_error":false,"parent_tool_use_id":"child","result":"subtask"}"#,
        #"{"type":"control_request","request_id":"late","request":{"subtype":"ping"}}"#
    ])
    func terminalReapRequiresCurrentEvidence(later: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .claudeCode)
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: .max, terminalProgressExitGraceSeconds: 0, nativeTurnEvidence: evidence)
        let root = #"{"type":"result","is_error":false,"result":"done"}"#
        for frame in [root, later] {
            let events = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode).parseProcessEvents(line: frame, parsesJSONLines: true)
            evidence.observeFrame(frame, parsesJSONLines: true, events: events)
            for event in events { _ = monitor.processEvent(event, process: nil) }
        }
        #expect(!evidence.providerTurnEnded)
        #expect(!monitor.evaluateWatchdogTimeoutForTesting())
        observe(root, runtime: .claudeCode, evidence: evidence)
        #expect(monitor.evaluateWatchdogTimeoutForTesting())
    }

    @Test("A complete captured provider exchange keeps its verdict after trailing metadata",
          arguments: ProviderStreamFixture.all.filter { $0.scenario == "answer-write-signoff" })
    func capturedTurnEnd(fixture: ProviderStreamFixture) throws {
        let evidence = RuntimeExecutionProcessEvidence(runtime: fixture.runtime)
        for line in try fixture.frameLines() {
            observe(line, runtime: fixture.runtime, evidence: evidence)
        }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.providerTurnEnded)
    }

    @Test("A native ending cannot attest to a turn after a truncated next frame", arguments: [
        (AgentRuntimeID.codexCLI, #"{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}"#),
        (.openCodeCLI, #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"s","id":"f","messageID":"m","reason":"stop"}}"#)
    ])
    func truncatedTail(runtime: AgentRuntimeID, stop: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime)
        observe(stop, runtime: runtime, evidence: evidence)
        observe(#"{"type":"unfinished"#, runtime: runtime, evidence: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.providerTurnEnded)
        #expect(!evidence.toolsStopped)
    }

    @Test("Copilot text cannot hide tool requests or unknown execution", arguments: [
        #"{"type":"assistant.message","data":{"content":"Working","toolRequests":[{"toolCallId":"call","name":"bash","arguments":{"command":"sleep 300 &"}}]}}"#,
        #"{"type":"future.remote_execution","content":"Looks like ordinary text"}"#
    ])
    func copilotTextDoesNotProveSafety(line: String) {
        let terminal = #"{"type":"result","sessionId":"copilot-evidence-session","exitCode":0,"result":"done"}"#
        let cleanEvidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(#"{"type":"assistant.message","data":{"content":"Done"}}"#, runtime: .copilotCLI, evidence: cleanEvidence)
        observe(terminal, runtime: .copilotCLI, evidence: cleanEvidence)
        cleanEvidence.processExited(naturally: true, stdoutEOF: true)
        #expect(cleanEvidence.toolsStopped)

        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(line, runtime: .copilotCLI, evidence: evidence)
        observe(terminal, runtime: .copilotCLI, evidence: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.toolsStopped)
    }

    @Test("OpenCode step completion is recognized but is not a terminal run")
    func openCodeStepIsNotTerminal() {
        let line = #"{"type":"step_finish","sessionID":"ses_test","part":{"type":"step-finish","id":"prt_test","sessionID":"ses_test","messageID":"msg_test","reason":"stop","cost":0,"tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}}"#
        let events = OpenCodeStreamEventParser.parseAll(line: line)
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
        #expect(!events.contains { if case .result = $0 { true } else { false } })
        #expect(!events.contains { if case .usage = $0 { true } else { false } })
        let normalized = OpenCodeStreamAccounting().normalize(line)
        #expect(!normalized.invalidUsage)
        #expect(OpenCodeStreamEventParser.parseAll(line: normalized.line).contains {
            if case .usage(1, 2) = $0 { true } else { false }
        })
    }
}
