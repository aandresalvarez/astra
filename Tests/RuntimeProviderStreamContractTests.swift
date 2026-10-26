import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider stream cleanup contracts")
struct RuntimeProviderStreamContractTests {
    private static let providers: [String: AgentRuntimeID] = ["claude": .claudeCode, "codex": .codexCLI,
        "cursor": .cursorCLI, "antigravity": .antigravityCLI, "copilot": .copilotCLI]

    private func observe(_ line: String, runtime: AgentRuntimeID, into evidence: RuntimeExecutionProcessEvidence) {
        evidence.observeFrame(line, parsesJSONLines: true,
            events: AgentRuntimeAdapterRegistry.adapter(for: runtime).parseProcessEvents(line: line, parsesJSONLines: true))
    }

    @Test("Captured installed CLI envelopes require their last terminal signal", arguments: ["claude", "codex", "cursor", "antigravity", "copilot"])
    func captured(provider: String) throws {
        let runtime = try #require(Self.providers[provider])
        let url = try #require(Bundle.module.url(forResource: "recovery-captured-20261024", withExtension: "jsonl",
            subdirectory: "ProviderStreams/\(provider)"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let terminal = try #require(lines.last)
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime)
        for line in lines.dropLast() {
            observe(line, runtime: runtime, into: evidence)
            #expect(!evidence.toolsStopped)
        }
        observe(terminal, runtime: runtime, into: evidence)
        #expect(evidence.toolsStopped)
        let resumed = try #require(lines.first { line in
            guard let frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return false }
            if case .activity = RuntimeProviderFrameEvidence.classify(frame, runtime: runtime) { return true }
            return false
        })
        observe(resumed, runtime: runtime, into: evidence)
        #expect(!evidence.toolsStopped, "Later native activity invalidates the earlier terminal")
        observe(terminal, runtime: runtime, into: evidence)
        #expect(evidence.toolsStopped)
        for (index, line) in lines.enumerated() {
            let isolated = RuntimeExecutionProcessEvidence(runtime: runtime)
            observe(line, runtime: runtime, into: isolated)
            observe(terminal, runtime: runtime, into: isolated)
            #expect(isolated.toolsStopped, "Rejected captured \(provider) frame \(index)")
        }
        // Future output, even when the presentation parser renders it as text,
        // cannot preserve an earlier terminal proof.
        observe(#"{"type":"future.remote_execution","content":"Still working"}"#, runtime: runtime, into: evidence)
        observe(terminal, runtime: runtime, into: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Antigravity continuation context metadata still requires the final frame")
    func antigravityContinuationMetadata() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
        let metadata = #"{"event":"step_update","step_update":{"conversation_id":"qa","step_index":3,"state":"DONE","step_type":"system_message","duration_seconds":0.000089}}"#
        let terminal = #"{"event":"result","result":{"status":"SUCCESS","response":"Complete"}}"#
        observe(metadata, runtime: .antigravityCLI, into: evidence)
        #expect(!evidence.toolsStopped)
        observe(terminal, runtime: .antigravityCLI, into: evidence)
        #expect(evidence.toolsStopped)
        for extra in [#", "tool_name":"shell""#, #", "future_work":true"#] {
            let uncertain = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
            observe(metadata.replacingOccurrences(of: "0.000089}", with: "0.000089" + extra + "}"), runtime: .antigravityCLI, into: uncertain)
            observe(terminal, runtime: .antigravityCLI, into: uncertain)
            #expect(!uncertain.toolsStopped)
        }
        let active = RuntimeExecutionProcessEvidence(runtime: .antigravityCLI)
        observe(metadata.replacingOccurrences(of: "DONE", with: "ACTIVE"), runtime: .antigravityCLI, into: active)
        observe(terminal, runtime: .antigravityCLI, into: active)
        #expect(!active.toolsStopped)
    }

    @Test("Copilot accounting and error frames alone never certify a stopped session", arguments: [
        #"{"type":"usage","content":"done","input_tokens":1}"#,
        #"{"type":"session.shutdown","data":{"modelMetrics":{}}}"#,
        #"{"type":"model.call_failure","data":{"errorMessage":"Retryable"}}"#,
        #"{"type":"session.error","data":{"message":"Provider unavailable"}}"#
    ])
    func copilotIntermediate(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(line, runtime: .copilotCLI, into: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.toolsStopped)
    }

    @Test("Hidden tool declarations survive text projection", arguments: ["toolRequests", "tool_requests"], [false, true])
    func hiddenCopilotTools(key: String, nested: Bool) throws {
        var frame: [String: Any] = ["type": "assistant.message", "data": ["content": "Working"]]
        let requests: [[String: Any]] = [["name": "bash", "arguments": ["command": "sleep 100 &"]]]
        if nested { frame["data"] = ["content": "Working", key: requests] } else { frame[key] = requests }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        observe(line, runtime: .copilotCLI, into: evidence)
        observe(#"{"type":"result","sessionId":"test","exitCode":0}"#, runtime: .copilotCLI, into: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Final counters and partial tool signals disprove tool-free Claude cleanup", arguments: [
        #"{"type":"result","is_error":false,"subagent_stats":{"spawned":1}}"#,
        #"{"type":"result","is_error":false,"usage":{"server_tool_use":{"web_search_requests":1}}}"#,
        #"{"type":"result","is_error":false,"queued_turn_count":1}"#,
        #"{"type":"result","is_error":false,"permission_denials":[{}]}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"}}}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{},"usage":{"server_tool_use":{"web_search_requests":1}}}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"server_tool_use":{"web_search_requests":1}}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"stop_reason":"tool_use"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":""}]}}"#
    ])
    func incompleteClaudeStream(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .claudeCode)
        observe(line, runtime: .claudeCode, into: evidence)
        observe(#"{"type":"result","is_error":false,"result":"done"}"#, runtime: .claudeCode, into: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Codex cannot accept another provider's result")
    func providerBinding() {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .codexCLI)
        observe(#"{"type":"result","exitCode":0,"sessionId":"test","result":"done"}"#, runtime: .codexCLI, into: evidence)
        observe(#"{"type":"turn.completed"}"#, runtime: .codexCLI, into: evidence)
        #expect(!evidence.toolsStopped)
    }
}
