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
        "session.mcp_servers_loaded", "session.tools_updated", "session.auto_mode_resolved"]

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
        let captured = try ["recovery-captured-20261024.jsonl", "answer-write-signoff.jsonl"].flatMap { name in
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
}
