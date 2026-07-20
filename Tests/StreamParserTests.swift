import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// MARK: - Inline decoder types (mirrors StreamEventParser structs)

private struct BaseEvent: Decodable { let type: String; let session_id: String?; let model: String? }
private struct ContentBlock: Decodable { let type: String; let text: String?; let thinking: String?; let name: String?; let id: String? }
private struct Message: Decodable { let content: [ContentBlock]? }
private struct AssistantEvent: Decodable { let type: String; let message: Message? }
private struct ModelUsageEntry: Decodable {
    let inputTokens: Int?; let outputTokens: Int?
    let cacheReadInputTokens: Int?; let cacheCreationInputTokens: Int?; let costUSD: Double?
}
private struct ResultEvent: Decodable {
    let type: String; let result: String?; let total_cost_usd: Double?
    let duration_ms: Int?; let num_turns: Int?; let is_error: Bool?
    let modelUsage: [String: ModelUsageEntry]?
}

private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(type, from: data)
}

// MARK: - Test data

private let systemJSON = """
{"type":"system","subtype":"init","cwd":"/tmp","session_id":"abc123","model":"claude-sonnet-4-6"}
"""

private let thinkingJSON = """
{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Let me think about this."}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":0}}}
"""

private let textJSON = """
{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg2","type":"message","role":"assistant","content":[{"type":"text","text":"Hello world!"}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":5}}}
"""

private let toolUseJSON = """
{"type":"assistant","message":{"model":"claude-sonnet-4-6","id":"msg3","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_123","name":"Glob","input":{"pattern":"*"}}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":10}}}
"""

private let partialThinkingDeltaJSON = """
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants a web page"}},"session_id":"session-1","parent_tool_use_id":null,"uuid":"event-1"}
"""

private let partialTextDeltaJSON = """
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"I will create the requested page."}},"session_id":"session-1","parent_tool_use_id":null,"uuid":"event-2"}
"""

private let resultJSON = """
{"type":"result","subtype":"success","is_error":false,"duration_ms":3401,"num_turns":1,"result":"Hello world!","total_cost_usd":0.029,"modelUsage":{"claude-sonnet-4-6":{"inputTokens":3,"outputTokens":15,"cacheReadInputTokens":0,"cacheCreationInputTokens":7849,"costUSD":0.029}}}
"""

private let errorResultJSON = """
{"type":"result","subtype":"error","is_error":true,"duration_ms":100,"num_turns":0,"result":"Error occurred","total_cost_usd":0.001,"modelUsage":{}}
"""

// MARK: - Tests

@Suite("Stream Event Parser")
struct StreamParserTests {

    @Test("System event parsing")
    func systemEvent() throws {
        let event = try decode(systemJSON, as: BaseEvent.self)
        #expect(event.type == "system")
        #expect(event.session_id == "abc123")
        #expect(event.model == "claude-sonnet-4-6")
    }

    @Test("Thinking event parsing")
    func thinkingEvent() throws {
        let event = try decode(thinkingJSON, as: AssistantEvent.self)
        let content = try #require(event.message?.content?.first)
        #expect(content.type == "thinking")
        #expect(content.thinking == "Let me think about this.")
    }

    @Test("Text event parsing")
    func textEvent() throws {
        let event = try decode(textJSON, as: AssistantEvent.self)
        let content = try #require(event.message?.content?.first)
        #expect(content.type == "text")
        #expect(content.text == "Hello world!")
    }

    @Test("Tool use event parsing")
    func toolUseEvent() throws {
        let event = try decode(toolUseJSON, as: AssistantEvent.self)
        let content = try #require(event.message?.content?.first)
        #expect(content.type == "tool_use")
        #expect(content.name == "Glob")
        #expect(content.id == "tool_123")
    }

    @Test("Failed tool result preserves error metadata")
    func failedToolResultPreservesErrorMetadata() throws {
        let json = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_pr","is_error":true,"content":"gh pr create failed"}]}}"#

        let parsed = StreamEventParser.parse(line: json)
        guard case .toolResult(let toolID, let content, let isError) = parsed else {
            Issue.record("Expected a structured tool result, got \(String(describing: parsed))")
            return
        }

        #expect(toolID == "tool_pr")
        #expect(content == "gh pr create failed")
        #expect(isError)
    }

