import Foundation
import ASTRACore
import ASTRAModels

enum ProviderMessages {
    static func missingExecutable(
        providerName: String,
        installAction: String,
        authAction: String
    ) -> String {
        "\(providerName) CLI not found. \(installAction), then \(authAction)"
    }

    static func missingExecutableAtPath(providerName: String, executablePath: String) -> String {
        "\(providerName) CLI not found at '\(executablePath)'. Check Settings."
    }

    static func start(providerName: String?, goal: String) -> String {
        "\(providerName ?? "Agent") started working on: \(goal)"
    }

    static func manualCompletion(providerName: String?, phase: RunPhase) -> String {
        if let providerName {
            return "\(providerName) finished."
        }
        return phase == .resume ? "Follow-up completed." : "Agent finished."
    }

    static func failurePrefix(providerName: String?, phase: RunPhase, exitCode: Int) -> String {
        if let providerName {
            return "\(providerName) exited with code \(exitCode)."
        }
        return phase == .resume ? "Follow-up failed (exit \(exitCode))." : "Agent exited with code \(exitCode)."
    }

    static func timeout(phase: RunPhase, timeoutSeconds: TimeInterval) -> String {
        let label = phase == .resume ? "Resume" : "Task"
        return "\(label) idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    static func maxTurns(phase: RunPhase, maxTurns: Int) -> String {
        if phase == .resume {
            return "Max turns reached (\(maxTurns)) during resume. Process killed."
        }
        return "Max turns reached (\(maxTurns)). Process killed."
    }
}

/// How an adapter's missing-executable diagnostic should be rendered.
///
/// The Claude Code adapter reports the resolved executable path (it always
/// resolves one via `RuntimePathResolver`, configured or detected), while the
/// CLI-style adapters (Copilot, Antigravity, Codex, Cursor, OpenCode) report
/// an install/auth remediation hint instead, since ASTRA does not surface a
/// resolved path for those runtimes in this message.
///
/// `installAndAuthHint` carries its own `providerName` (rather than reusing
/// `ProviderRuntimeMessages.providerName`) because Copilot and Antigravity
/// use a longer name here than in their other diagnostic copy — "GitHub
/// Copilot"/"Google Antigravity" for this message vs. "Copilot"/"Antigravity"
/// for start/completion/failure copy — matching the pre-collapse adapters.
enum ProviderMissingExecutableStyle: Equatable, Sendable {
    case resolvedPath
    case installAndAuthHint(providerName: String, installAction: String, authAction: String)
}

/// Per-adapter presentation strings backing the `AgentRuntimePostRunDiagnostics`
/// diagnostic-copy requirements and the missing-executable diagnostics in
/// `AgentRuntimeProcessLaunchPlanning`.
///
/// Every one of the ~8 protocol requirements this backs is pure presentation
/// copy keyed off a provider's display name (or `nil` for the generic
/// "Agent"/"Follow-up" copy used by Claude Code). Adapters expose a single
/// `providerMessages` property; the protocol extensions in
/// `AgentRuntimeAdapter.swift` do the string assembly by delegating to
/// `ProviderMessages` above, so behavior is unchanged from before the
/// protocol-surface collapse — only the per-adapter boilerplate is gone.
struct ProviderRuntimeMessages: Equatable, Sendable {
    /// `nil` reproduces the generic "Agent"/"Follow-up" copy (Claude Code);
    /// a value reproduces the "<Provider> ..." copy every CLI adapter used.
    let providerName: String?
    let missingExecutableStyle: ProviderMissingExecutableStyle
    let missingExecutableAuditReason: String
    let missingExecutableStopReason: String?
    /// Whether `timeoutPayload`/`maxTurnsPayload` should vary their copy by
    /// the live `RunPhase` passed to the protocol method (Antigravity, and
    /// the Claude Code default) or always render as `.run` (Copilot, Codex,
    /// Cursor, OpenCode — those adapters do not distinguish resume copy for
    /// timeout/max-turns today).
    let usesLivePhaseForTimeoutAndMaxTurns: Bool

    static let claudeCode = ProviderRuntimeMessages(
        providerName: nil,
        missingExecutableStyle: .resolvedPath,
        missingExecutableAuditReason: "provider_cli_not_found",
        missingExecutableStopReason: nil,
        usesLivePhaseForTimeoutAndMaxTurns: true
    )

