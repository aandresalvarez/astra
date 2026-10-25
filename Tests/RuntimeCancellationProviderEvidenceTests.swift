import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Cancellation evidence from native provider streams")
struct RuntimeCancellationProviderEvidenceTests {
    private let agyTerminal = #"{"event":"result","result":{"status":"SUCCESS","response":"done","num_turns":1}}"#
    private func observe(_ line: String, runtime: AgentRuntimeID, in evidence: RuntimeExecutionProcessEvidence) {
        evidence.observeFrame(line, parsesJSONLines: true,
            events: AgentRuntimeAdapterRegistry.adapter(for: runtime).parseProcessEvents(line: line, parsesJSONLines: true))
    }

    @Test("Captured tool-free streams require the provider's terminal frame", arguments: ["codex", "antigravity"])
    func capturedNativeStream(provider: String) throws {
        let runtime: AgentRuntimeID = provider == "codex" ? .codexCLI : .antigravityCLI
        let url = try #require(Bundle.module.url(forResource: "cancellation-tool-free", withExtension: "jsonl",
            subdirectory: "ProviderStreams/\(provider)"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime)
        for line in lines.dropLast() {
            observe(line, runtime: runtime, in: evidence)
            #expect(!evidence.toolsStopped, "An intermediate response cannot prove the turn finished")
        }
        let terminal = try #require(lines.last)
        observe(terminal, runtime: runtime, in: evidence)
        #expect(evidence.toolsStopped)
        for (index, line) in lines.enumerated() {
            let single = RuntimeExecutionProcessEvidence(runtime: runtime)
            observe(line, runtime: runtime, in: single)
            observe(terminal, runtime: runtime, in: single)
            #expect(single.toolsStopped, "Captured \(provider) frame \(index) rejected")
        }
    }

    @Test("Empty Antigravity text steps remain nonterminal", arguments: [
        #"{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":""}}"#
    ])
    func emptyTextSteps(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
        observe(line, runtime: .antigravityCLI, in: evidence)
        #expect(!evidence.toolsStopped)
        observe(agyTerminal, runtime: .antigravityCLI, in: evidence)
        #expect(evidence.toolsStopped)
    }

    @Test("Antigravity tools and malformed or unknown steps stay uncertain", arguments: [
        #"{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"run_command"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"output":"done"}}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"future_execution","text_delta":"done"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"FUTURE","step_type":"agent_response","text_delta":"done"}}"#,
        #"{"event":"STEP_UPDATE","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","tool_name":"run_command","text_delta":"done"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"AGENT_RESPONSE","tool_name":"run_command","text_delta":"done"}}"#,
        #"{"event":"step_update","step_update":{"state":"DONE","step_type":"user_input"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"user_input","tool_info":{}}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","tool_name":"run_command","text_delta":"done"}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":42}}"#,
        #"{"event":"step_update","step_update":{"step_index":-1,"state":"DONE","step_type":"agent_response","text_delta":"done"}}"#
    ])
    func uncertainSteps(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
        observe(line, runtime: .antigravityCLI, in: evidence)
        observe(agyTerminal, runtime: .antigravityCLI, in: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Text bookkeeping never hides a second parsed tool event")
    func mixedFrame() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
        evidence.observeFrame(#"{"event":"step_update","step_update":{"step_index":0,"state":"DONE","step_type":"user_input"}}"#,
            parsesJSONLines: true, events: [.control(type: "agy.step.user_input"), .toolUse(name: "run_command", id: "1", input: nil)])
        observe(agyTerminal, runtime: .antigravityCLI, in: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Codex tool completion still cannot prove detached work stopped")
    func codexTool() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .codexCLI)
        observe(#"{"type":"item.completed","item":{"id":"tool","type":"command_execution","exit_code":0,"status":"completed"}}"#,
            runtime: .codexCLI, in: evidence)
        observe(#"{"type":"turn.completed"}"#, runtime: .codexCLI, in: evidence)
        #expect(!evidence.toolsStopped)
    }
}
