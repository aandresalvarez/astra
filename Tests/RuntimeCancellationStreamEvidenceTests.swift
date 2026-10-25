import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Cancellation evidence from streamed Claude text")
struct RuntimeCancellationStreamEvidenceTests {
    private let terminal = #"{"type":"result","result":"done","is_error":false,"num_turns":1}"#

    private func observe(_ line: String, in evidence: RuntimeExecutionProcessEvidence) {
        evidence.observeFrame(line, parsesJSONLines: true, events: AgentRuntimeAdapterRegistry.adapter(for: .claudeCode).parseProcessEvents(line: line, parsesJSONLines: true))
    }

    @Test("The captured native tool-free stream proves cleanup through the production adapter")
    func capturedNativeStream() throws {
        let url = try #require(Bundle.module.url(forResource: "cancellation-tool-free", withExtension: "jsonl",
            subdirectory: "ProviderStreams/claude"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let evidence = RuntimeExecutionProcessEvidence()
        for line in lines.dropLast() { observe(line, in: evidence) }
        #expect(!evidence.toolsStopped)
        observe(try #require(lines.last), in: evidence)
        #expect(evidence.toolsStopped)
        // Every frame is checked individually as well, identifying the exact
        // production projection if a future provider change prevents proof.
        for (index, line) in lines.enumerated() {
            let single = RuntimeExecutionProcessEvidence()
            observe(line, in: single); observe(terminal, in: single)
            #expect(single.toolsStopped, "Captured frame \(index) rejected")
        }
    }

    @Test("Known text and thinking bookkeeping permits proof only after a terminal frame", arguments: [
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking","thinking":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"signed"}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":""}]}}"#
    ])
    func knownTextBookkeeping(line: String) {
        let evidence = RuntimeExecutionProcessEvidence()
        observe(line, in: evidence)
        #expect(!evidence.toolsStopped)
        observe(terminal, in: evidence)
        #expect(evidence.toolsStopped)
    }

    @Test("Tools, malformed blocks and unfamiliar deltas remain uncertain", arguments: [
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"tool","name":"Bash","input":{}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking","thinking":42}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"future_tool","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":12}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"future_delta"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"future_delta","text":"looks harmless"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":""}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text"}]}}"#,
        #"{"type":"assistant","message":{"id":"msg-test","content":[{"type":"text","text":"done"},{"type":"thinking"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":""},{"type":"future_tool"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":""},{"type":"tool_use","id":"tool","name":"Bash","input":{}}]}}"#
    ])
    func uncertainFramesStaySticky(line: String) {
        let evidence = RuntimeExecutionProcessEvidence()
        observe(line, in: evidence)
        observe(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#, in: evidence)
        observe(terminal, in: evidence)
        #expect(!evidence.toolsStopped)
    }

    @Test("Recognized text bookkeeping cannot hide another parsed tool event in the frame")
    func bookkeepingCannotMaskToolEvent() {
        let evidence = RuntimeExecutionProcessEvidence()
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#
        evidence.observeFrame(line, parsesJSONLines: true, events: [
            .control(type: "stream_event.content_block_start"),
            .toolUse(name: "Bash", id: "tool", input: ["command": "sleep 10"])
        ])
        observe(terminal, in: evidence)
        #expect(!evidence.toolsStopped)
    }
}
