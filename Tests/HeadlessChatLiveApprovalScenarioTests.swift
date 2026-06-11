import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Live approval control protocol")
struct LiveApprovalControlProtocolTests {
    @Test("control request parses and responses encode allow, deny, and error")
    func controlRequestRoundTrip() throws {
        let line = """
        {"type":"control_request","request_id":"req-42","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"git push"}}}
        """
        let request = try #require(ClaudeControlProtocol.controlRequest(from: line))
        #expect(request.requestID == "req-42")
        #expect(request.subtype == "can_use_tool")
        #expect(request.toolName == "Bash")
        #expect(request.inputSummary?.contains("git push") == true)

        let allow = try #require(ClaudeControlProtocol.allowResponse(for: request))
        #expect(allow.contains("\"type\":\"control_response\""))
        #expect(allow.contains("\"request_id\":\"req-42\""))
        #expect(allow.contains("\"behavior\":\"allow\""))
        #expect(allow.contains("git push"))

        let deny = try #require(ClaudeControlProtocol.denyResponse(for: request, message: "user declined"))
        #expect(deny.contains("\"behavior\":\"deny\""))
        #expect(deny.contains("user declined"))

        let error = try #require(ClaudeControlProtocol.errorResponse(requestID: "req-42", message: "unsupported"))
        #expect(error.contains("\"subtype\":\"error\""))

        #expect(ClaudeControlProtocol.controlRequest(from: "{\"type\":\"assistant\"}") == nil)

        let message = try #require(ClaudeControlProtocol.initialUserMessage(prompt: "Do the thing"))
        #expect(message.contains("\"type\":\"user\""))
        #expect(message.contains("Do the thing"))
    }