    @Test("All tool results in one Claude user message are preserved")
    func multipleToolResultsArePreserved() {
        let json = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_ok","is_error":false,"content":"done"},{"type":"tool_result","tool_use_id":"tool_pr","is_error":true,"content":"gh pr create failed"}]}}"#

        let parsed = StreamEventParser.parseAll(line: json)

        #expect(parsed.count == 2)
        #expect(parsed.contains {
            if case .toolResult(let id, let content, let isError) = $0 {
                return id == "tool_ok" && content == "done" && !isError
            }
            return false
        })
        #expect(parsed.contains {
            if case .toolResult(let id, let content, let isError) = $0 {
                return id == "tool_pr" && content == "gh pr create failed" && isError
            }
            return false
        })
    }

    @Test("Assistant usage event is emitted with cache tokens")
    func assistantUsageEvent() throws {
        let events = StreamEventParser.parseAll(line: textJSON)
        #expect(events.contains {
            if case .usage(let input, let output) = $0 {
                return input == 101 && output == 5
            }
            return false
        })
    }

    @Test("Partial thinking delta parses as semantic thinking")
    func partialThinkingDeltaParsesAsThinking() throws {
        let parsed = StreamEventParser.parse(line: partialThinkingDeltaJSON)
        guard case .thinking(let text) = parsed else {
            Issue.record("Expected .thinking, got \(String(describing: parsed))")
            return
        }
        #expect(text == "The user wants a web page")
    }

    @Test("Partial text delta parses as visible text")
    func partialTextDeltaParsesAsVisibleText() throws {
        let parsed = StreamEventParser.parse(line: partialTextDeltaJSON)
        guard case .text(let text) = parsed else {
            Issue.record("Expected .text, got \(String(describing: parsed))")
            return
        }
        #expect(text == "I will create the requested page.")
    }

    @Test("Result event parsing")
    func resultEvent() throws {
        let event = try decode(resultJSON, as: ResultEvent.self)
        #expect(event.type == "result")
        #expect(event.result == "Hello world!")
        #expect(event.total_cost_usd == 0.029)
        #expect(event.is_error == false)
        #expect(event.num_turns == 1)
        #expect(event.duration_ms == 3401)

        let usage = try #require(event.modelUsage?["claude-sonnet-4-6"])
        #expect(usage.inputTokens == 3)
        #expect(usage.outputTokens == 15)
        #expect(usage.cacheCreationInputTokens == 7849)
        let totalInput = (usage.inputTokens ?? 0) + (usage.cacheReadInputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
        #expect(totalInput == 7852)
    }

    @Test("Error result parsing")
    func errorResult() throws {
        let event = try decode(errorResultJSON, as: ResultEvent.self)
        #expect(event.is_error == true)
        #expect(event.result == "Error occurred")
    }

    @Test("Multi-line buffer parsing")
    func lineBufferParsing() throws {
        let lines = [systemJSON, textJSON, resultJSON]
        var parsedTypes: [String] = []
        for line in lines {
            let event = try decode(line, as: BaseEvent.self)
            parsedTypes.append(event.type)
        }
        #expect(parsedTypes == ["system", "assistant", "result"])
    }

    @Test("Empty and whitespace lines are skipped")
    func emptyLines() throws {
        let lines = ["", "   ", "\n", systemJSON, ""]
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let _ = try? JSONDecoder().decode(BaseEvent.self, from: data) {
                count += 1
            }
        }
        #expect(count == 1)
    }

    @Test("Write tool_use input extraction")
    func writeToolInput() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Write","id":"toolu_123","input":{"file_path":"/tmp/new.swift","content":"print(\\"hello\\")"}}]}}
        """
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let msg = obj["message"] as! [String: Any]
        let content = msg["content"] as! [[String: Any]]
        let block = content[0]
        let input = block["input"] as! [String: String]

        #expect(block["name"] as? String == "Write")
        #expect(input["file_path"] == "/tmp/new.swift")
        #expect(input["content"] == "print(\"hello\")")
    }

    // MARK: - Agent Teams Event Tests

    @Test("Teammate started event parsing")
    func teammateStarted() throws {
        let json = """
        {"type":"system","subtype":"task_started","task_id":"task-1","task_type":"in_process_teammate","description":"pro-agent: Implement the REST API","prompt":"Implement the REST API","uuid":"uuid-1"}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teammateStarted(let taskId, let name, let prompt) = parsed else {
            Issue.record("Expected .teammateStarted, got \(String(describing: parsed))")
            return
        }
        #expect(taskId == "task-1")
        #expect(name == "pro-agent")
        #expect(prompt == "Implement the REST API")
    }

    @Test("Teammate completed event parsing")
    func teammateCompleted() throws {
        let json = """
        {"type":"system","subtype":"task_completed","task_id":"task-1","description":"pro-agent: done"}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teammateCompleted(let taskId, let name) = parsed else {
            Issue.record("Expected .teammateCompleted, got \(String(describing: parsed))")
            return
        }
        #expect(taskId == "task-1")
        #expect(name == "pro-agent")
    }

    @Test("TeamCreate tool_use parsed as teamCreated")
    func teamCreated() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"TeamCreate","id":"toolu_tc1","input":{"team_name":"api-team","description":"Build the API layer"}}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teamCreated(let name, let desc) = parsed else {
            Issue.record("Expected .teamCreated, got \(String(describing: parsed))")
            return
        }
        #expect(name == "api-team")
        #expect(desc == "Build the API layer")
    }

    @Test("TeamDelete tool_use parsed as teamDeleted")
    func teamDeleted() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"TeamDelete","id":"toolu_td1","input":{"team_name":"api-team"}}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teamDeleted(let name) = parsed else {
            Issue.record("Expected .teamDeleted, got \(String(describing: parsed))")
            return
        }
        #expect(name == "api-team")
    }

    @Test("SendMessage tool_use parsed as teamMessage")
    func teamMessage() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"SendMessage","id":"toolu_sm1","input":{"to":"pro-agent","message":"Please review the endpoints","type":"message"}}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teamMessage(let from, let to, let content) = parsed else {
            Issue.record("Expected .teamMessage, got \(String(describing: parsed))")
            return
        }
        #expect(from == "lead")
        #expect(to == "pro-agent")
        #expect(content == "Please review the endpoints")
    }

    @Test("SendMessage shutdown_request is filtered out")
    func shutdownFiltered() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"SendMessage","id":"toolu_sm2","input":{"to":"pro-agent","message":"shutdown","type":"shutdown_request"}}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        // shutdown_request falls through to generic toolUse
        guard case .toolUse(let name, _, _) = parsed else {
            Issue.record("Expected .toolUse fallthrough, got \(String(describing: parsed))")
            return
        }
        #expect(name == "SendMessage")
    }

    @Test("Non-teammate system event still returns systemInit")
    func systemInitNotTeam() throws {
        let json = """
        {"type":"system","subtype":"init","cwd":"/tmp","session_id":"s1","model":"claude-sonnet-4-6"}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .systemInit(let model, let sessionId) = parsed else {
            Issue.record("Expected .systemInit, got \(String(describing: parsed))")
            return
        }
        #expect(model == "claude-sonnet-4-6")
        #expect(sessionId == "s1")
    }

    @Test("Claude system status remains a transient control")
    func systemStatusIsControl() throws {
        let json = #"{"type":"system","subtype":"status","status":"requesting","uuid":"74b4705c-e0ac-45f0-9693-26d184a40c32","session_id":"f6c2c835-49a4-4141-9bfd-68f07f4ebcc7"}"#
        let parsed = StreamEventParser.parse(line: json)
        guard case .control(let type) = parsed else {
            Issue.record("Expected .control, got \(String(describing: parsed))")
            return
        }
        #expect(type == "system.status")
    }

    @Test("Claude post-turn summaries remain transient controls")
    func postTurnSummaryIsControl() throws {
        let json = #"{"type":"system","subtype":"post_turn_summary","summarizes_uuid":"u1","status_category":"completed"}"#
        let parsed = StreamEventParser.parse(line: json)
        guard case .control(let type) = parsed else {
            Issue.record("Expected .control, got \(String(describing: parsed))")
            return
        }
        #expect(type == "system.post_turn_summary")
    }

    @Test("Unknown Claude system subtypes remain observable")
    func unknownSystemSubtypeIsUnknown() throws {
        let json = #"{"type":"system","subtype":"future_lifecycle","session_id":"s1"}"#
        let parsed = StreamEventParser.parse(line: json)
        guard case .unknown(let type) = parsed else {
            Issue.record("Expected .unknown, got \(String(describing: parsed))")
            return
        }
        #expect(type == "system.future_lifecycle")
    }

    @Test("local_agent task_type also parsed as teammateStarted")
    func localAgentStarted() throws {
        let json = """
        {"type":"system","subtype":"task_started","task_id":"a64fbccb35b9bec59","task_type":"local_agent","description":"Write haiku about mountains","prompt":"Write a single haiku about mountains.","uuid":"uuid-2"}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teammateStarted(let taskId, let name, let prompt) = parsed else {
            Issue.record("Expected .teammateStarted for local_agent, got \(String(describing: parsed))")
            return
        }
        #expect(taskId == "a64fbccb35b9bec59")
        // local_agent descriptions have no "name:" prefix, so uses full description
        #expect(name == "Write haiku about mountains")
        #expect(prompt == "Write a single haiku about mountains.")
    }

    @Test("task_notification parsed as teammateCompleted")
    func taskNotification() throws {
        let json = """
        {"type":"system","subtype":"task_notification","task_id":"a64fbccb35b9bec59","status":"completed","summary":"Write haiku about mountains","uuid":"uuid-3"}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .teammateCompleted(let taskId, let name) = parsed else {
            Issue.record("Expected .teammateCompleted for task_notification, got \(String(describing: parsed))")
            return
        }
        #expect(taskId == "a64fbccb35b9bec59")
        #expect(name == "Write haiku about mountains")
    }

    @Test("Agent name extraction from description")
    func agentNameExtraction() throws {
        // Name with colon separator
        let json1 = """
        {"type":"system","subtype":"task_started","task_id":"t1","task_type":"in_process_teammate","description":"research-agent: Find all references","prompt":"Find all references"}
        """
        if case .teammateStarted(_, let name, _) = StreamEventParser.parse(line: json1) {
            #expect(name == "research-agent")
        } else {
            Issue.record("Failed to parse teammate started")
        }

        // No description falls back to task_id
        let json2 = """
        {"type":"system","subtype":"task_started","task_id":"fallback-id","task_type":"in_process_teammate","prompt":"Do something"}
        """
        if case .teammateStarted(_, let name, _) = StreamEventParser.parse(line: json2) {
            #expect(name == "fallback-id")
        } else {
            Issue.record("Failed to parse teammate with fallback name")
        }
    }

    // MARK: - Permission Denial Tests

    @Test("Permission denied event detected from user type")
    func permissionDenied() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","name":"Bash","text":"Permission denied: tool Bash is not allowed"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied(let tool, let reason) = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
        #expect(tool == "Bash")
        #expect(reason.contains("Permission denied"))
    }

    @Test("User denied keyword triggers permissionDenied")
    func userDeniedKeyword() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","name":"Write","text":"User denied the tool execution"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied(let tool, _) = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
        #expect(tool == "Write")
    }

    @Test("Normal user event is toolResult, not permissionDenied")
    func normalUserEvent() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","text":"File contents here..."}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .toolResult(_, let content, let isError) = parsed else {
            Issue.record("Expected .toolResult, got \(String(describing: parsed))")
            return
        }
        #expect(content == "File contents here...")
        #expect(!isError)
    }

    @Test("Permission denied with 'not allowed' keyword")
    func notAllowedKeyword() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","name":"Bash","text":"Tool Bash is not allowed in this context"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
    }

    @Test("Permission denied without tool name extracts unknown")
    func permissionDeniedNoToolName() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","text":"User rejected this action"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied(let tool, _) = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
        #expect(tool == "unknown")
    }

    @Test("Permission denied infers tool from denial text when name is missing")
    func permissionDeniedInfersToolFromText() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","text":"Permission denied: tool Bash is not allowed"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied(let tool, _) = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
        #expect(tool == "Bash")
    }

    @Test("Permission denied falls back to tool use id")
    func permissionDeniedFallsBackToToolUseID() throws {
        let json = """
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_123","text":"User rejected this action"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        guard case .permissionDenied(let tool, _) = parsed else {
            Issue.record("Expected .permissionDenied, got \(String(describing: parsed))")
            return
        }
        #expect(tool == "toolu_123")
    }

    @Test("Edit tool_use input extraction")
    func editToolInput() throws {
        let json = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Edit","id":"toolu_456","input":{"file_path":"/tmp/edit.swift","old_string":"let x = 1","new_string":"let x = 2"}}]}}
        """
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let msg = obj["message"] as! [String: Any]
        let content = msg["content"] as! [[String: Any]]
        let block = content[0]
        let input = block["input"] as! [String: String]

        #expect(block["name"] as? String == "Edit")
        #expect(input["file_path"] == "/tmp/edit.swift")
        #expect(input["old_string"] == "let x = 1")
        #expect(input["new_string"] == "let x = 2")
    }

    // MARK: - Phase 7D: Content block priority

    @Test("Text block preferred over thinking block in assistant message")
    func textPreferredOverThinking() {
        // Assistant message with thinking block BEFORE text block
        let json = """
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me think..."},{"type":"text","text":"Here is the answer"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        switch parsed {
        case .text(let text):
            #expect(text == "Here is the answer")
        default:
            Issue.record("Expected .text, got \(String(describing: parsed))")
        }
    }

    @Test("Thinking block returned when no text block present")
    func thinkingAloneStillWorks() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Deep thoughts"}]}}
        """
        let parsed = StreamEventParser.parse(line: json)
        switch parsed {
        case .thinking(let text):
            #expect(text == "Deep thoughts")
        default:
            Issue.record("Expected .thinking, got \(String(describing: parsed))")
        }
    }
}
