import Foundation
import Testing
import ASTRACore
import WorkspaceToolSupport
@testable import ASTRA

@Suite("Managed SSH helper completion evidence")
struct RuntimeManagedSSHHelperEvidenceTests {
    static let command = "astra-workspace-job start --connection fixture -- 'sleep 10'"
    static let admitted: RemoteWorkspaceJobCLI.Command = .start(connection: "fixture", label: nil, timeoutSeconds: nil, command: "sleep 10")

    static func observe(_ frame: [String: Any], runtime: AgentRuntimeID, in evidence: RuntimeExecutionProcessEvidence) throws {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
        evidence.observeFrame(line, parsesJSONLines: true,
            events: AgentRuntimeAdapterRegistry.adapter(for: runtime).parseProcessEvents(line: line, parsesJSONLines: true))
    }

    static func frames(runtime: AgentRuntimeID, command: String = RuntimeManagedSSHHelperEvidenceTests.command, resultID: String = "helper-1") throws -> [[String: Any]] {
        let input = ["command": command]
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        if runtime == .copilotCLI {
            return [
                ["type": "assistant.tool_call_delta", "data": ["toolCallId": "helper-1", "toolName": "bash", "inputDelta": inputJSON]],
                ["type": "assistant.message", "data": ["content": "Start a managed job", "toolRequests": [["toolCallId": "helper-1", "name": "bash", "arguments": input]]]],
                ["type": "tool.execution_start", "data": ["toolCallId": "helper-1", "toolName": "bash", "arguments": input]],
                ["type": "tool.execution_complete", "data": ["toolCallId": resultID, "success": true, "result": ["content": "remote_job_id: fixture"]]],
                ["type": "result", "sessionId": "fixture", "exitCode": 0, "result": "Finished"]
            ]
        }
        return [
            ["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "helper-1", "name": "Bash", "input": [:]]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": inputJSON]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "helper-1", "name": "Bash", "input": input]]]],
            ["type": "stream_event", "event": ["type": "content_block_stop", "index": 0]],
            ["type": "stream_event", "event": ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": resultID, "content": "remote_job_id: fixture"]]]],
            ["type": "result", "is_error": false, "result": "Finished"]
        ]
    }

    /// Reuse captured native envelopes, replacing the tool identity, kind and
    /// input with the synthetic helper. No provider or remote command runs.
    static func capturedFrames(runtime: AgentRuntimeID, command: String = RuntimeManagedSSHHelperEvidenceTests.command,
                               resultID: String = "helper-1", copilotMessageIndex: Int = 0) throws -> [[String: Any]] {
        var frames = try Self.frames(runtime: runtime, command: command, resultID: resultID)
        let provider = runtime == .copilotCLI ? "copilot" : "claude"
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/\(provider)/answer-write-signoff.jsonl")
        let captured = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let input = ["command": command]
        if runtime == .copilotCLI {
            var delta = try #require(captured.first { $0["type"] as? String == "assistant.tool_call_delta" })
            var data = try #require(delta["data"] as? [String: Any])
            #expect(delta["ephemeral"] as? Bool == true && data["toolType"] as? String == "function")
            data["toolCallId"] = "helper-1"; data["toolName"] = "bash"
            data["inputDelta"] = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            delta["data"] = data; frames[0] = delta
            let messages = captured.filter {
                $0["type"] as? String == "assistant.message"
                    && (($0["data"] as? [String: Any])?["toolRequests"] as? [[String: Any]])?.isEmpty == false
            }
            var message = try #require(messages.dropFirst(copilotMessageIndex).first)
            var messageData = try #require(message["data"] as? [String: Any])
            let requests = try #require(messageData["toolRequests"] as? [[String: Any]])
            var request = try #require(requests.first)
            request["toolCallId"] = "helper-1"; request["name"] = "bash"; request["arguments"] = input
            // The second envelope originally announces a custom apply_patch.
            // The replacement Bash command is a function; custom stays a negative case.
            request["type"] = "function"
            messageData["toolRequests"] = [request]; message["data"] = messageData; frames[1] = message
        } else {
            var start = try #require(captured.first {
                let event = $0["event"] as? [String: Any]
                return event?["type"] as? String == "content_block_start"
                    && (event?["content_block"] as? [String: Any])?["type"] as? String == "tool_use"
            })
            var event = try #require(start["event"] as? [String: Any])
            var block = try #require(event["content_block"] as? [String: Any])
            #expect(block["caller"] as? [String: String] == ["type": "direct"])
            block["id"] = "helper-1"; block["name"] = "Bash"; block["input"] = [String: String]()
            event["index"] = 0; event["content_block"] = block; start["event"] = event; frames[0] = start
            var assistant = try #require(captured.first {
                (($0["message"] as? [String: Any])?["content"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == "tool_use"
                } == true
            })
            var message = try #require(assistant["message"] as? [String: Any])
            let blocks = try #require(message["content"] as? [[String: Any]])
            var completed = try #require(blocks.first { $0["type"] as? String == "tool_use" })
            #expect(completed["caller"] as? [String: String] == ["type": "direct"])
            completed["id"] = "helper-1"; completed["name"] = "Bash"; completed["input"] = input
            message["content"] = [completed]; assistant["message"] = message
            assistant["wire_tool_inputs"] = ["helper-1": input]; frames[2] = assistant
        }
        return frames
    }

    static func evidence(runtime: AgentRuntimeID, capturedMetadata: Bool = true) throws -> RuntimeExecutionProcessEvidence {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime, managedSSHBroker: broker)
        let frames = try capturedMetadata ? Self.capturedFrames(runtime: runtime) : Self.frames(runtime: runtime)
        for frame in frames { try observe(frame, runtime: runtime, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        return evidence
    }

    @Test("Native parser frames account only for exact broker-acknowledged helper work",
          arguments: [AgentRuntimeID.claudeCode, .copilotCLI], [false, true])
    func realFrames(runtime: AgentRuntimeID, capturedMetadata: Bool) throws {
        let evidence = try Self.evidence(runtime: runtime, capturedMetadata: capturedMetadata)
        #expect(evidence.providerTurnEnded && evidence.managedSSHOnly)
        #expect(!evidence.toolsStopped) // remote completion still needs protected job evidence
    }

    @Test("Unrelated or incomplete shell work never acquires managed-helper proof", arguments: [AgentRuntimeID.claudeCode, .copilotCLI],
        ["compound", "substitution", "lookalike", "redirect", "background", "unmatched", "missingAck", "extraStart", "unknown", "counter", "intermediateCounter", "extraIntermediateTool", "nestedIntermediateWork", "omittedFrames", "missingResult", "missingEOF"])
    func failClosed(runtime: AgentRuntimeID, fault: String) throws {
        let broker = RuntimeManagedSSHBrokerEvidence()
        if fault != "missingAck" { broker.acknowledge(Self.admitted) }
        if fault == "extraStart" { broker.acknowledge(Self.admitted) }
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime, managedSSHBroker: broker)
        let command: String
        switch fault {
        case "compound": command = Self.command + "; ssh elsewhere 'sleep 10 &'"
        case "substitution": command = Self.command + " \"$(touch unrelated)\""
        case "lookalike": command = "/tmp/astra-workspace-job start --connection fixture -- 'sleep 10'"
        case "redirect": command = Self.command + " > unrelated"
        case "background": command = Self.command + " &"
        default: command = Self.command
        }
        var frames = try Self.capturedFrames(runtime: runtime, command: command, resultID: fault == "unmatched" ? "unknown" : "helper-1")
        if fault == "missingResult" { frames.remove(at: frames.count - 2) }
        if fault == "omittedFrames" { frames = [try #require(frames.last)] }
        if fault == "unknown" { frames.insert(["type": "unknown.native.work"], at: 0) }
        if fault == "counter" { frames[frames.count - 1]["subagent_stats"] = ["spawned": 1] }
        if fault == "intermediateCounter" { frames[0]["queued_turn_count"] = 1 }
        if fault == "extraIntermediateTool" { frames[0]["toolRequests"] = [["name": "ssh"]] }
        if fault == "nestedIntermediateWork" {
            if runtime == .claudeCode {
                var event = try #require(frames[0]["event"] as? [String: Any])
                var block = try #require(event["content_block"] as? [String: Any])
                block["subagent_stats"] = ["spawned": 1]; event["content_block"] = block; frames[0]["event"] = event
            } else {
                var data = try #require(frames[0]["data"] as? [String: Any])
                data["unknown_native_work"] = true; frames[0]["data"] = data
            }
        }
        for frame in frames { try Self.observe(frame, runtime: runtime, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: fault != "missingEOF")
        #expect(!evidence.managedSSHOnly)
        #expect(!evidence.toolsStopped)
    }

    @Test("Claude caller metadata permits only an exact direct caller",
          arguments: [false, true], ["indirect", "extra", "null", "string"])
    func invalidClaudeCaller(completed: Bool, fault: String) throws {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .claudeCode, managedSSHBroker: broker)
        var frames = try Self.capturedFrames(runtime: .claudeCode)
        let caller: Any
        switch fault {
        case "indirect": caller = ["type": "code_execution"]
        case "extra": caller = ["type": "direct", "subagent_stats": ["spawned": 1]] as [String: Any]
        case "null": caller = NSNull()
        default: caller = "direct"
        }
        if completed {
            var message = try #require(frames[2]["message"] as? [String: Any])
            var blocks = try #require(message["content"] as? [[String: Any]])
            blocks[0]["caller"] = caller; message["content"] = blocks; frames[2]["message"] = message
        } else {
            var event = try #require(frames[0]["event"] as? [String: Any])
            var block = try #require(event["content_block"] as? [String: Any])
            block["caller"] = caller; event["content_block"] = block; frames[0]["event"] = event
        }
        for frame in frames { try Self.observe(frame, runtime: .claudeCode, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Copilot native metadata rejects malformed flags, unknown kinds and extra work",
          arguments: ["number", "false", "string", "null", "toolType", "extra", "queued", "subagent"])
    func invalidCopilotMetadata(fault: String) throws {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var data = try #require(frames[0]["data"] as? [String: Any])
        switch fault {
        case "number": frames[0]["ephemeral"] = 1
        case "false": frames[0]["ephemeral"] = false
        case "string": frames[0]["ephemeral"] = "true"
        case "null": frames[0]["ephemeral"] = NSNull()
        case "toolType": data["toolType"] = "custom"
        case "extra": data["unknown_native_work"] = true
        case "queued": data["queued_turn_count"] = 1
        default: data["subagent_stats"] = ["spawned": 1]
        }
        frames[0]["data"] = data
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    static func copilotProgressFrame(_ type: String) -> [String: Any] {
        let outputKey = type == "tool.execution_partial_result" ? "partialOutput" : "progressMessage"
        // Native shapes are also exercised by CopilotStreamRegressionTests.
        // JSON-looking output is text, not another execution envelope.
        return ["type": type, "ephemeral": true,
                "data": ["toolCallId": "helper-1", outputKey: #"{"queued_turn_count":1,"toolRequests":[{"name":"ssh"}]}"#]]
    }

    @Test("Copilot helper progress preserves native output shapes",
          arguments: ["tool.execution_partial_result", "tool.execution_progress"], [false, true])
    func copilotProgressNativeShape(type: String, ephemeral: Bool) throws {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var progress = Self.copilotProgressFrame(type)
        if !ephemeral { progress.removeValue(forKey: "ephemeral") }
        frames.insert(progress, at: 3) // after the matching start, before completion
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Copilot helper progress rejects unvalidated work and invalid lifecycle identities",
          arguments: ["tool.execution_partial_result", "tool.execution_progress"],
          ["arguments", "toolName", "unknown", "queued", "subagent", "requests", "missingOutput", "numberOutput",
           "objectOutput", "wrongOutput", "missingID", "unknownID", "emptyID", "beforeStart", "afterCompletion"])
    func copilotProgressRejectsUnvalidatedWork(type: String, fault: String) throws {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var progress = Self.copilotProgressFrame(type)
        var data = try #require(progress["data"] as? [String: Any])
        let outputKey = type == "tool.execution_partial_result" ? "partialOutput" : "progressMessage"
        var insertion = 3
        switch fault {
        case "arguments": data["arguments"] = ["command": "ssh elsewhere 'sleep 10 &'"]
        case "toolName": data["toolName"] = "unrelated"
        case "unknown": data["unknown_native_work"] = true
        case "queued": data["queued_turn_count"] = 1
        case "subagent": data["subagent_stats"] = ["spawned": 1]
        case "requests": data["toolRequests"] = [["name": "ssh"]]
        case "missingOutput": data.removeValue(forKey: outputKey)
        case "numberOutput": data[outputKey] = 1
        case "objectOutput": data[outputKey] = ["toolRequests": [["name": "ssh"]]]
        case "wrongOutput":
            data.removeValue(forKey: outputKey)
            data[outputKey == "partialOutput" ? "progressMessage" : "partialOutput"] = "unrelated shape"
        case "missingID": data.removeValue(forKey: "toolCallId")
        case "unknownID": data["toolCallId"] = "unrelated"
        case "emptyID": data["toolCallId"] = ""
        case "beforeStart": insertion = 2
        default: insertion = 4 // completion has already been observed
        }
        progress["data"] = data; frames.insert(progress, at: insertion)
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Captured Copilot helper announcements preserve descriptive metadata and empty work hints",
          arguments: [0, 1], ["captured", "empty", "null", "rteFalse", "descriptiveScalars"])
    func copilotAnnouncementNativeShape(messageIndex: Int, metadata: String) throws {
        var frames = try Self.capturedFrames(runtime: .copilotCLI, copilotMessageIndex: messageIndex)
        var data = try #require(frames[1]["data"] as? [String: Any])
        switch metadata {
        case "empty":
            data["parentToolCallId"] = ""
            data["serverTools"] = ["provider": "openai-responses", "items": [], "rawContentBlocks": [],
                                   "functionCallNamespaces": [String: String]()] as [String: Any]
        case "null": data["parentToolCallId"] = NSNull(); data["serverTools"] = NSNull()
        case "rteFalse": data["rte"] = false
        case "descriptiveScalars":
            data["outputTokens"] = 17; data["chunkCount"] = 2; data["chunkIndex"] = 0
            for key in ["clientRequestId", "providerId", "requestId", "serviceRequestId", "reasoningWireField"] {
                data[key] = "fixture"
            }
        default: break
        }
        frames[1]["data"] = data
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Copilot helper announcements reject unknown work and malformed descriptive metadata",
          arguments: ["arguments", "toolName", "unknown", "contentNumber", "messageNumber", "reasoningNumber",
                      "reasoningUnknown", "rteNumber", "outputTokensString", "outputTokensBool", "requestType", "requestSummary"])
    func copilotAnnouncementRejectsUnvalidatedWork(fault: String) throws {
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var data = try #require(frames[1]["data"] as? [String: Any])
        switch fault {
        case "arguments": data["arguments"] = ["command": "ssh elsewhere 'sleep 10 &'"]
        case "toolName": data["toolName"] = "unrelated"
        case "unknown": data["unknown_native_work"] = true
        case "contentNumber": data["content"] = 1
        case "messageNumber": data["messageId"] = 1
        case "reasoningNumber": data["reasoningBlocks"] = 1
        case "reasoningUnknown": data["reasoningBlocks"] = ["provider": "fixture", "unknown_native_work": true] as [String: Any]
        case "rteNumber": data["rte"] = 1
        case "outputTokensString": data["outputTokens"] = "17"
        case "outputTokensBool": data["outputTokens"] = true
        default:
            var requests = try #require(data["toolRequests"] as? [[String: Any]])
            if fault == "requestType" { requests[0]["type"] = "custom" }
            else { requests[0]["intentionSummary"] = ["toolName": "unrelated"] }
            data["toolRequests"] = requests
        }
        frames[1]["data"] = data
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(Self.admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.managedSSHOnly && !evidence.toolsStopped)
    }

    @Test("Native subagent and server-tool work stays uncertain with or without a managed helper",
          arguments: ["announcement", "afterHelper", "withoutHelper"],
          ["parent", "parentNumber", "parentFalse", "serverItems", "serverRaw", "serverNamespaces", "serverAdvisor",
           "serverZero", "serverFalse", "serverUnknownZero", "serverMalformed"])
    func copilotNativeWorkHintsRemainSticky(route: String, fault: String) throws {
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var frame: [String: Any] = route == "announcement" ? frames[1]
            : ["type": "assistant.message", "data": ["content": "Synthetic answer"]]
        var data = try #require(frame["data"] as? [String: Any])
        switch fault {
        case "parent": data["parentToolCallId"] = "unrelated-subagent"
        case "parentNumber": data["parentToolCallId"] = 0
        case "parentFalse": data["parentToolCallId"] = false
        case "serverItems": data["serverTools"] = ["provider": "fixture", "items": [["type": "tool_call"]]] as [String: Any]
        case "serverRaw": data["serverTools"] = ["provider": "fixture", "rawContentBlocks": [["type": "tool_use"]]] as [String: Any]
        case "serverNamespaces": data["serverTools"] = ["provider": "fixture", "functionCallNamespaces": ["call-1": "functions"]] as [String: Any]
        case "serverAdvisor": data["serverTools"] = ["provider": "fixture", "advisorModel": "fixture-advisor"]
        case "serverZero": data["serverTools"] = 0
        case "serverFalse": data["serverTools"] = false
        case "serverUnknownZero": data["serverTools"] = ["provider": "fixture", "unknown_native_work": 0] as [String: Any]
        default: data["serverTools"] = ["provider": "fixture", "items": 0] as [String: Any]
        }
        frame["data"] = data
        if route == "announcement" { frames[1] = frame }
        else if route == "afterHelper" { frames.insert(frame, at: frames.count - 1) }
        else { frames = [frame, try #require(frames.last)] }
        let broker = RuntimeManagedSSHBrokerEvidence()
        if route != "withoutHelper" { broker.acknowledge(Self.admitted) }
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.managedSSHOnly)
        #expect(!evidence.toolsStopped)
    }

    @Test("Native empty subagent and server-tool metadata preserves text-only cleanup",
          arguments: [false, true], ["omitted", "providerOnly", "empty", "null"])
    func copilotNativeEmptyWorkHintsAllowText(withHelper: Bool, metadata: String) throws {
        var frames = try Self.capturedFrames(runtime: .copilotCLI)
        var data: [String: Any] = ["content": "Synthetic answer"]
        switch metadata {
        case "providerOnly": data["serverTools"] = ["provider": "openai-responses"]
        case "empty":
            data["parentToolCallId"] = ""
            data["serverTools"] = ["provider": "fixture", "items": [], "rawContentBlocks": [],
                                   "functionCallNamespaces": [String: String]()] as [String: Any]
        case "null": data["parentToolCallId"] = NSNull(); data["serverTools"] = NSNull()
        default: break
        }
        let frame: [String: Any] = ["type": "assistant.message", "data": data]
        if withHelper { frames.insert(frame, at: frames.count - 1) }
        else { frames = [frame, try #require(frames.last)] }
        let broker = RuntimeManagedSSHBrokerEvidence()
        if withHelper { broker.acknowledge(Self.admitted) }
        let evidence = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        for frame in frames { try Self.observe(frame, runtime: .copilotCLI, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(evidence.managedSSHOnly == withHelper)
        #expect(evidence.toolsStopped == !withHelper)
    }
}
