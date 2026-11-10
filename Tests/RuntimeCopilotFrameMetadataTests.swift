import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot native frame metadata")
struct RuntimeCopilotFrameMetadataTests {
    static let types = ["assistant.message", "assistant.message_delta", "assistant.reasoning", "assistant.reasoning_delta",
        "user.message", "assistant.turn_start", "assistant.message_start", "assistant.turn_end", "assistant.idle",
        "model.call_start", "model.call_finished", "model.call_failure", "model.call_final_result", "session.error",
        "session.shutdown", "session.mcp_server_status_changed", "session.mcp_server_tools_loaded",
        "session.mcp_servers_loaded", "session.tools_updated", "session.auto_mode_resolved",
        "session.info", "session.usage_checkpoint"]

    static func frame(_ type: String) throws -> [String: Any] {
        if type == "assistant.reasoning_delta" {
            return try RuntimeManagedSSHHelperEvidenceTests.capturedCopilotTextFrame(type: type)
        }
        if type == "session.shutdown" {
            // Primary SDK ShutdownData/ShutdownModelMetric shapes; this event
            // has no captured fixture. These are accounting, not tool counters.
            return ["type": type, "data": ["shutdownType": "routine", "sessionStartTime": 1000, "totalApiDurationMs": 5,
                "codeChanges": ["linesAdded": 0, "linesRemoved": 0, "filesModified": []],
                "modelMetrics": ["fixture": ["requests": ["count": 1],
                    "usage": ["inputTokens": 12, "outputTokens": 3, "cacheReadTokens": 0, "cacheWriteTokens": 0]]]]]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ProviderStreams/copilot")
        // The redactor empties older session frames; the two types that first
        // reached stdout with CLI 1.0.105 come from that capture.
        let names = ["session.info", "session.usage_checkpoint"].contains(type)
            ? ["tool-free-1.0.105-auto.jsonl"] : ["recovery-captured-20261024.jsonl", "answer-write-signoff.jsonl"]
        let captured = try names.flatMap { name in
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
        let selected = captured.first { frame in
            guard frame["type"] as? String == type, let data = frame["data"] as? [String: Any] else { return false }
            if type == "assistant.message" {
                return (data["toolRequests"] as? [Any])?.isEmpty != false && (data["content"] as? String)?.isEmpty == false
            }
            return type != "model.call_failure" || data["errorMessage"] is String
        }
        return try #require(selected)
    }

    @Test("Every supported native activity or bookkeeping envelope preserves its parser cleanup contract",
          arguments: types, [false, true])
    func nativeFrames(type: String, withHelper: Bool) throws {
        let evidence = try RuntimeManagedSSHHelperEvidenceTests.textEvidence(Self.frame(type), withHelper: withHelper)
        #expect(evidence.providerTurnEnded)
        #expect(evidence.managedSSHOnly == withHelper)
        #expect(evidence.toolsStopped == !withHelper)
    }

    @Test("Unknown and malformed native metadata stays uncertain for every supported event type",
          arguments: types, ["afterHelper", "withoutHelper"].flatMap { route in
              ["envelopeUnknown", "dataUnknown", "malformed", "agentId"].map { "\(route):\($0)" }
          })
    func unsupportedMetadata(type: String, variation: String) throws {
        let parts = variation.split(separator: ":")
        var frame = try Self.frame(type)
        var data = try #require(frame["data"] as? [String: Any])
        switch parts[1] {
        case "envelopeUnknown": frame["unknown_native_work"] = ["toolName": "unrelated"]
        case "dataUnknown": data["arguments"] = ["command": "ssh elsewhere 'sleep 10 &'"]
        case "agentId": frame["agentId"] = "unrelated-subagent"
        default:
            // Corrupt a field that the native frame actually supplies. This
            // preserves the parser route where possible; idle has no data.
            if let key = data.keys.sorted().first { data[key] = NSNull() }
            else { data["aborted"] = 0 }
        }
        frame["data"] = data
        let evidence = try RuntimeManagedSSHHelperEvidenceTests.textEvidence(frame, withHelper: parts[0] == "afterHelper")
        #expect(evidence.providerTurnEnded)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Captured server inventory and native accounting have bounded nested metadata", arguments: [false, true],
          ["servers", "serverUnknown", "serverNumber", "metrics", "metricUnknown", "usageUnknown", "requestsUnknown",
           "codeUnknown", "codeLines", "codeFiles", "codeBoolean", "codeMissing", "codeEmpty", "tokenUnknown"])
    func nestedMetadata(withHelper: Bool, shape: String) throws {
        var frame = try shape.hasPrefix("server")
            ? RuntimeManagedSSHHelperEvidenceTests.capturedCopilotTextFrame(type: "session.mcp_servers_loaded")
            : Self.frame("session.shutdown")
        var data = try #require(frame["data"] as? [String: Any])
        switch shape {
        case "serverUnknown": data["servers"] = [["name": "fixture", "status": "connected", "unknown_native_work": true]]
        case "serverNumber": data["servers"] = 0
        case "metricUnknown": data["modelMetrics"] = ["fixture": ["unknown_native_work": true]]
        case "usageUnknown": data["modelMetrics"] = ["fixture": ["usage": ["inputTokens": 1, "unknown_native_work": true]]]
        case "requestsUnknown": data["modelMetrics"] = ["fixture": ["requests": ["count": 1, "toolName": "unrelated"]]]
        case "codeUnknown": data["codeChanges"] = ["linesAdded": 0, "unknown_native_work": true]
        case "codeLines": data["codeChanges"] = ["linesAdded": 1, "linesRemoved": 0, "filesModified": []]
        case "codeFiles": data["codeChanges"] = ["linesAdded": 0, "linesRemoved": 0, "filesModified": ["fixture"]]
        case "codeBoolean": data["codeChanges"] = ["linesAdded": false, "linesRemoved": 0, "filesModified": []]
        case "codeMissing": data["codeChanges"] = ["linesAdded": 0]
        case "codeEmpty": data["codeChanges"] = [String: Any]()
        case "tokenUnknown": data["tokenDetails"] = ["input": ["tokenCount": 1, "unknown_native_work": true]]
        default: break
        }
        frame["data"] = data
        let evidence = try RuntimeManagedSSHHelperEvidenceTests.textEvidence(frame, withHelper: withHelper)
        #expect(evidence.providerTurnEnded)
        if ["servers", "metrics"].contains(shape) {
            #expect(evidence.managedSSHOnly == withHelper)
            #expect(evidence.toolsStopped == !withHelper)
        } else {
            #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
        }
    }

    @Test("Built-in edit hints are sticky even outside the model bookkeeping envelope",
          arguments: [false, true], ["false", "true", "zero", "string", "null"])
    func globalEditHint(withHelper: Bool, value: String) throws {
        let frames = try RuntimeManagedSSHHelperEvidenceTests.frames(runtime: .copilotCLI)
        var frame = try #require(frames.last)
        switch value {
        case "false": frame["containsBuiltInFileEditRequest"] = false
        case "true": frame["containsBuiltInFileEditRequest"] = true
        case "zero": frame["containsBuiltInFileEditRequest"] = 0
        case "string": frame["containsBuiltInFileEditRequest"] = "false"
        default: frame["containsBuiltInFileEditRequest"] = NSNull()
        }
        let evidence = try RuntimeManagedSSHHelperEvidenceTests.textEvidence(frame, withHelper: withHelper)
        #expect(evidence.providerTurnEnded)
        if value == "false" {
            #expect(evidence.managedSSHOnly == withHelper)
            #expect(evidence.toolsStopped == !withHelper)
        } else {
            #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
        }
    }

    // MARK: Copilot CLI 1.0.105 stdout captures (shape-only; see the PR that added them)

    static let toolFreeStreams = ["tool-free-1.0.105-auto.jsonl", "tool-free-1.0.105-allow-all.jsonl"]

    static func stream(_ name: String) throws -> [[String: Any]] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/copilot/\(name)")
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    static func evidence(_ frames: [[String: Any]]) throws -> RuntimeExecutionProcessEvidence {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        for frame in frames { try RuntimeManagedSSHHelperEvidenceTests.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        return evidence
    }

    /// Replaces the value at `path`; `0` enters an array's first element and
    /// `*` a dictionary's only value (model-keyed maps). `nil` removes the key.
    static func replacing(_ value: Any, at path: ArraySlice<String>, with replacement: Any?) throws -> Any {
        guard let key = path.first else { return replacement as Any }
        if var items = value as? [Any], key == "0" {
            items[0] = try replacing(try #require(items.first), at: path.dropFirst(), with: replacement)
            return items
        }
        var object = try #require(value as? [String: Any])
        let name = try key == "*" ? #require(object.keys.first) : key
        if path.count == 1, replacement == nil { object[name] = nil; return object }
        object[name] = try replacing(object[name] ?? [String: Any](), at: path.dropFirst(), with: replacement)
        return object
    }

    @Test("A tool-free Copilot 1.0.105 stream proves that its tools stopped", arguments: toolFreeStreams)
    func toolFreeStreamIsClean(name: String) throws {
        let frames = try Self.stream(name)
        for frame in frames {
            #expect(RuntimeProviderFrameEvidence.classify(frame, runtime: .copilotCLI) != .uncertain,
                    "\(frame["type"] ?? "untyped") is uncertain")
            #expect(!RuntimeStreamExecutionHints.containsWork(frame))
        }
        let evidence = try Self.evidence(frames)
        #expect(evidence.providerTurnEnded && evidence.toolsStopped)
    }

    @Test("One tool request or one unknown frame keeps a 1.0.105 stream uncertain",
          arguments: toolFreeStreams, ["toolRequest", "unknownFrame", "unknownSessionFrame", "permissionFrame"])
    func executionKeepsStreamUncertain(name: String, fault: String) throws {
        var frames = try Self.stream(name)
        switch fault {
        case "toolRequest":
            let index = try #require(frames.firstIndex { $0["type"] as? String == "assistant.message" })
            frames[index] = try #require(Self.replacing(frames[index], at: ["data", "toolRequests"],
                with: [["toolCallId": "fixture", "name": "bash", "arguments": ["command": "sleep 10 &"]]]) as? [String: Any])
        case "unknownFrame": frames.insert(["type": "fixture.unknown_native_work", "data": [String: Any]()], at: frames.count - 1)
        case "unknownSessionFrame": frames.insert(["type": "session.usage_record", "data": [String: Any]()], at: frames.count - 1)
        default: frames.insert(["type": "session.permissions_changed", "data": ["allowAllTools": true]], at: frames.count - 1)
        }
        let evidence = try Self.evidence(frames)
        #expect(evidence.providerTurnEnded && !evidence.toolsStopped)
    }

    @Test("A captured 1.0.105 run of one read-only tool stays uncertain, as does its usage checkpoint alone")
    func capturedToolRunStaysUncertain() throws {
        let toolRun = try Self.stream("view-tool-1.0.105.jsonl")
        #expect(toolRun.contains { $0["type"] as? String == "tool.execution_start" })
        let whole = try Self.evidence(toolRun)
        #expect(whole.providerTurnEnded && !whole.toolsStopped)

        // The checkpoint's last model call followed a tool result (`initiator`
        // is `agent`), which contradicts a stream that shows no tool frames.
        let checkpoint = try #require(toolRun.first { $0["type"] as? String == "session.usage_checkpoint" })
        #expect(RuntimeProviderFrameEvidence.classify(checkpoint, runtime: .copilotCLI) == .uncertain)
        var frames = try Self.stream(Self.toolFreeStreams[0])
        let index = try #require(frames.firstIndex { $0["type"] as? String == "session.usage_checkpoint" })
        frames[index] = checkpoint
        let spliced = try Self.evidence(frames)
        #expect(spliced.providerTurnEnded && !spliced.toolsStopped)
    }

    static let snapshot = ["data", "accountingSnapshot"]
    static let cacheModel = ["data", "promptCacheBreakState", "0", "models", "*"]
    /// (frame type, path, replacement). Each contradicts a tool-free turn or
    /// leaves the captured shape, so the frame must stop counting as bookkeeping.
    static var faults: [(String, [String], Any?)] { [
        ("session.usage_checkpoint", snapshot + ["codeChanges", "linesAdded"], 2),
        ("session.usage_checkpoint", snapshot + ["codeChanges", "filesModifiedCount"], 1),
        ("session.usage_checkpoint", snapshot + ["codeChanges", "filesModified"], ["fixture"]),
        ("session.usage_checkpoint", snapshot + ["codeChanges", "unknown_native_work"], 0),
        ("session.usage_checkpoint", snapshot + ["codeChanges"], nil),
        ("session.usage_checkpoint", snapshot + ["agentMetrics", "subagent"], ["totalNanoAiu": 0]),
        ("session.usage_checkpoint", snapshot + ["agentMetrics", "main", "toolCalls"], 0),
        ("session.usage_checkpoint", snapshot + ["agentMetrics"], nil),
        ("session.usage_checkpoint", snapshot + ["toolCalls"], 0),
        ("session.usage_checkpoint", snapshot + ["modelMetrics", "*", "toolCalls"], 0),
        ("session.usage_checkpoint", snapshot + ["providerModelMetrics", "0", "provider", "command"], "fixture"),
        ("session.usage_checkpoint", snapshot, nil),
        ("session.usage_checkpoint", cacheModel + ["initiator"], "agent"),
        ("session.usage_checkpoint", cacheModel + ["initiator"], nil),
        ("session.usage_checkpoint", cacheModel + ["pending_tool_calls"], 0),
        ("session.usage_checkpoint", cacheModel + ["tools", "0", "arguments"], ["command": "sleep 10 &"]),
        ("session.usage_checkpoint", cacheModel + ["cache_config", "advisor_tool"], "false"),
        ("session.usage_checkpoint", cacheModel + ["conversation", "pendingToolResults"], 1),
        ("session.usage_checkpoint", ["data", "promptCacheBreakState", "0", "pendingRewriteSources"], ["fixture"]),
        ("session.usage_checkpoint", ["data", "modelCacheState", "0", "unknown_native_work"], true),
        ("session.usage_checkpoint", ["data", "usageAccountingWatermarks", "fixture"], "1"),
        ("session.usage_checkpoint", ["data", "backgroundTasks"], [String]()),
        ("session.info", ["data", "infoType"], "background_task"),
        ("session.info", ["data", "command"], "sleep 10 &"),
        ("session.auto_mode_resolved", ["data", "categoryScores", "toolCalls"], 1),
        ("session.auto_mode_resolved", ["data", "fallback"], 0),
        ("user.message", ["data", "responsesReasoning", "toolChoice"], "required"),
        ("user.message", ["data", "responsesReasoning"], "max"),
        ("session.mcp_servers_loaded", ["data", "servers", "0", "serverMetadata", "tools"], [String]()),
        ("session.mcp_servers_loaded", ["data", "servers", "0", "displayName"], 1),
        ("session.mcp_server_status_changed", ["data", "configSource"], ["command": "fixture"]),
        ("model.call_final_result", ["data", "isByok"], "false")
    ] }

    @Test("Accounting or metadata that leaves the captured 1.0.105 shape stays uncertain", arguments: faults.indices)
    func capturedShapeFaults(index: Int) throws {
        let (type, path, replacement) = Self.faults[index]
        var frames = try Self.stream(Self.toolFreeStreams[0])
        // Prefer the frame that carries the field, e.g. the second status change.
        let position = try #require(frames.lastIndex { $0["type"] as? String == type })
        let original = frames[position]
        #expect(RuntimeProviderFrameEvidence.classify(original, runtime: .copilotCLI) != .uncertain)
        let mutated = try #require(Self.replacing(original, at: path[...], with: replacement) as? [String: Any])
        #expect(RuntimeProviderFrameEvidence.classify(mutated, runtime: .copilotCLI) == .uncertain, "\(type) \(path)")
        frames[position] = mutated
        let evidence = try Self.evidence(frames)
        #expect(evidence.providerTurnEnded && !evidence.toolsStopped, "\(type) \(path)")
    }
}
