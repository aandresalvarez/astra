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

    static func evidence(runtime: AgentRuntimeID) throws -> RuntimeExecutionProcessEvidence {
        let broker = RuntimeManagedSSHBrokerEvidence(); broker.acknowledge(admitted)
        let evidence = RuntimeExecutionProcessEvidence(runtime: runtime, managedSSHBroker: broker)
        for frame in try frames(runtime: runtime) { try observe(frame, runtime: runtime, in: evidence) }
        evidence.processExited(naturally: true, stdoutEOF: true)
        return evidence
    }

    @Test("Real parser frames account only for exact broker-acknowledged helper work", arguments: [AgentRuntimeID.claudeCode, .copilotCLI])
    func realFrames(runtime: AgentRuntimeID) throws {
        let evidence = try Self.evidence(runtime: runtime)
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
        var frames = try Self.frames(runtime: runtime, command: command, resultID: fault == "unmatched" ? "unknown" : "helper-1")
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
}
