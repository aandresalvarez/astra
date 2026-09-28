import Foundation
import ASTRACore

extension RuntimeReadinessCheck {
    /// The check for a probe that ran but proved nothing about the account.
    ///
    /// A readiness probe has three honest answers, not two: the provider is
    /// usable, it is definitely not (the CLI ran to completion and said so),
    /// or the probe never got an answer because it timed out, could not start,
    /// or was cancelled. The last is no evidence either way. It warns and lets
    /// the run go ahead, where the provider reports any real sign-in problem
    /// itself. Blocking on it turned one stalled model request into a dead
    /// task and told the user to re-authenticate.
    ///
    /// Returns nil when the process ran to completion; its exit status and
    /// output are then the caller's evidence to judge.
    static func inconclusiveProbe(
        id: String,
        title: String,
        result: RunResult,
        timeout: TimeInterval
    ) -> RuntimeReadinessCheck? {
        let reason: String
        switch result.outcome {
        case .exited:
            return nil
        case .timedOut:
            reason = "the check timed out after \(Int(timeout))s"
        case .cancelled:
            reason = "the check was cancelled"
        case .launchFailed(let failure):
            reason = "the check could not start (\(RuntimeReadinessRedactor.redacted(failure)))"
        }
        return inconclusive(id: id, title: title, reason: reason)
    }

    static func inconclusive(id: String, title: String, reason: String) -> RuntimeReadinessCheck {
        RuntimeReadinessCheck(
            id: id,
            title: title,
            detail: "\(title) could not be verified: \(reason). That is usually transient, not a sign-in problem.",
            state: .warning,
            remediation: "ASTRA will still start the run, and the provider reports any real sign-in problem. "
                + "Click Check Again to retry the check."
        )
    }
}
