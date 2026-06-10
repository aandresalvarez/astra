import Foundation
import SwiftData
import ASTRACore

/// Stdin/stdout control-protocol support for providers that can ask ASTRA for
/// live tool approval mid-run (Claude Code `--permission-prompt-tool stdio`
/// with stream-json input). The run pauses on the provider side while ASTRA
/// surfaces the ask; an approval answers the same process instead of killing
/// it and relaunching, so the provider session and its context survive asks.
struct AgentRuntimeInteractiveAskPlan: Equatable {
    /// JSON line written to the provider's stdin at launch carrying the prompt,
    /// required because stream-json input mode ignores a positional prompt arg.
    let initialStdinMessage: String
}

/// A `can_use_tool` ask decoded from the provider's control stream.
struct AgentInteractiveAskRequest: Sendable {
    let requestID: String
    let toolName: String
    let inputSummary: String?
}

enum ClaudeControlProtocol {
    struct ControlRequest {
        let requestID: String
        let subtype: String
        let toolName: String?
        let inputJSON: [String: Any]?
        let inputSummary: String?
    }

    static func initialUserMessage(prompt: String) -> String? {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": prompt]]
            ]
        ]
        return encode(payload)
    }

    static func controlRequest(from line: String) -> ControlRequest? {
        guard line.contains("\"control_request\""),
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "control_request",
              let requestID = object["request_id"] as? String,
              let request = object["request"] as? [String: Any],
              let subtype = request["subtype"] as? String else {
            return nil
        }
        let input = request["input"] as? [String: Any]
        let summary = input.flatMap { encode($0) }.map { String($0.prefix(600)) }
        return ControlRequest(
            requestID: requestID,
            subtype: subtype,
            toolName: request["tool_name"] as? String,
            inputJSON: input,
            inputSummary: summary
        )
    }

    static func allowResponse(for request: ControlRequest) -> String? {
        response(requestID: request.requestID, body: [
            "behavior": "allow",
            "updatedInput": request.inputJSON ?? [:]
        ])
    }

    static func denyResponse(for request: ControlRequest, message: String) -> String? {
        response(requestID: request.requestID, body: [
            "behavior": "deny",
            "message": message
        ])
    }

    /// Any unrecognized control request must still be answered or the provider
    /// blocks forever waiting on stdin.
    static func errorResponse(requestID: String, message: String) -> String? {
        encode([
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": requestID,
                "error": message
            ]
        ])
    }

    private static func response(requestID: String, body: [String: Any]) -> String? {
        encode([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": body
            ]
        ])
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Pending in-flight asks keyed by task, bridging the provider's blocked
/// control request to the user's approve action in the UI. Approving resolves
/// the waiting continuation; the legacy pause-and-relaunch path is skipped.
final class InFlightPermissionCenter: @unchecked Sendable {
    static let shared = InFlightPermissionCenter()

    struct PendingAsk {
        let requestID: String
        let toolName: String
        let inputSummary: String?
    }

    private struct Waiter {
        let ask: PendingAsk
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var waiters: [UUID: [Waiter]] = [:]

    func awaitDecision(taskID: UUID, ask: PendingAsk) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            waiters[taskID, default: []].append(Waiter(ask: ask, continuation: continuation))
            lock.unlock()
        }
    }

    func pendingAsks(taskID: UUID) -> [PendingAsk] {
        lock.lock()
        defer { lock.unlock() }
        return waiters[taskID]?.map(\.ask) ?? []
    }

    /// Resolves every pending ask for the task. Returns how many were resolved
    /// so callers can distinguish an in-flight approval from the legacy
    /// pause-and-relaunch approval.
    @discardableResult
    func resolveAll(taskID: UUID, approved: Bool) -> Int {
        lock.lock()
        let resolved = waiters.removeValue(forKey: taskID) ?? []
        lock.unlock()
        for waiter in resolved {
            waiter.continuation.resume(returning: approved)
        }
        return resolved.count
    }

    /// Called when the provider process exits so no continuation leaks and the
    /// task does not stay stuck awaiting a decision for a dead run.
    func failAll(taskID: UUID) {
        resolveAll(taskID: taskID, approved: false)
    }
}

extension AgentRuntimeWorker {
    /// Bridges a provider's live `can_use_tool` ask to the UI: the task pauses
    /// as `pendingUser` with a standard approval payload while the provider
    /// process stays alive, and the user's decision resumes the same session.
    @MainActor
    static func interactiveAskHandler(
        runtime: AgentRuntimeID,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        pendingEvents: OrderedMainActorTaskQueue
    ) -> ((AgentInteractiveAskRequest) async -> Bool) {
        let taskID = task.id
        return { ask in
            let request = PermissionBroker.providerNativePromptRequest(toolName: ask.toolName, context: ask.inputSummary)
            let grants = PermissionBroker.approvalGrants(for: request)
            let payload = PermissionBroker.approvalPayloadString(
                providerID: runtime,
                request: request,
                reason: "The provider paused for permission before running this action.",
                providerDetail: ask.inputSummary,
                grants: grants
            )
            pendingEvents.add {
                let event = TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Tool.permissionApprovalRequested,
                    payload: payload,
                    run: run
                )
                modelContext.insert(event)
                task.status = .pendingUser
                task.updatedAt = Date()
                try? modelContext.save()
            }
            let approved = await InFlightPermissionCenter.shared.awaitDecision(
                taskID: taskID,
                ask: InFlightPermissionCenter.PendingAsk(
                    requestID: ask.requestID,
                    toolName: ask.toolName,
                    inputSummary: ask.inputSummary
                )
            )
            pendingEvents.add {
                if approved, task.status == .pendingUser {
                    task.status = .running
                    task.updatedAt = Date()
                }
                let resolution = TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.System.info,
                    payload: approved
                        ? "Live permission approved for \(ask.toolName); the provider continues in the same session."
                        : "Live permission for \(ask.toolName) was declined or the run ended; the provider continues without it.",
                    run: run
                )
                modelContext.insert(resolution)
                try? modelContext.save()
            }
            return approved
        }
    }
}
