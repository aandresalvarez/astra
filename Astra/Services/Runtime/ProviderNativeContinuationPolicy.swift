import Foundation
import ASTRACore
import ASTRAModels

/// Checks the durable launch contract before reusing a provider session.
/// A mismatch rebuilds context from ASTRA history without altering prior runs.
enum ProviderNativeContinuationPolicy {
    struct Decision {
        let sessionID: String?
        let skipReason: String
        let signatureMatched: Bool
    }

    @MainActor
    static func resolve(
        for task: AgentTask,
        currentRun: TaskRun,
        runtimeAdapter: any AgentRuntimeDescriptorReadiness,
        phase: RunPhase,
        currentLaunchSignature: ProviderLaunchSignaturePayload,
        grantNeutralizingStrings: Set<String> = [],
        providerHomeDirectory: String = "",
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Decision {
        guard phase == .resume,
              runtimeAdapter.descriptor.supportsNativeContinuation else {
            return Decision(sessionID: nil, skipReason: "unsupported_or_not_resume_phase", signatureMatched: false)
        }

        guard let sessionID = task.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return Decision(sessionID: nil, skipReason: "missing_session_id", signatureMatched: false)
        }

        if shouldSkipNativeContinuationAfterLastRun(task, currentRun: currentRun) {
            return Decision(sessionID: nil, skipReason: "unsafe_previous_no_progress_run", signatureMatched: false)
        }

        guard let previousRun = priorRun(forNativeSessionID: sessionID, task: task, currentRun: currentRun) else {
            return Decision(sessionID: nil, skipReason: "missing_previous_session_run", signatureMatched: false)
        }

        let storeLookup = ProviderNativeSessionStore.lookup(
            runtime: runtimeAdapter.descriptor.id,
            sessionID: sessionID,
            providerHomeDirectory: providerHomeDirectory,
            userHome: userHome,
            environment: environment
        )
        guard storeLookup == .present else {
            // Only a confirmed absence stops the task advertising the session; a store that could not be
            // read says nothing about it, so the session stays for a later attempt.
            if storeLookup == .absent { task.sessionId = nil }
            return Decision(
                sessionID: nil,
                skipReason: storeLookup == .absent ? "provider_session_missing" : "provider_session_unverifiable",
                signatureMatched: false
            )
        }

        guard let previousSignature = ProviderLaunchSignatureService.storedSignature(for: task, run: previousRun) else {
            return Decision(sessionID: nil, skipReason: "missing_previous_launch_signature", signatureMatched: false)
        }

        let previousValue = ProviderLaunchSignatureService.grantNeutralizedValue(
            previousSignature,
            grantStrings: grantNeutralizingStrings
        )
        let currentValue = ProviderLaunchSignatureService.grantNeutralizedValue(
            currentLaunchSignature,
            grantStrings: grantNeutralizingStrings
        )
        guard previousValue == currentValue else {
            return Decision(sessionID: nil, skipReason: "launch_signature_changed", signatureMatched: false)
        }

        return Decision(sessionID: sessionID, skipReason: "none", signatureMatched: true)
    }

    private static func shouldSkipNativeContinuationAfterLastRun(_ task: AgentTask, currentRun: TaskRun) -> Bool {
        guard let lastRun = task.runs
            .filter({ $0.id != currentRun.id })
            .sorted(by: { $0.startedAt > $1.startedAt })
            .first,
              lastRun.status == .failed,
              lastRun.typedStopReason.map({
                  [.providerNoSemanticProgress, .providerNoActionableProgress].contains($0)
              }) == true,
              lastRun.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private static func priorRun(forNativeSessionID sessionID: String, task: AgentTask, currentRun: TaskRun) -> TaskRun? {
        task.runs
            .filter { $0.id != currentRun.id }
            .filter { $0.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID }
            .max { $0.startedAt < $1.startedAt }
    }

}
