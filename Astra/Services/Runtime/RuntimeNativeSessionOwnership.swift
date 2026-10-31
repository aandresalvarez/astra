import Foundation
import ASTRACore
import ASTRAModels

/// Session identity is narrower than an account or provider home. Claims live
/// in the existing execution owner; this policy creates no second authority.
enum RuntimeNativeSessionOwnership {
    /// Called in the ordered ownership queue for a provider's session frame.
    @MainActor
    static func observe(_ sessionID: String?, owner: RuntimeExecutionOwner?,
                        process: AgentRuntimeProcessControl, evidence: RuntimeExecutionProcessEvidence) async -> String? {
        do { try await owner?.session(sessionID); return nil }
        catch {
            evidence.observe(.unknown(type: "native_session_ownership_unverified"))
            process.terminate()
            return error.localizedDescription
        }
    }

    /// A brief admission lease may belong to an independent app process. Wait
    /// without blocking the actor; expiration is a verification failure, never
    /// evidence that another execution or its tools have stopped.
    @MainActor
    static func admission(in store: RuntimeExecutionOwnerStore,
                          deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))) async throws -> RuntimeExecutionOwnerStore.Lease {
        while true {
            try Task.checkCancellation()
            do { return try store.acquireAdmission() }
            catch RuntimeExecutionOwnerStore.Failure.busy {
                guard ContinuousClock.now < deadline else { throw AdmissionTimeout() }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    struct AdmissionTimeout: LocalizedError {
        var errorDescription: String? {
            "Another ASTRA instance is updating execution reservations. Native session ownership could not be verified; its resources remain protected."
        }
    }

    static func normalized(_ sessionID: String?) -> String? {
        guard let value = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func claim(runtime: String, sessionID: String?, taskID: UUID) -> TaskResourceLockClaim? {
        guard let sessionID = normalized(sessionID) else { return nil }
        return TaskExecutionResourceBroker.lockClaims(for: [TaskExecutionResourceClaim(
            kind: .nativeSession, key: runtime + ":" + sessionID, access: .exclusive
        )], taskID: taskID, requestID: nil, runMode: "native_session").first
    }

    static func claim(_ record: RuntimeExecutionOwnerRecord) -> TaskResourceLockClaim? {
        claim(runtime: record.runtime, sessionID: record.sessionID, taskID: record.taskID)
    }

    /// Older receipts already contain the session ID, including in retained
    /// executions. Project those reservations without rewriting old evidence.
    static func claims(_ record: RuntimeExecutionOwnerRecord, store: RuntimeExecutionOwnerStore,
                       readRetained: (URL) throws -> RuntimeExecutionOwnerRecord? = RuntimeExecutionOwnerStore.read) throws -> [TaskResourceLockClaim] {
        let retained = try store.retainedExecutions(of: record, read: readRetained).filter { !($0.resourcesReleased == true && $0.canReplace) }
        // The input may be an orphaned audit: it can never authorize release.
        // Only protected historical receipts above can supply that proof.
        return ([record] + retained).flatMap { receipt in
            (receipt.resourceClaims ?? []).filter { $0.resourceKind == .nativeSession }
                + [claim(receipt)].compactMap { $0 }
        }
    }

    struct Conflict: LocalizedError {
        let runtime: String
        let sessionID: String
        let holder: UUID
        var holderTitle: String? = nil
        var workspace: String? = nil

        var message: String {
            let provider = AgentRuntimeID(rawValue: runtime)?.displayName ?? runtime
            let location = workspace.map { " in workspace \u{201C}\($0)\u{201D}" } ?? ""
            return "Waiting for \(provider) native session \(sessionID), held by \(TaskExecutionResourceBroker.holderLabel(holder, title: holderTitle))\(location). Its execution or tools are not confirmed stopped. Review the owning task; no competing launch was authorized."
        }

        var errorDescription: String? { message }
    }
}
