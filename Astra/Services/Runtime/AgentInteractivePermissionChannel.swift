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

/// The answer to a live ask, carrying the deny reason so the provider sees the
/// actual cause (ASTRA policy vs the user declining) instead of always "the
/// user declined".
enum InteractiveAskOutcome: Sendable, Equatable {
    case allow
    case deny(message: String)

    var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// A `can_use_tool` ask decoded from the provider's control stream.
struct AgentInteractiveAskRequest: Sendable {
    let requestID: String
    let toolName: String
    let inputSummary: String?
    /// The bare command extracted from the structured input's `command`/`cmd`
    /// key, so policy matching sees `git push …` rather than the JSON-encoded
    /// `inputSummary`. Nil when the input has no such key (e.g. file/web tools,
    /// which carry a path/url instead).
    let commandText: String?

    init(requestID: String, toolName: String, inputSummary: String?, commandText: String? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.commandText = commandText
    }
}

enum ClaudeControlProtocol {
    struct ControlRequest {
        let requestID: String
        let subtype: String
        let toolName: String?
        let inputJSON: [String: Any]?
        let inputSummary: String?

        /// The bare shell command from the structured input, if present.
        var commandText: String? {
            for key in ["command", "cmd"] {
                if let value = inputJSON?[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        }
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

/// Payload for a `permission.request.resolved` event.
struct PermissionRequestResolution: Codable, Equatable {
    var requestID: String
    var approved: Bool
    var toolName: String

    var payloadString: String {
        // Encoding a fixed-shape Codable can't realistically fail, but never
        // hand-roll the fallback: an interpolated requestID with a quote or
        // backslash would emit invalid JSON that the open-request logic then
        // can't decode. A safe sentinel is better than a malformed payload.
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(from payload: String) -> PermissionRequestResolution? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PermissionRequestResolution.self, from: data)
    }
}

/// Whether a runtime permission card should still be shown, correct under
/// concurrent and out-of-order resolutions. Shared by the decision dock and the
/// lifecycle coordinator so the two can't drift.
enum RuntimePermissionOpenState {
    /// Minimal event shape the open-state check needs.
    struct Event {
        let type: String
        let payload: String
        let timestamp: Date
    }

    static func hasOpenRequest(events: [Event]) -> Bool {
        let requests = events.filter { $0.type == "permission.approval.requested" }
        guard !requests.isEmpty else { return false }

        // Live asks carry a requestID and are closed by a matching
        // permission.request.resolved — correlate by id so resolving ask B
        // never closes the still-open ask A.
        let resolvedIDs = Set(
            events
                .filter { $0.type == "permission.request.resolved" }
                .compactMap { PermissionRequestResolution.decode(from: $0.payload)?.requestID }
        )
        for request in requests {
            guard let id = PermissionApprovalEventPayload.decoded(from: request.payload)?.requestID else {
                continue // legacy request — handled by the timestamp path below
            }
            if !resolvedIDs.contains(id) {
                return true // an un-resolved live ask is still open
            }
        }

        // Legacy pause-and-relaunch requests (no requestID) are closed by a
        // later task.approved.
        let legacyRequests = requests.filter {
            PermissionApprovalEventPayload.decoded(from: $0.payload)?.requestID == nil
        }
        guard let latestLegacy = legacyRequests.max(by: { $0.timestamp < $1.timestamp }) else {
            return false // all requests were live and resolved
        }
        let latestApproval = events
            .filter { $0.type == "task.approved" }
            .max { $0.timestamp < $1.timestamp }
        return latestApproval.map { latestLegacy.timestamp > $0.timestamp } ?? true
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

    /// Resolves a single pending ask by request id. Returns true if one was
    /// found and resolved. Concurrent asks on the same task (a provider that
    /// batches, or interleaved tool calls) get independent answers — only
    /// `resolveAll` collapses them, and that is reserved for process death.
    @discardableResult
    func resolve(taskID: UUID, requestID: String, approved: Bool) -> Bool {
        lock.lock()
        guard var taskWaiters = waiters[taskID],
              let index = taskWaiters.firstIndex(where: { $0.ask.requestID == requestID }) else {
            lock.unlock()
            return false
        }
        let waiter = taskWaiters.remove(at: index)
        if taskWaiters.isEmpty {
            waiters.removeValue(forKey: taskID)
        } else {
            waiters[taskID] = taskWaiters
        }
        lock.unlock()
        waiter.continuation.resume(returning: approved)
        return true
    }

    /// Resolves every pending ask for the task. Returns how many were resolved
    /// so callers can distinguish an in-flight approval from the legacy
    /// pause-and-relaunch approval. Used by the UI (which approves "the open
    /// request" without tracking ids) and for process-death cleanup.
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
        permissionPolicy: PermissionPolicy,
        manifest: RunPermissionManifest?,
        modelContext: ModelContext,
        pendingEvents: OrderedMainActorTaskQueue
    ) -> ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome) {
        let taskID = task.id
        return { ask in
            // Classify the ask against ASTRA policy before deciding whether to
            // interrupt the user. Auto auto-approves inside the envelope and
            // denies the deny-list; Ask forwards. No manifest → forward (the
            // safe default, matching pre-classifier behavior).
            let decision = manifest.map {
                // Only the extracted bare shell command goes into policy
                // matching — never the JSON-encoded inputSummary, which would
                // miss shell deny/allow patterns and misclassify non-shell
                // asks (Write/WebFetch) as "commands". Non-shell asks match by
                // tool name with a nil command.
                AutoApprovalClassifier.decide(
                    toolName: ask.toolName,
                    command: ask.commandText,
                    permissionPolicy: permissionPolicy,
                    manifest: $0
                )
            } ?? .forwardToUser

            switch decision {
            case .autoApprove:
                pendingEvents.add {
                    modelContext.insert(TaskEvent(
                        task: task,
                        eventType: TaskEventTypes.Tool.permissionRequestResolved,
                        payload: PermissionRequestResolution(
                            requestID: ask.requestID, approved: true, toolName: ask.toolName
                        ).payloadString,
                        run: run
                    ))
                    modelContext.insert(TaskEvent(
                        task: task,
                        eventType: TaskEventTypes.System.info,
                        payload: "Auto-approved \(ask.toolName) (inside the active policy envelope).",
                        run: run
                    ))
                    try? modelContext.save()
                }
                return .allow
            case .deny(let reason):
                pendingEvents.add {
                    modelContext.insert(TaskEvent(
                        task: task,
                        eventType: TaskEventTypes.Tool.permissionRequestResolved,
                        payload: PermissionRequestResolution(
                            requestID: ask.requestID, approved: false, toolName: ask.toolName
                        ).payloadString,
                        run: run
                    ))
                    // Recorded as system.info, NOT permission.denied: this is a
                    // gracefully-handled policy denial (the provider is told no
                    // and continues), not an unmet runtime permission prompt.
                    // shouldPauseForRuntimePermissionApproval pauses any failed
                    // run carrying a permission.denied event, so using that type
                    // here would wrongly surface an approval card if the run
                    // later exited non-zero for an unrelated reason. The denial
                    // is already recorded by the permission.request.resolved
                    // event above.
                    modelContext.insert(TaskEvent(
                        task: task,
                        eventType: TaskEventTypes.System.info,
                        payload: "Auto-denied \(ask.toolName) by ASTRA policy: \(reason)",
                        run: run
                    ))
                    try? modelContext.save()
                }
                // The provider sees the actual policy reason, not "user declined".
                return .deny(message: "Blocked by ASTRA policy: \(reason)")
            case .forwardToUser:
                break
            }

            let request = PermissionBroker.providerNativePromptRequest(toolName: ask.toolName, context: ask.inputSummary)
            let grants = PermissionBroker.approvalGrants(for: request)
            let payload = PermissionBroker.approvalPayloadString(
                providerID: runtime,
                request: request,
                reason: "The provider paused for permission before running this action.",
                providerDetail: ask.inputSummary,
                grants: grants,
                requestID: ask.requestID
            )
            pendingEvents.add {
                let event = TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Tool.permissionApprovalRequested,
                    payload: payload,
                    run: run
                )
                modelContext.insert(event)
                TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext)
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
                // The provider continues after allow AND deny alike, so the
                // pause always lifts; the run-status guard keeps this from
                // resurrecting a task whose run already finished.
                if task.status == .pendingUser, run.status == .running {
                    TaskStateMachine.resumeAfterRuntimePermission(task, modelContext: modelContext)
                }
                // Closes the open-request card: a denied live ask never emits
                // task.approved, so without this the card would linger.
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Tool.permissionRequestResolved,
                    payload: PermissionRequestResolution(
                        requestID: ask.requestID,
                        approved: approved,
                        toolName: ask.toolName
                    ).payloadString,
                    run: run
                ))
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.System.info,
                    payload: approved
                        ? "Live permission approved for \(ask.toolName); the provider continues in the same session."
                        : "Live permission for \(ask.toolName) was declined or the run ended; the provider continues without it.",
                    run: run
                ))
                try? modelContext.save()
            }
            return approved
                ? .allow
                : .deny(message: "The user declined this action in ASTRA. Continue without it or propose an alternative.")
        }
    }
}