    @Test("permission center resolves and fails pending asks")
    func permissionCenterResolvesPendingAsks() async {
        let center = InFlightPermissionCenter()
        let taskID = UUID()
        async let decision = center.awaitDecision(
            taskID: taskID,
            ask: InFlightPermissionCenter.PendingAsk(requestID: "r1", toolName: "Bash", inputSummary: nil)
        )
        var ticks = 0
        while center.pendingAsks(taskID: taskID).isEmpty, ticks < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            ticks += 1
        }
        #expect(!center.pendingAsks(taskID: taskID).isEmpty)
        #expect(center.pendingAsks(taskID: taskID).first?.toolName == "Bash")
        #expect(center.resolveAll(taskID: taskID, approved: true) == 1)
        let approved = await decision
        #expect(approved)
        #expect(center.resolveAll(taskID: taskID, approved: true) == 0)
    }

    @Test("permission center resolves concurrent asks independently by request id")
    func permissionCenterResolvesByRequestID() async {
        let center = InFlightPermissionCenter()
        let taskID = UUID()
        async let d1 = center.awaitDecision(
            taskID: taskID, ask: InFlightPermissionCenter.PendingAsk(requestID: "r1", toolName: "Bash", inputSummary: nil)
        )
        async let d2 = center.awaitDecision(
            taskID: taskID, ask: InFlightPermissionCenter.PendingAsk(requestID: "r2", toolName: "Write", inputSummary: nil)
        )
        var ticks = 0
        while center.pendingAsks(taskID: taskID).count < 2, ticks < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            ticks += 1
        }
        #expect(center.pendingAsks(taskID: taskID).count == 2)

        // Approve r2, deny r1 — each gets its own answer, neither collapses.
        #expect(center.resolve(taskID: taskID, requestID: "r2", approved: true))
        let a2 = await d2
        #expect(a2)
        #expect(center.pendingAsks(taskID: taskID).count == 1)

        #expect(center.resolve(taskID: taskID, requestID: "r1", approved: false))
        let a1 = await d1
        #expect(!a1)
        #expect(center.pendingAsks(taskID: taskID).isEmpty)

        // Unknown id resolves nothing.
        #expect(!center.resolve(taskID: taskID, requestID: "missing", approved: true))
    }

    @Test("PermissionRequestResolution round-trips through its payload")
    func permissionRequestResolutionRoundTrips() throws {
        let resolution = PermissionRequestResolution(requestID: "req-9", approved: false, toolName: "Bash")
        let decoded = try #require(PermissionRequestResolution.decode(from: resolution.payloadString))
        #expect(decoded == resolution)
    }

    @Test("permission.request.resolved closes the open-request dock state")
    func resolvedEventClosesOpenRequest() {
        let base = Date(timeIntervalSince1970: 1000)
        let requested = TaskRuntimePermissionState.Event(
            type: "permission.approval.requested",
            payload: liveRequestPayload(requestID: "r1", toolName: "Bash"),
            timestamp: base
        )
        // Still open with only the request.
        #expect(TaskRuntimePermissionState.build(events: [requested]).hasOpenApprovalRequest)

        // A later resolution (deny, no task.approved) for the SAME id closes it.
        let resolved = TaskRuntimePermissionState.Event(
            type: "permission.request.resolved",
            payload: PermissionRequestResolution(requestID: "r1", approved: false, toolName: "Bash").payloadString,
            timestamp: base.addingTimeInterval(1)
        )
        #expect(!TaskRuntimePermissionState.build(events: [requested, resolved]).hasOpenApprovalRequest)
    }

    @Test("out-of-order resolution of one ask doesn't hide another pending ask")
    func outOfOrderResolutionKeepsOtherAskOpen() {
        let base = Date(timeIntervalSince1970: 1000)
        let events: [RuntimePermissionOpenState.Event] = [
            .init(type: "permission.approval.requested", payload: liveRequestPayload(requestID: "rA", toolName: "Bash"), timestamp: base),
            .init(type: "permission.approval.requested", payload: liveRequestPayload(requestID: "rB", toolName: "Write"), timestamp: base.addingTimeInterval(1)),
            // B resolves first; A is still pending. The old timestamp logic
            // would have wrongly closed the card here.
            .init(type: "permission.request.resolved", payload: PermissionRequestResolution(requestID: "rB", approved: true, toolName: "Write").payloadString, timestamp: base.addingTimeInterval(2))
        ]
        #expect(RuntimePermissionOpenState.hasOpenRequest(events: events))

        // Resolving A too closes the card.
        let closed = events + [
            RuntimePermissionOpenState.Event(type: "permission.request.resolved", payload: PermissionRequestResolution(requestID: "rA", approved: false, toolName: "Bash").payloadString, timestamp: base.addingTimeInterval(3))
        ]
        #expect(!RuntimePermissionOpenState.hasOpenRequest(events: closed))
    }

    @Test("legacy request without requestID still closes on task.approved")
    func legacyRequestClosesOnApproval() {
        let base = Date(timeIntervalSince1970: 1000)
        let requested = RuntimePermissionOpenState.Event(
            type: "permission.approval.requested", payload: "{}", timestamp: base
        )
        #expect(RuntimePermissionOpenState.hasOpenRequest(events: [requested]))
        let approved = RuntimePermissionOpenState.Event(
            type: "task.approved", payload: "Task approved by user.", timestamp: base.addingTimeInterval(1)
        )
        #expect(!RuntimePermissionOpenState.hasOpenRequest(events: [requested, approved]))
    }

    private func liveRequestPayload(requestID: String, toolName: String) -> String {
        PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .providerNativePrompt(toolName: toolName, context: nil),
            reason: "test",
            grants: [],
            requestID: requestID
        )
    }
}

