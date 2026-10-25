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