    static let copilot = ProviderRuntimeMessages(
        providerName: "Copilot",
        missingExecutableStyle: .installAndAuthHint(
            providerName: "GitHub Copilot",
            installAction: "Install with `brew install copilot-cli` or `npm install -g @github/copilot`",
            authAction: "authenticate with `copilot`."
        ),
        missingExecutableAuditReason: "copilot_cli_not_found",
        missingExecutableStopReason: "missing_copilot",
        usesLivePhaseForTimeoutAndMaxTurns: false
    )

    static let antigravity = ProviderRuntimeMessages(
        providerName: "Antigravity",
        missingExecutableStyle: .installAndAuthHint(
            providerName: "Google Antigravity",
            installAction: "Install it from the official setup docs",
            authAction: "run `agy` once to authenticate."
        ),
        missingExecutableAuditReason: "antigravity_cli_not_found",
        missingExecutableStopReason: "missing_antigravity",
        usesLivePhaseForTimeoutAndMaxTurns: true
    )

    static let codex = ProviderRuntimeMessages(
        providerName: "Codex",
        missingExecutableStyle: .installAndAuthHint(
            providerName: "Codex",
            installAction: "Install Codex CLI",
            authAction: "authenticate with `codex login`."
        ),
        missingExecutableAuditReason: "codex_cli_not_found",
        missingExecutableStopReason: "missing_codex",
        usesLivePhaseForTimeoutAndMaxTurns: false
    )

    static let cursor = ProviderRuntimeMessages(
        providerName: "Cursor",
        missingExecutableStyle: .installAndAuthHint(
            providerName: "Cursor",
            installAction: "Install Cursor CLI",
            authAction: "authenticate with `cursor-agent login`."
        ),
        missingExecutableAuditReason: "cursor_cli_not_found",
        missingExecutableStopReason: "missing_cursor",
        usesLivePhaseForTimeoutAndMaxTurns: false
    )

    static let openCode = ProviderRuntimeMessages(
        providerName: "OpenCode",
        missingExecutableStyle: .installAndAuthHint(
            providerName: "OpenCode",
            installAction: "Install OpenCode",
            authAction: "authenticate with `opencode auth login`."
        ),
        missingExecutableAuditReason: "opencode_cli_not_found",
        missingExecutableStopReason: "missing_opencode",
        usesLivePhaseForTimeoutAndMaxTurns: false
    )

    func missingExecutableMessage(executablePath: String, displayName: String) -> String {
        switch missingExecutableStyle {
        case .resolvedPath:
            return ProviderMessages.missingExecutableAtPath(providerName: displayName, executablePath: executablePath)
        case .installAndAuthHint(let providerName, let installAction, let authAction):
            return ProviderMessages.missingExecutable(
                providerName: providerName,
                installAction: installAction,
                authAction: authAction
            )
        }
    }

    func defaultStartEventPayload(goal: String) -> String {
        ProviderMessages.start(providerName: providerName, goal: goal)
    }

    func manualCompletionPayload(phase: RunPhase) -> String {
        ProviderMessages.manualCompletion(providerName: providerName, phase: phase)
    }

    func failurePayloadPrefix(phase: RunPhase, exitCode: Int) -> String {
        ProviderMessages.failurePrefix(providerName: providerName, phase: phase, exitCode: exitCode)
    }

    func timeoutPayload(phase: RunPhase, timeoutSeconds: TimeInterval) -> String {
        ProviderMessages.timeout(
            phase: usesLivePhaseForTimeoutAndMaxTurns ? phase : .run,
            timeoutSeconds: timeoutSeconds
        )
    }

    func maxTurnsPayload(phase: RunPhase, maxTurns: Int) -> String {
        ProviderMessages.maxTurns(
            phase: usesLivePhaseForTimeoutAndMaxTurns ? phase : .run,
            maxTurns: maxTurns
        )
    }

    /// `sessionTurnMessage` for the CLI-style adapters (Copilot, Antigravity,
    /// Codex, Cursor, OpenCode): prefers the start payload once a prompt
    /// override is present, otherwise falls back to the task goal. Claude
    /// Code does not use this helper — its default keeps preferring
    /// `sessionMessage` (see `AgentRuntimePostRunDiagnostics`'s extension).
    func sessionTurnMessage(task: AgentTask, promptOverride: String?, startPayload: String?) -> String {
        promptOverride == nil ? task.goal : (startPayload ?? task.goal)
    }
}
