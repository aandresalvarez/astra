import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Claude native frame metadata")
struct RuntimeClaudeFrameMetadataTests {
    typealias Helper = RuntimeManagedSSHHelperMetadataTests
    typealias Fixture = RuntimeManagedSSHHelperEvidenceTests
    static let kinds = ["assistantText", "assistantThinking", "userText", "messageStart", "textStart", "thinkingStart",
        "textDelta", "thinkingDelta", "signatureDelta", "messageDelta", "contentStop", "messageStop"]
    static let routes = kinds.flatMap { kind in [false, true].map { Route(kind: kind, afterHelper: $0) } }

    static func frame(_ kind: String) throws -> [String: Any] {
        let captured = try Helper.captured("claude")
        if ["assistantText", "assistantThinking", "userText"].contains(kind) {
            let blockType = kind == "assistantThinking" ? "thinking" : "text"
            let type = kind == "userText" ? "user" : "assistant"
            var frame = try #require(captured.first {
                guard $0["type"] as? String == type else { return false }
                if type == "user" { return true }
                return (($0["message"] as? [String: Any])?["content"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == blockType
                } == true
            })
            var message = try #require(frame["message"] as? [String: Any])
            if kind == "userText" { message["content"] = [["type": "text", "text": "fixture user text"]] }
            else if kind == "assistantThinking" {
                var blocks = try #require(message["content"] as? [[String: Any]])
                blocks[0]["thinking"] = "fixture reasoning"; message["content"] = blocks
            }
            frame["message"] = message
            return frame
        }
        let eventType: String
        switch kind {
        case "messageStart": eventType = "message_start"
        case "textStart", "thinkingStart": eventType = "content_block_start"
        case "textDelta", "thinkingDelta", "signatureDelta": eventType = "content_block_delta"
        case "messageDelta": eventType = "message_delta"
        case "contentStop": eventType = "content_block_stop"
        default: eventType = "message_stop"
        }
        return try #require(captured.first {
            guard let event = $0["event"] as? [String: Any], event["type"] as? String == eventType else { return false }
            switch kind {
            case "textStart", "thinkingStart":
                return (event["content_block"] as? [String: Any])?["type"] as? String == (kind == "textStart" ? "text" : "thinking")
            case "textDelta", "thinkingDelta", "signatureDelta":
                let subtype = kind == "textDelta" ? "text_delta" : kind == "thinkingDelta" ? "thinking_delta" : "signature_delta"
                return (event["delta"] as? [String: Any])?["type"] as? String == subtype
            case "messageDelta": return (event["delta"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
            default: return true
            }
        })
    }

    static func evidence(_ frame: [String: Any], afterHelper: Bool) throws -> RuntimeExecutionProcessEvidence {
        let broker: RuntimeManagedSSHBrokerEvidence? = afterHelper ? RuntimeManagedSSHBrokerEvidence() : nil
        broker?.acknowledge(Fixture.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .claudeCode, managedSSHBroker: broker)
        if afterHelper {
            for frame in try Helper.frames(.claudeCode).dropLast() {
                try Fixture.observe(frame, runtime: .claudeCode, in: evidence)
            }
        }
        try Fixture.observe(frame, runtime: .claudeCode, in: evidence)
        try Fixture.observe(["type": "result", "is_error": false, "result": "Finished"], runtime: .claudeCode, in: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        return evidence
    }

    @Test("Captured ordinary Claude text and stream metadata preserves completion",
          arguments: kinds, [false, true])
    func nativeMetadata(kind: String, afterHelper: Bool) throws {
        let evidence = try Self.evidence(Self.frame(kind), afterHelper: afterHelper)
        #expect(evidence.providerTurnEnded)
        #expect(afterHelper ? evidence.managedSSHOnly : evidence.toolsStopped)
    }

    @Test("Claude JSON-looking strings remain opaque text",
          arguments: ["assistantText", "textDelta"], [false, true])
    func opaqueText(kind: String, afterHelper: Bool) throws {
        var frame = try Self.frame(kind)
        let text = #"{"unknown_native_work":true,"toolRequests":[{"name":"ssh"}]}"#
        if kind == "assistantText" {
            var message = try #require(frame["message"] as? [String: Any])
            message["content"] = [["type": "text", "text": text]]; frame["message"] = message
        } else {
            var event = try #require(frame["event"] as? [String: Any])
            event["delta"] = ["type": "text_delta", "text": text]; frame["event"] = event
        }
        let evidence = try Self.evidence(frame, afterHelper: afterHelper)
        #expect(afterHelper ? evidence.managedSSHOnly : evidence.toolsStopped)
    }

    @Test("Claude ordinary text and stream frames retain unsupported metadata uncertainty",
          arguments: routes,
          ["unknownEnvelope", "unknownPayload", "agentAttribution", "malformedMetadata", "knownCounter"])
    func rejectsUnsupportedMetadata(route: Route, fault: String) throws {
        var frame = try Self.frame(route.kind)
        switch fault {
        case "unknownEnvelope": frame["unknown_native_work"] = ["arguments": ["command": "ssh unrelated"]]
        case "agentAttribution": frame["agent_id"] = "unaccounted-agent"
        case "malformedMetadata": frame["timestamp"] = ["unknown_native_work": true]
        case "knownCounter": frame["queued_turn_count"] = 1
        default:
            if var message = frame["message"] as? [String: Any] {
                message["unknown_native_work"] = true; frame["message"] = message
            } else {
                var event = try #require(frame["event"] as? [String: Any])
                if var delta = event["delta"] as? [String: Any] { delta["unknown_native_work"] = true; event["delta"] = delta }
                else if var message = event["message"] as? [String: Any] { message["unknown_native_work"] = true; event["message"] = message }
                else { event["unknown_native_work"] = true }
                frame["event"] = event
            }
        }
        let evidence = try Self.evidence(frame, afterHelper: route.afterHelper)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    struct Route: Sendable, CustomStringConvertible {
        var kind: String
        var afterHelper: Bool
        var description: String { "\(kind):\(afterHelper ? "afterHelper" : "withoutHelper")" }
    }
}
