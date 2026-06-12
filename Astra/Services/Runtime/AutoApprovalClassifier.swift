import Foundation
import ASTRACore

/// Decides what a live in-flight ask becomes, given the run's policy.
///
/// This is the trap-closer for "Auto mode auto-approves the provider's native
/// asks": done naively, Auto would let the *provider* define the blast radius,
/// so `rm -rf` would self-approve. Instead Auto auto-approves only what's
/// inside ASTRA's policy envelope and denies the rest — exactly what Ask mode
/// would enforce as a non-interactive grant. The allow/ask/deny judgment is
/// delegated to `AgentRuntimePolicyGuard.disposition`, so there is one source
/// of truth shared with post-hoc enforcement.
enum LiveAskDecision: Equatable {
    /// Answer allow without bothering the user (Auto, inside the envelope).
    case autoApprove
    /// Surface the approval card and await the user (Ask, or Auto edge cases).
    case forwardToUser
    /// Answer deny with a message (denied by policy, in any mode).
    case deny(reason: String)
}

enum AutoApprovalClassifier {
    static func decide(
        toolName: String,
        command: String?,
        permissionPolicy: PermissionPolicy,
        manifest: RunPermissionManifest
    ) -> LiveAskDecision {
        let disposition = AgentRuntimePolicyGuard(manifest: manifest)
            .disposition(toolName: toolName, command: command)

        switch disposition {
        case .denied:
            return .deny(reason: "This action is denied by the active ASTRA policy and was not run.")
        case .allowed:
            // Inside the envelope regardless of mode — no need to interrupt.
            return .autoApprove
        case .ask:
            switch permissionPolicy {
            case .autonomous:
                // Auto: routine work auto-approves; the deny-list already
                // peeled off above, so what remains is policy-permitted.
                return .autoApprove
            case .restricted, .interactive:
                // Ask: the user decides.
                return .forwardToUser
            }
        }
    }
}
