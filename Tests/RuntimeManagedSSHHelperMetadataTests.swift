import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Managed SSH helper metadata contract")
struct RuntimeManagedSSHHelperMetadataTests {
    typealias Fixture = RuntimeManagedSSHHelperEvidenceTests

    static func captured(_ provider: String, fixture: String = "answer-write-signoff") throws -> [[String: Any]] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/\(provider)/\(fixture).jsonl")
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            let object = try JSONSerialization.jsonObject(with: Data($0.utf8))
            return try #require(object as? [String: Any])
        }
    }

    /// Preserve captured provider metadata, replacing only synthetic command,
    /// tool identity, stream index and output. No helper or shell is launched.
    static func frames(_ runtime: AgentRuntimeID) throws -> [[String: Any]] {
        var frames = try Fixture.capturedFrames(runtime: runtime)
        let native = try captured(runtime == .copilotCLI ? "copilot" : "claude")
        if runtime == .copilotCLI {
            for (index, type) in [(2, "tool.execution_start"), (3, "tool.execution_complete")] {
                var frame = try #require(native.first { $0["type"] as? String == type })
                var data = try #require(frame["data"] as? [String: Any])
                data["toolCallId"] = "helper-1"
                if index == 2 {
                    data["toolName"] = "bash"; data["arguments"] = ["command": Fixture.command]
                } else {
                    data["result"] = ["content": "remote_job_id: fixture"]
                }
                frame["data"] = data; frames[index] = frame
            }
            frames.insert(Fixture.copilotProgressFrame("tool.execution_progress"), at: 3)
        } else {
            let input = ["command": Fixture.command]
            let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            for (index, type) in [(1, "content_block_delta"), (3, "content_block_stop"), (4, "message_delta")] {
                var frame = try #require(native.first {
                    guard let event = $0["event"] as? [String: Any], event["type"] as? String == type else { return false }
                    return type != "content_block_delta"
                        || (event["delta"] as? [String: Any])?["type"] as? String == "input_json_delta"
                })
                var event = try #require(frame["event"] as? [String: Any])
                if index != 4 { event["index"] = 0 }
                if index == 1 { event["delta"] = ["type": "input_json_delta", "partial_json": inputJSON] }
                frame["event"] = event; frames[index] = frame
            }
            var user = try #require(native.first { $0["type"] as? String == "user" })
            var message = try #require(user["message"] as? [String: Any])
            message["content"] = [["type": "tool_result", "tool_use_id": "helper-1", "content": "remote_job_id: fixture"]]
            user["message"] = message; frames[5] = user
        }
        return frames
    }

    static func evidence(_ runtime: AgentRuntimeID, frames: [[String: Any]]) throws -> RuntimeExecutionProcessEvidence {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Fixture.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime, managedSSHBroker: broker)
        for frame in frames { try Fixture.observe(frame, runtime: runtime, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        return evidence
    }

    @Test("Captured Copilot helper metadata and finished output preserve accounting",
          arguments: ["captured", "descriptive", "opaqueText", "textContents", "terminalExit", "shellExit", "error", "durableFlag", "parentNull"])
    func copilotNativeControls(shape: String) throws {
        var frames = try Self.frames(.copilotCLI)
        var data = try #require(frames[4]["data"] as? [String: Any])
        switch shape {
        case "descriptive":
            var start = try #require(frames[2]["data"] as? [String: Any])
            start["rte"] = false; start["interactionId"] = "fixture-interaction"
            start["arguments"] = ["command": Fixture.command, "description": "Managed job", "timeout": 1000, "timeout_ms": 1000] as [String: Any]
            frames[2]["data"] = start
        case "opaqueText":
            data["result"] = ["content": #"{"toolRequests":[{"name":"ssh"}]}"#,
                              "detailedContent": #"{"unknown_native_work":true}"#]
        case "textContents": data["result"] = ["content": "job", "contents": [["type": "text", "text": #"{"queued_turn_count":1}"#]]] as [String: Any]
        case "terminalExit": data["result"] = ["content": "job", "contents": [["type": "terminal", "text": "job", "cwd": "/fixture", "exitCode": 0]]] as [String: Any]
        case "shellExit": data["result"] = ["content": "job", "contents": [["type": "shell_exit", "shellId": "fixture-shell", "exitCode": 0, "outputPreview": "job", "outputTruncated": false]]] as [String: Any]
        case "error":
            data["success"] = false; data.removeValue(forKey: "result")
            data["error"] = ["message": #"{"toolRequests":[]}"#, "code": "fixture"]
        case "durableFlag": frames[2]["ephemeral"] = false; frames[4]["ephemeral"] = false
        case "parentNull": frames[2]["parentId"] = NSNull(); frames[4]["parentId"] = NSNull()
        default: break
        }
        frames[4]["data"] = data
        let evidence = try Self.evidence(.copilotCLI, frames: frames)
        #expect(evidence.providerTurnEnded && evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Captured Claude helper metadata and textual results preserve accounting",
          arguments: ["captured", "descriptive", "opaqueText", "textResult", "error", "shellResult"])
    func claudeNativeControls(shape: String) throws {
        var frames = try Self.frames(.claudeCode)
        var message = try #require(frames[5]["message"] as? [String: Any])
        var blocks = try #require(message["content"] as? [[String: Any]])
        switch shape {
        case "descriptive":
            var assistant = try #require(frames[2]["message"] as? [String: Any])
            var uses = try #require(assistant["content"] as? [[String: Any]])
            let input = ["command": Fixture.command, "description": "Managed job", "timeout": 1000, "timeout_ms": 1000] as [String: Any]
            uses[0]["input"] = input; assistant["content"] = uses; frames[2]["message"] = assistant
            frames[2]["wire_tool_inputs"] = ["helper-1": input]
        case "opaqueText": blocks[0]["content"] = #"{"unknown_native_work":true,"toolRequests":[{"name":"ssh"}]}"#
        case "textResult": blocks[0]["content"] = [["type": "text", "text": #"{"queued_turn_count":1}"#]]
        case "error": blocks[0]["is_error"] = true
        case "shellResult":
            let native = try Self.captured("claude", fixture: "foreground-tool-completion")
            let user = try #require(native.first { $0["tool_use_result"] != nil })
            frames[5]["tool_use_result"] = user["tool_use_result"]
        default: break
        }
        message["content"] = blocks; frames[5]["message"] = message
        let evidence = try Self.evidence(.claudeCode, frames: frames)
        #expect(evidence.providerTurnEnded && evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    static let stages = ["copilot.delta", "copilot.message", "copilot.start", "copilot.progress", "copilot.complete",
        "claude.start", "claude.delta", "claude.assistant", "claude.stop", "claude.messageDelta", "claude.user"]

    @Test("Every helper family rejects unknown or malformed outer metadata",
          arguments: stages, ["unknown", "identity", "timestamp", "knownCounter"])
    func envelopeMetadata(stage: String, fault: String) throws {
        let runtime: AgentRuntimeID = stage.hasPrefix("copilot") ? .copilotCLI : .claudeCode
        let names = runtime == .copilotCLI ? Array(Self.stages.prefix(5)) : Array(Self.stages.suffix(6))
        let index = try #require(names.firstIndex(of: stage))
        var frames = try Self.frames(runtime)
        switch fault {
        case "unknown": frames[index]["unknown_native_work"] = ["arguments": ["command": "ssh unrelated"]]
        case "identity": frames[index][runtime == .copilotCLI ? "id" : "session_id"] = ["toolRequests": [["name": "ssh"]]]
        case "timestamp": frames[index]["timestamp"] = ["unknown_native_work": true]
        default: frames[index]["queued_turn_count"] = 1
        }
        let evidence = try Self.evidence(runtime, frames: frames)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Copilot start and completion descriptive fields are typed",
          arguments: [2, 4], ["turnId", "model", "interactionId", "rte", "parentId"])
    func copilotTypedMetadata(index: Int, field: String) throws {
        var frames = try Self.frames(.copilotCLI)
        let unaccounted: [String: Any] = ["toolRequests": [["name": "ssh"]]]
        if field == "parentId" { frames[index][field] = unaccounted }
        else {
            var data = try #require(frames[index]["data"] as? [String: Any])
            data[field] = unaccounted; frames[index]["data"] = data
        }
        let evidence = try Self.evidence(.copilotCLI, frames: frames)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Copilot structured completion requires validated metadata and actual terminal exit",
          arguments: ["missingSuccess", "numberSuccess", "objectSuccess", "stringResult", "unknownResult", "objectContent",
            "stringError", "unknownError", "objectErrorMessage", "unfinishedTerminal", "invalidTerminalExit", "missingShellExit",
            "missingShellID", "invalidTruncated", "unknownContents"])
    func copilotCompletionMetadata(fault: String) throws {
        var frames = try Self.frames(.copilotCLI)
        var data = try #require(frames[4]["data"] as? [String: Any])
        switch fault {
        case "missingSuccess": data.removeValue(forKey: "success")
        case "numberSuccess": data["success"] = 1
        case "objectSuccess": data["success"] = ["toolRequests": [["name": "ssh"]]]
        case "stringResult": data["result"] = "job"
        case "unknownResult": data["result"] = ["content": "job", "unknown_native_work": true] as [String: Any]
        case "objectContent": data["result"] = ["content": ["toolRequests": [["name": "ssh"]]]]
        case "stringError": data["error"] = "failure"
        case "unknownError": data["error"] = ["message": "failure", "unknown_native_work": true] as [String: Any]
        case "objectErrorMessage": data["error"] = ["message": ["toolRequests": [["name": "ssh"]]]]
        case "unfinishedTerminal": data["result"] = ["content": "still running", "contents": [["type": "terminal", "text": "still running"]]] as [String: Any]
        case "invalidTerminalExit": data["result"] = ["content": "job", "contents": [["type": "terminal", "text": "job", "exitCode": false]]] as [String: Any]
        case "missingShellExit": data["result"] = ["content": "job", "contents": [["type": "shell_exit", "shellId": "fixture-shell"]]] as [String: Any]
        case "missingShellID": data["result"] = ["content": "job", "contents": [["type": "shell_exit", "exitCode": 0]]] as [String: Any]
        case "invalidTruncated": data["result"] = ["content": "job", "contents": [["type": "shell_exit", "shellId": "fixture-shell", "exitCode": 0, "outputTruncated": ["unknown_native_work": true]]]] as [String: Any]
        default: data["result"] = ["content": "job", "contents": [["type": "unknown_native_work", "arguments": ["command": "ssh unrelated"]]]] as [String: Any]
        }
        frames[4]["data"] = data
        let evidence = try Self.evidence(.copilotCLI, frames: frames)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Helper shell description and timeout metadata cannot contain work",
          arguments: [AgentRuntimeID.claudeCode, .copilotCLI], ["description", "timeoutString", "timeoutBoolean", "timeoutObject", "timeoutMSObject"])
    func inputMetadata(runtime: AgentRuntimeID, fault: String) throws {
        var frames = try Self.frames(runtime)
        var input: [String: Any] = ["command": Fixture.command]
        switch fault {
        case "description": input["description"] = ["toolRequests": [["name": "ssh"]]]
        case "timeoutString": input["timeout"] = "unknown"
        case "timeoutBoolean": input["timeout"] = false
        case "timeoutObject": input["timeout"] = ["unknown_native_work": true]
        default: input["timeout_ms"] = ["unknown_native_work": true]
        }
        if runtime == .copilotCLI {
            var data = try #require(frames[2]["data"] as? [String: Any])
            data["arguments"] = input; frames[2]["data"] = data
        } else {
            var message = try #require(frames[2]["message"] as? [String: Any])
            var blocks = try #require(message["content"] as? [[String: Any]])
            blocks[0]["input"] = input; message["content"] = blocks; frames[2]["message"] = message
            frames[2]["wire_tool_inputs"] = ["helper-1": input]
        }
        let evidence = try Self.evidence(runtime, frames: frames)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Claude helper message, stream and wire-input metadata is bounded",
          arguments: ["messageUnknown", "messageType", "messageIdentity", "usageUnknown", "wireExtra", "wireMismatch", "wireMalformed",
            "startEventUnknown", "deltaEventUnknown", "stopEventUnknown", "stopDeltaUnknown", "messageDeltaUnknown",
            "userMessageUnknown", "resultObject", "resultUnknownBlock", "errorObject", "signatureObject", "citationsObject",
            "startIndexBoolean", "deltaIndexBoolean", "stopIndexBoolean"])
    func claudeNestedMetadata(fault: String) throws {
        var frames = try Self.frames(.claudeCode)
        if fault.hasPrefix("wire") {
            switch fault {
            case "wireExtra": frames[2]["wire_tool_inputs"] = ["helper-1": ["command": Fixture.command], "unrelated": ["command": "ssh unrelated"]]
            case "wireMismatch": frames[2]["wire_tool_inputs"] = ["helper-1": ["command": "ssh unrelated"]]
            default: frames[2]["wire_tool_inputs"] = "unverified"
            }
        } else if ["messageUnknown", "messageType", "messageIdentity", "usageUnknown", "signatureObject", "citationsObject"].contains(fault) {
            var message = try #require(frames[2]["message"] as? [String: Any])
            switch fault {
            case "messageUnknown": message["unknown_native_work"] = true
            case "messageType": message["type"] = "unknown_native_work"
            case "messageIdentity": message["id"] = ["toolRequests": [["name": "ssh"]]]
            case "usageUnknown":
                var usage = try #require(message["usage"] as? [String: Any])
                usage["unknown_native_work"] = ["arguments": ["command": "ssh unrelated"]]; message["usage"] = usage
            default:
                var blocks = try #require(message["content"] as? [[String: Any]])
                blocks.append(fault == "signatureObject"
                    ? ["type": "thinking", "thinking": "job", "signature": ["unknown_native_work": true]]
                    : ["type": "text", "text": "job", "citations": ["unknown_native_work": true]])
                message["content"] = blocks
            }
            frames[2]["message"] = message
        } else if ["userMessageUnknown", "resultObject", "resultUnknownBlock", "errorObject"].contains(fault) {
            var message = try #require(frames[5]["message"] as? [String: Any])
            var blocks = try #require(message["content"] as? [[String: Any]])
            switch fault {
            case "userMessageUnknown": message["unknown_native_work"] = true
            case "resultObject": blocks[0]["content"] = ["toolRequests": [["name": "ssh"]]]
            case "resultUnknownBlock": blocks[0]["content"] = [["type": "unknown_native_work", "arguments": ["command": "ssh unrelated"]]]
            default: blocks[0]["is_error"] = ["unknown_native_work": true]
            }
            message["content"] = blocks; frames[5]["message"] = message
        } else {
            let index: Int
            if fault.hasPrefix("start") { index = 0 }
            else if fault.hasPrefix("delta") { index = 1 }
            else if fault.hasPrefix("stopEvent") || fault.hasPrefix("stopIndex") { index = 3 }
            else { index = 4 }
            var event = try #require(frames[index]["event"] as? [String: Any])
            if fault.hasSuffix("Boolean") { event["index"] = false }
            else if fault == "stopDeltaUnknown" {
                var delta = try #require(event["delta"] as? [String: Any])
                delta["unknown_native_work"] = true; event["delta"] = delta
            } else { event["unknown_native_work"] = true }
            frames[index]["event"] = event
        }
        let evidence = try Self.evidence(.claudeCode, frames: frames)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }
}
