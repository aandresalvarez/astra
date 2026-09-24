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
}
