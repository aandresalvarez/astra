import Foundation
import ASTRACore
import ASTRAModels

/// Decides whether launching a task rewrites `.claude/settings.local.json` in
/// its checkout to carry template hooks, and so whether admission must claim
/// that checkout exclusively.
///
/// Only Claude Code reads that file. Admission and launch each answer from
/// what they know, and the two answers are built so they cannot disagree
/// toward an unclaimed write:
///
/// - Admission (`claimsCheckoutSettings`) skips the claim only for a runtime it
///   can positively name as one that never reads the file. A missing or
///   unknown runtime keeps the claim.
/// - Launch (`injects`) writes only for a runtime that reads the file, only
///   while the admitted workspace access is exclusive, and only into a folder
///   the admitted lease holds as a writer. A launch that ends up on Claude
///   Code after admission skipped the claim, or whose checkout moved while it
///   was queued, therefore starts without the hooks rather than writing a
///   checkout it does not hold. The hook scope is created before the
///   workspace-drift check, so this cannot be left to that check.
enum TemplateHookInjectionPolicy {
    /// Built-in runtimes that take no configuration from a checkout's
    /// `.claude/settings.local.json`.
    static let runtimesIgnoringCheckoutSettings: Set<AgentRuntimeID> = [
        .codexCLI, .copilotCLI, .cursorCLI, .antigravityCLI, .openCodeCLI
    ]

    /// Mirrors `ClaudeSettingsStore.injectTemplateHooks`' own write guard: an
    /// empty or `{}` payload never touches the settings file.
    static func hasHooks(_ hooksJSON: String) -> Bool {
        !hooksJSON.isEmpty && hooksJSON != "{}"
    }

    static func readsCheckoutSettings(_ runtime: AgentRuntimeID) -> Bool {
        !runtimesIgnoringCheckoutSettings.contains(runtime)
    }

    /// Admission side. `runtimeRawValue` is the runtime frozen on the request,
    /// or the task's own when there is no request.
    static func claimsCheckoutSettings(hooksJSON: String, runtimeRawValue: String?) -> Bool {
        guard hasHooks(hooksJSON) else { return false }
        guard let runtime = runtimeRawValue.flatMap(AgentRuntimeID.init(rawValue:)) else { return true }
        return readsCheckoutSettings(runtime)
    }

    /// Launch side. `runtime` is the one this launch selected. `lease` is the
    /// admitted lock claims; `nil` only for a launch admission never saw,
    /// which keeps the access check alone.
    static func injects(
        hooksJSON: String,
        runtime: AgentRuntimeID,
        workspaceAccess: TaskExecutionResourceAccess,
        path: String = "",
        lease: [TaskResourceLockClaim]? = nil
    ) -> Bool {
        hasHooks(hooksJSON) && readsCheckoutSettings(runtime) && workspaceAccess == .exclusive
            && (lease.map { leaseCoversWrites(to: path, lease: $0) } ?? true)
    }

    /// Whether the lease holds `path` as a writer: a workspace claim on it,
    /// or on a folder containing it.
    static func leaseCoversWrites(to path: String, lease: [TaskResourceLockClaim]) -> Bool {
        guard !path.isEmpty else { return false }
        let target = TaskExecutionResourceBroker.canonicalKey(kind: .workspace, key: path)
        return lease.contains { claim in
            guard claim.resourceKind == .workspace, claim.accessMode == .write else { return false }
            let held = TaskExecutionResourceBroker.canonicalKey(kind: .workspace, key: claim.resourceKey)
            return target == held || target.hasPrefix(held.hasSuffix("/") ? held : held + "/")
        }
    }
}