extension HeadlessChatScenarioTests {
    @Test("Claude live ask pauses the task and approval resumes the same process")
    func claudeLiveAskPausesAndApprovalResumesSameProcess() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsFile = harness.rootURL.appendingPathComponent("claude-live-args.txt")
        let stdinFile = harness.rootURL.appendingPathComponent("claude-live-stdin.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            IFS= read -r first_line
            printf '%s\\n' "$first_line" >> \(Self.shQuote(stdinFile.path))
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"live-approval-sess","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"control_request","request_id":"req-live-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"git push origin main"}}}'
            IFS= read -r response_line
            printf '%s\\n' "$response_line" >> \(Self.shQuote(stdinFile.path))
            case "$response_line" in
              *'"behavior":"allow"'*)
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Pushed after live approval"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Pushed after live approval","usage":{"input_tokens":3,"output_tokens":5}}'
                exit_code=0
                ;;
              *)
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"duration_ms":12,"num_turns":1,"result":"denied","usage":{"input_tokens":1,"output_tokens":1}}'
                exit_code=1
                ;;
            esac
            # Like the real CLI in stream-json input mode: after the result,
            # keep reading stdin and exit only on EOF — with the branch's
            # original exit status.
            while IFS= read -r _; do :; done
            exit "$exit_code"
            """, argsFile: argsFile)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Push the release branch", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            liveApprovals: true
        )

        let runHandle = Task { await harness.execute(task: task, worker: worker) }

        var ticks = 0
        while InFlightPermissionCenter.shared.pendingAsks(taskID: task.id).isEmpty, ticks < 200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        let pendingAsk = try #require(InFlightPermissionCenter.shared.pendingAsks(taskID: task.id).first)
        #expect(pendingAsk.toolName == "Bash")
        #expect(pendingAsk.inputSummary?.contains("git push origin main") == true)

        ticks = 0
        while task.status != .pendingUser, ticks < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        #expect(task.status == .pendingUser)
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        InFlightPermissionCenter.shared.resolveAll(taskID: task.id, approved: true)
        _ = await runHandle.value

        #expect(task.status == .completed)
        #expect(task.runs.count == 1)
        #expect(task.runs.first?.output == "Pushed after live approval")
        #expect(task.sessionId == "live-approval-sess")
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Live permission approved") })

        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("--permission-prompt-tool"))
        #expect(args.contains("stream-json"))
        #expect(!args.contains("Push the release branch"))

        let stdin = try String(contentsOf: stdinFile, encoding: .utf8)
        #expect(stdin.contains("Push the release branch"))
        #expect(stdin.contains("\"behavior\":\"allow\""))
        #expect(stdin.contains("\"request_id\":\"req-live-1\""))
    }

    @Test("Claude live ask denial answers the process and lifts the pause")
    func claudeLiveAskDenialAnswersProcessAndLiftsPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let stdinFile = harness.rootURL.appendingPathComponent("claude-live-deny-stdin.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            IFS= read -r first_line
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"live-deny-sess","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"control_request","request_id":"req-deny-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"}}}'
            IFS= read -r response_line
            printf '%s\\n' "$response_line" >> \(Self.shQuote(stdinFile.path))
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Skipped the cleanup step after the decline."}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Skipped the cleanup step after the decline.","usage":{"input_tokens":3,"output_tokens":5}}'
            # Like the real CLI in stream-json input mode: after the result,
            # keep reading stdin and exit only on EOF.
            while IFS= read -r _; do :; done
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Tidy the build folder", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            liveApprovals: true
        )

        let runHandle = Task { await harness.execute(task: task, worker: worker) }
        var ticks = 0
        while InFlightPermissionCenter.shared.pendingAsks(taskID: task.id).isEmpty, ticks < 200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        #expect(!InFlightPermissionCenter.shared.pendingAsks(taskID: task.id).isEmpty)

        InFlightPermissionCenter.shared.resolveAll(taskID: task.id, approved: false)
        _ = await runHandle.value

        let stdin = try String(contentsOf: stdinFile, encoding: .utf8)
        #expect(stdin.contains("\"behavior\":\"deny\""))
        #expect(stdin.contains("\"request_id\":\"req-deny-1\""))
        // The provider kept going after the decline; the live-ask pause must
        // not leave the finished task parked in pendingUser.
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("declined") })
        // The deny path emits no task.approved, so the resolved event is what
        // closes the open-request card.
        let resolvedEvent = try #require(task.events.first { $0.type == "permission.request.resolved" })
        let resolution = try #require(PermissionRequestResolution.decode(from: resolvedEvent.payload))
        #expect(!resolution.approved)
        #expect(task.runs.count == 1)
        #expect(task.status == .completed)
    }
}
