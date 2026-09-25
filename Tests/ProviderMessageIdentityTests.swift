import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Phase 2 of docs/specs/2026-09-23-provider-message-identity-plan.md: every
/// provider's assistant text carries the provider's own message identity.
@Suite("Provider message identity")
struct ProviderMessageIdentityTests {
    private static func fragment(_ events: [AgentEvent]) -> [AssistantMessageFragment] {
        events.compactMap { event in
            guard case .assistantMessage(.fragment(let fragment)) = event else { return nil }
            return fragment
        }
    }

    // MARK: - Copilot

    @Test("Copilot deltas and the final copy share the message id, tool requests or not")
    func copilotMessagesAreKeyedByMessageID() {
        let delta = CopilotStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"assistant.message_delta","data":{"messageId":"m1","deltaContent":"Reading it."}}"#
        )
        let narration = CopilotStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"assistant.message","data":{"messageId":"m1","content":"Reading it.","toolRequests":[{"toolCallId":"c1","name":"view"}]}}"#
        )
        let answer = CopilotStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"assistant.message","data":{"messageId":"m2","content":"Here is the reply.","phase":"commentary"}}"#
        )

        #expect(Self.fragment(delta) == [.init(key: "copilot:m1", kind: .delta, text: "Reading it.")])
        #expect(Self.fragment(narration) == [.init(key: "copilot:m1", kind: .final, text: "Reading it.")])
        #expect(Self.fragment(answer) == [.init(key: "copilot:m2", kind: .final, text: "Here is the reply.")])
    }

    @Test("Copilot's result frame names the session")
    func copilotResultNamesTheSession() {
        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"result","sessionId":"06ea7a4c","exitCode":0}"#
        )
        #expect(events.contains(.started(sessionID: "06ea7a4c", model: nil)))
        #expect(events.contains(.completed(summary: nil)))
    }

    // MARK: - Codex

    @Test("Codex agent messages are keyed finals, error items are notices")
    func codexMessagesAndWarnings() {
        let message = CodexStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"The draft is saved."}}"#
        )
        let warning = CodexStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Configured value for approval_policy is disallowed"}}"#
        )

        #expect(Self.fragment(message) == [.init(key: "codex:item_3", kind: .final, text: "The draft is saved.")])
        #expect(warning == [.notice(message: "Configured value for approval_policy is disallowed")])
    }

    @Test("Codex input tokens already include cached ones and are counted once")
    func codexCountsInputTokensOnce() {
        let events = CodexStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"turn.completed","usage":{"input_tokens":65359,"cached_input_tokens":53632,"output_tokens":1200}}"#
        )
        #expect(events.contains(.stats(inputTokens: 65359, outputTokens: 1200, costUSD: nil, durationMs: nil, turns: nil)))
    }

    @Test("A completed Codex file change records every entry of changes[] once")
    func codexFileChangesComeFromChanges() {
        let started = CodexStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"item.started","item":{"id":"item_6","type":"file_change","changes":[{"path":"/w/answer.md","kind":"add"}]}}"#
        )
        let completed = CodexStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"item.completed","item":{"id":"item_6","type":"file_change","changes":[{"path":"/w/answer.md","kind":"add"},{"path":"/w/notes.md","kind":"update"}],"status":"completed"}}"#
        )

        #expect(started == [.control(type: "item.started.file_change")])
        #expect(completed == [
            .fileChange(path: "/w/answer.md", kind: "add", summary: nil),
            .fileChange(path: "/w/notes.md", kind: "update", summary: nil)
        ])
    }

    // MARK: - Antigravity and OpenCode

    @Test("Antigravity response deltas are keyed by their step")
    func antigravityDeltasAreKeyedByStep() {
        let events = AntigravityStreamEventParser.parseStructuredAgentEvents(
            line: #"{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"Hi"}}"#
        ) ?? []
        #expect(Self.fragment(events) == [.init(key: "antigravity:step-3", kind: .delta, text: "Hi")])
    }

    @Test("An OpenCode text part is a final keyed by its part id")
    func openCodeTextPartsAreKeyed() {
        let events = OpenCodeStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"text","part":{"id":"prt_1","messageID":"msg_1","text":"Hello"}}"#
        )
        #expect(Self.fragment(events) == [.init(key: "opencode:prt_1", kind: .final, text: "Hello")])
    }

    @Test("The unkeyed entry points keep the shapes utility-prompt collectors aggregate")
    func unkeyedEntryPointsKeepLegacyShapes() {
        #expect(CopilotStreamEventParser.parseAgentEvents(
            line: #"{"type":"assistant.message","data":{"messageId":"m2","content":"Here is the reply."}}"#
        ) == [.completed(summary: "Here is the reply.")])
        #expect(CodexStreamEventParser.parseAgentEvents(
            line: #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Done."}}"#
        ) == [.completed(summary: "Done.")])
        #expect(CursorStreamEventParser.parseAgentEvents(
            line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"PING"}]},"model_call_id":"c-0"}"#
        ) == [.text(text: "PING")])
        #expect(OpenCodeStreamEventParser.parseAgentEvents(
            line: #"{"type":"text","part":{"id":"prt_1","text":"Hello"}}"#
        ) == [.text(text: "Hello")])
    }

    // MARK: - Cursor

    @Test("Cursor frames resolve by model call, and the id-less last frame adds only its new text")
    func cursorFramesResolveWithContinuation() {
        var pipeline = AgentRuntimeEventPipeline(supportsAstraRunProtocol: true)
        func resolve(_ line: String) -> [AssistantMessageFragment] {
            Self.fragment(CursorStreamEventParser.parseIdentifiedAgentEvents(line: line).flatMap { pipeline.process($0) })
        }
        let first = resolve(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading it."}]},"model_call_id":"c-0"}"#)
        let second = resolve(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the reply."}]},"model_call_id":"c-1"}"#)
        let last = resolve(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the reply.\n\nSaved."}]}}"#)
        let repeated = resolve(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the reply.\n\nSaved."}]}}"#)

        #expect(first == [.init(key: "cursor:c-0#0", kind: .final, text: "Reading it.")])
        #expect(second == [.init(key: "cursor:c-1#0", kind: .final, text: "Here is the reply.")])
        #expect(last == [.init(key: "cursor:c-1#0+1", kind: .final, text: "\n\nSaved.")])
        #expect(repeated.isEmpty)
    }

    @Test("An id-less Cursor frame that does not extend the previous message gets its own key")
    func cursorUnrelatedFrameGetsItsOwnKey() {
        var resolver = AssistantMessageIdentityResolver()
        _ = resolver.resolve(.cursorFrame(modelCallID: "c-0", text: "First."))
        #expect(resolver.resolve(.cursorFrame(modelCallID: nil, text: "Something else."))
            == .fragment(.init(key: "cursor:frame-1", kind: .final, text: "Something else.")))
    }

    // MARK: - Phase 4: adapter gaps

    @Test("Cursor tool calls become tool uses and results, and a successful edit a file change")
    func cursorToolCallsAreParsed() {
        let started = CursorStreamEventParser.parseAgentEvents(
            line: #"{"type":"tool_call","subtype":"started","call_id":"t1","tool_call":{"editToolCall":{"args":{"path":"/w/answer.md","streamContent":"the whole file"}}}}"#
        )
        let completed = CursorStreamEventParser.parseAgentEvents(
            line: #"{"type":"tool_call","subtype":"completed","call_id":"t1","tool_call":{"editToolCall":{"args":{"path":"/w/answer.md"},"result":{"success":{"linesAdded":3}}}}}"#
        )
        let failed = CursorStreamEventParser.parseAgentEvents(
            line: #"{"type":"tool_call","subtype":"completed","call_id":"t2","tool_call":{"readToolCall":{"args":{"path":"/w/x"},"result":{"error":{"message":"No such file"}}}}}"#
        )

        #expect(started == [.toolUse(name: "editToolCall", id: "t1", inputSummary: #"{"path":"\/w\/answer.md"}"#)])
        #expect(completed == [
            .toolResult(id: "t1", content: "Completed editToolCall", isError: false),
            .fileChange(path: "/w/answer.md", kind: "update", summary: nil)
        ])
        #expect(failed == [.toolResult(id: "t2", content: "No such file", isError: true)])
    }

    @Test("A Copilot apply_patch names its files as file changes")
    func copilotApplyPatchRecordsFileChanges() {
        let line = #"{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"apply_patch","arguments":"*** Begin Patch\n*** Add File: /w/answer.md\n+Hi\n*** Update File: /w/notes.md\n*** End Patch"}}"#
        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(line: line)
        #expect(events.contains(.fileChange(path: "/w/answer.md", kind: "add", summary: nil)))
        #expect(events.contains(.fileChange(path: "/w/notes.md", kind: "update", summary: nil)))
    }

    @Test("A Copilot frame whose JSON broke is a diagnostic, never answer text")
    func copilotMalformedJSONIsNotText() {
        let events = CopilotStreamEventParser.parseIdentifiedAgentEvents(
            line: #"{"type":"assistant.message","data":{"content":"token ******"broken}}"#
        )
        #expect(events.count == 1)
        guard case .unknown(_, let type, _) = events.first else {
            Issue.record("expected a diagnostic, got \(events)")
            return
        }
        #expect(type == "malformed_json")
    }

    @Test("The monitor does not count a Claude main-agent envelope again; a subagent's stays text")
    func claudeMonitorSkipsRepeatedEnvelopes() {
        let main = #"{"type":"assistant","message":{"id":"msg_A","content":[{"type":"text","text":"Hello"}]},"parent_tool_use_id":null}"#
        let sub = #"{"type":"assistant","message":{"id":"msg_S","content":[{"type":"text","text":"Sub"}]},"parent_tool_use_id":"toolu_1"}"#
        let mainEvents = ClaudeMessageIdentity.monitorEvents(StreamEventParser.parseAll(line: main), line: main)
        #expect(!mainEvents.contains { if case .text = $0 { true } else { false } })
        #expect(mainEvents.contains { if case .control("assistant.final_copy") = $0 { true } else { false } })
        #expect(ClaudeMessageIdentity.monitorEvents(StreamEventParser.parseAll(line: sub), line: sub).contains {
            if case .text = $0 { true } else { false }
        })
    }
}
