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
/// - Launch (`injects`) writes only for a runtime that reads the file *and*
///   only while the admitted workspace access is exclusive. A launch that
///   ends up on Claude Code after admission skipped the claim therefore
///   starts without the hooks rather than writing a checkout it holds shared.
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

    /// Launch side. `runtime` is the one this launch selected.
    static func injects(
        hooksJSON: String,
        runtime: AgentRuntimeID,
        workspaceAccess: TaskExecutionResourceAccess
    ) -> Bool {
        hasHooks(hooksJSON) && readsCheckoutSettings(runtime) && workspaceAccess == .exclusive
    }
}
