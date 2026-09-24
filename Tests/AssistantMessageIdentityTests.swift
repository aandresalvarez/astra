import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Assistant message identity")
struct AssistantMessageIdentityTests {
    private static func messageStart(_ id: String, parent: String? = nil) -> String {
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","content":[]}},"parent_tool_use_id":\#(json(parent))}"#
    }

    private static func textDelta(_ text: String, index: Int, parent: String? = nil) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(json(text))}},"parent_tool_use_id":\#(json(parent))}"#
    }

    private static func envelope(_ text: String, id: String?, parent: String? = nil) -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        return #"{"type":"assistant","message":{\#(idField)"role":"assistant","content":[{"type":"text","text":\#(json(text))}]},"parent_tool_use_id":\#(json(parent))}"#
    }

    private static func json(_ value: String?) -> String {
        guard let value else { return "null" }
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func claudeEvents(_ line: String) -> [AgentEvent] {
        AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
            .parseWorkerStreamEvents(line: line, parsesJSONLines: true)
            .agentEvents
    }

    private static func fragments(_ events: [AgentEvent]) -> [AssistantMessageFragment] {
        events.compactMap { event in
            guard case .assistantMessage(.fragment(let fragment)) = event else { return nil }
            return fragment
        }
    }

    // MARK: - Claude parsing

    @Test("Claude lines carry their message identity")
    func claudeLinesCarryIdentity() {
        #expect(Self.claudeEvents(Self.messageStart("msg_A")) == [
            .assistantMessage(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)),
            .control(type: "stream_event.message_start")
        ])
        #expect(Self.claudeEvents(Self.textDelta("Hel", index: 2)) == [
            .assistantMessage(.claudeTextDelta(blockIndex: 2, parentToolUseID: nil, text: "Hel"))
        ])
        #expect(Self.claudeEvents(Self.envelope("Hello", id: "msg_A", parent: "toolu_1")) == [
            .assistantMessage(.claudeTextFinal(messageID: "msg_A", parentToolUseID: "toolu_1", text: "Hello"))
        ])
    }

    @Test("A Claude envelope without a message id stays plain text")
    func envelopeWithoutIDStaysText() {
        #expect(Self.claudeEvents(Self.envelope("Hello", id: nil)) == [.text(text: "Hello")])
    }

    // MARK: - Resolver

    @Test("A streamed block and its envelope resolve to the same key")
    func deltaAndFinalShareAKey() {
        var resolver = AssistantMessageIdentityResolver()
        #expect(resolver.resolve(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)) == .consumed)
        // Block 0 is thinking, so the first text block streams at index 1.
        let first = resolver.resolve(.claudeTextDelta(blockIndex: 1, parentToolUseID: nil, text: "One"))
        let second = resolver.resolve(.claudeTextDelta(blockIndex: 3, parentToolUseID: nil, text: "Two"))
        let firstFinal = resolver.resolve(.claudeTextFinal(messageID: "msg_A", parentToolUseID: nil, text: "One"))
        let secondFinal = resolver.resolve(.claudeTextFinal(messageID: "msg_A", parentToolUseID: nil, text: "Two"))

        #expect(first == .fragment(.init(key: "claude:msg_A#0", kind: .delta, text: "One")))
        #expect(second == .fragment(.init(key: "claude:msg_A#1", kind: .delta, text: "Two")))
        #expect(firstFinal == .fragment(.init(key: "claude:msg_A#0", kind: .final, text: "One")))
        #expect(secondFinal == .fragment(.init(key: "claude:msg_A#1", kind: .final, text: "Two")))
    }

    @Test("A subagent's messages do not move the main agent's current message")
    func subagentStreamsAreSeparate() {
        var resolver = AssistantMessageIdentityResolver()
        _ = resolver.resolve(.claudeMessageStart(messageID: "msg_Main", parentToolUseID: nil))
        _ = resolver.resolve(.claudeMessageStart(messageID: "msg_Sub", parentToolUseID: "toolu_1"))

        #expect(resolver.resolve(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "main"))
            == .fragment(.init(key: "claude:msg_Main#0", kind: .delta, text: "main")))
        #expect(resolver.resolve(.claudeTextDelta(blockIndex: 0, parentToolUseID: "toolu_1", text: "sub"))
            == .fragment(.init(key: "claude:msg_Sub#0", kind: .delta, text: "sub", isSubagent: true)))
    }

    @Test("A delta before any message start keeps the unkeyed path")
    func deltaWithoutStartIsUnkeyed() {
        var resolver = AssistantMessageIdentityResolver()
        #expect(resolver.resolve(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "Hi")) == .unkeyed("Hi"))
    }

    // MARK: - Pipeline

    @Test("The pipeline turns a streamed Claude message into deltas and one final")
    func pipelineEmitsDeltasThenFinal() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let lines = [
            Self.messageStart("msg_A"),
            Self.textDelta("Line one is short.\n", index: 0),
            Self.textDelta("Done.", index: 0),
            Self.envelope("Line one is short.\nDone.", id: "msg_A")
        ]
        let events = lines.flatMap(Self.claudeEvents).flatMap { pipeline.process($0) } + pipeline.flushAgentEvents()

        #expect(Self.fragments(events) == [
            .init(key: "claude:msg_A#0", kind: .delta, text: "Line one is short.\n"),
            .init(key: "claude:msg_A#0", kind: .delta, text: "Done."),
            .init(key: "claude:msg_A#0", kind: .final, text: "Line one is short.\nDone.")
        ])
        #expect(!events.contains { if case .text = $0 { true } else { false } })
    }

    @Test("A marker streamed in deltas is not emitted again by the final copy")
    func finalDoesNotRepeatMarkers() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        let marker = #"ASTRA_EVENT {"v":1,"type":"complete","summary":"Finished.","verifiedBy":"unit tests"}"#
        let text = "All set.\n\(marker)\n"
        let events = [
            AgentEvent.assistantMessage(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)),
            .assistantMessage(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: text)),
            .assistantMessage(.claudeTextFinal(messageID: "msg_A", parentToolUseID: nil, text: text))
        ].flatMap { pipeline.process($0) }

        let markers = events.filter { if case .astraProtocol = $0 { true } else { false } }
        #expect(markers.count == 1)
        #expect(Self.fragments(events).last == .init(key: "claude:msg_A#0", kind: .final, text: "All set.\n"))
    }

    @Test("A delta after its message's final copy is dropped")
    func lateDeltaIsDropped() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        _ = pipeline.process(.assistantMessage(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)))
        _ = pipeline.process(.assistantMessage(.claudeTextFinal(messageID: "msg_A", parentToolUseID: nil, text: "Done.")))

        #expect(pipeline.process(.assistantMessage(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "Done."))).isEmpty)
    }

    @Test("Line buffering never splices two messages together")
    func messagesHaveTheirOwnLineBuffers() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        _ = pipeline.process(.assistantMessage(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)))
        // Could be the start of a marker, so the filter holds it back.
        let held = pipeline.process(.assistantMessage(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "ASTRA_")))
        _ = pipeline.process(.assistantMessage(.claudeMessageStart(messageID: "msg_B", parentToolUseID: nil)))
        let other = pipeline.process(.assistantMessage(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "Hello\n")))
        let flushed = pipeline.flushAgentEvents()

        #expect(held.isEmpty)
        #expect(Self.fragments(other) == [.init(key: "claude:msg_B#0", kind: .delta, text: "Hello\n")])
        #expect(Self.fragments(flushed) == [.init(key: "claude:msg_A#0", kind: .delta, text: "ASTRA_")])
    }

    @Test("Without the run protocol, keyed fragments pass through unfiltered")
    func unsupportedProtocolPassesFragmentsThrough() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: false)
        _ = pipeline.process(.assistantMessage(.claudeMessageStart(messageID: "msg_A", parentToolUseID: nil)))
        let events = pipeline.process(.assistantMessage(.claudeTextDelta(blockIndex: 0, parentToolUseID: nil, text: "ASTRA_")))

        #expect(Self.fragments(events) == [.init(key: "claude:msg_A#0", kind: .delta, text: "ASTRA_")])
        #expect(pipeline.flushAgentEvents().isEmpty)
    }
}
