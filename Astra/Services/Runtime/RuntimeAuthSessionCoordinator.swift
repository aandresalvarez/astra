import AppKit
import AstraObjCSupport
import Foundation
import ASTRACore
import os

/// Seam over "run this command in the user's Terminal" so sign-in flows
/// are unit-testable and the Apple Events path can degrade gracefully.
protocol TerminalCommandLaunching: Sendable {
    /// Launches `command` in Terminal.app via scripting. Throws when
    /// Automation permission is denied or scripting fails. MainActor
    /// because NSAppleScript is documented main-thread-only.
    @MainActor func launchInTerminal(command: String) throws
    /// Fallback: bring Terminal forward without scripting (the user
    /// pastes the command themselves).
    func openTerminalApp()
}

struct TerminalLaunchError: Error, Equatable {
    let reason: String
}

/// Real launcher: `tell application "Terminal" to do script …` through
/// NSAppleScript. The app already holds the
/// `com.apple.security.automation.apple-events` entitlement; the first
/// call still triggers a one-time macOS consent prompt, and a denial
/// surfaces here as a thrown error so callers fall back to copy/paste.
struct TerminalAppLauncher: TerminalCommandLaunching {
    @MainActor
    func launchInTerminal(command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalLaunchError(reason: "Could not build the Terminal script.")
        }
        // OSA bridging can raise NSException; route through the Obj-C trap
        // so a raise degrades to the copy/paste fallback instead of aborting.
        let raised = AstraExceptionTrap.catching {
            _ = script.executeAndReturnError(&errorInfo)
        }
        if let raised {
            throw TerminalLaunchError(reason: raised.reason ?? "AppleScript raised \(raised.name.rawValue).")
        }
        if let errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
            throw TerminalLaunchError(reason: message)
        }
    }

    func openTerminalApp() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }
}

/// How the sign-in command reached the user.
enum RuntimeAuthLaunchMethod: Equatable, Sendable {
    /// Terminal opened with the command already running.
    case scriptedTerminal
    /// Scripting unavailable — Terminal opened empty; the caller should
    /// copy the command to the pasteboard and tell the user to paste it.
    case manualCopy(reason: String)
}

enum RuntimeAuthSessionPhase: Equatable, Sendable {
    case launched(RuntimeAuthLaunchMethod)
    case waitingForSignIn
    /// Emitted after every poll tick so the UI can show "Last check Xs
    /// ago: still no credentials" — without this the user sees a spinner
    /// for up to 5 minutes with no feedback.
    case polled(elapsed: Int, observation: String)
}

enum RuntimeAuthSessionOutcome: Equatable, Sendable {
    /// The verification probe confirmed an authenticated session.
    case verified
    /// Provider has no local probe; treat as signed in but unverified.
    case deferred(note: String)
    /// Provider verification is on-demand only (Antigravity).
    case manual(note: String)
    /// The installed CLI version does not support the status probe;
    /// treat as unverified rather than signed out.
    case probeUnsupported(note: String)
    /// Polling hit the time cap without a confirmed session.
    case timedOut
    case failed(String)
    case cancelled
}

struct RuntimeAuthSessionRequest: Sendable {
    let runtime: AgentRuntimeID
    /// Resolved path of the runtime's own binary (probe target when the
    /// remediation does not override the probe binary).
    let executablePath: String
    let remediation: RuntimeAuthRemediation
}

/// Drives one sign-in session: hands the login command to Terminal, then
/// polls the provider's read-only status command until the session is
/// confirmed, the time cap expires, or the caller cancels. Owned by
/// `RuntimeSetupModel`, which enforces the one-active-session invariant
/// and renders the published phases.
struct RuntimeAuthSessionRunner: Sendable {
    var launcher: any TerminalCommandLaunching = TerminalAppLauncher()
    var probeRunner: any BinaryRunner = ProcessBinaryRunner()
    var detectExecutable: @Sendable (String) -> String = {
        RuntimePathResolver.detectExecutablePath(named: $0)
    }
    /// Browser OAuth flows routinely take minutes; cap generously.
    var maxDuration: TimeInterval = 300
    var pollInterval: TimeInterval = 5
    var probeTimeout: TimeInterval = 5
    /// Cold-start Node CLIs flap; require two clean confirmations.
    var requiredConsecutiveSuccesses = 2
    var sleep: @Sendable (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ASTRA",
        category: "runtime-auth"
    )

    func run(
        _ request: RuntimeAuthSessionRequest,
        onPhase: @escaping @Sendable (RuntimeAuthSessionPhase) async -> Void
    ) async -> RuntimeAuthSessionOutcome {
        do {
            try await launcher.launchInTerminal(command: request.remediation.terminalCommand)
            await onPhase(.launched(.scriptedTerminal))
            Self.log.info("auth session launched runtime=\(request.runtime.rawValue, privacy: .public) method=scripted")
        } catch {
            let reason = (error as? TerminalLaunchError)?.reason ?? error.localizedDescription
            launcher.openTerminalApp()
            await onPhase(.launched(.manualCopy(reason: reason)))
            Self.log.info("auth session launched runtime=\(request.runtime.rawValue, privacy: .public) method=manual-copy")
        }

        switch request.remediation.verification {
        case .deferredToTaskStart(let note):
            return .deferred(note: note)
        case .manualRecheck(let note):
            return .manual(note: note)
        case .probe:
            return await pollUntilVerified(request, onPhase: onPhase)
        }
    }

    /// Single-shot verification — the Check Now button and the
    /// app-did-become-active re-check both use this.
    func verifyOnce(_ request: RuntimeAuthSessionRequest) async -> RuntimeAuthProbeEvaluation {
        await evaluateProbe(request)
    }

    private func pollUntilVerified(
        _ request: RuntimeAuthSessionRequest,
        onPhase: @escaping @Sendable (RuntimeAuthSessionPhase) async -> Void
    ) async -> RuntimeAuthSessionOutcome {
        var elapsed: TimeInterval = 0
        var consecutiveSuccesses = 0

        while elapsed < maxDuration {
            if Task.isCancelled { return .cancelled }
            do {
                try await sleep(pollInterval)
            } catch {
                return .cancelled
            }
            elapsed += pollInterval

            let evaluation = await evaluateProbe(request)
            Self.log.info("auth poll tick runtime=\(request.runtime.rawValue, privacy: .public) elapsed=\(Int(elapsed))s result=\(String(describing: evaluation), privacy: .public)")
            await onPhase(.polled(elapsed: Int(elapsed), observation: Self.observation(for: evaluation, runtime: request.runtime)))
            switch evaluation {
            case .authenticated:
                consecutiveSuccesses += 1
                if consecutiveSuccesses >= requiredConsecutiveSuccesses {
                    Self.log.info("auth session verified runtime=\(request.runtime.rawValue, privacy: .public) after=\(Int(elapsed))s")
                    return .verified
                }
            case .signedOut:
                consecutiveSuccesses = 0
            case .indeterminate:
                // Probe timed out or flaked — neither confirm nor reset.
                break
            case .unsupported(let note):
                Self.log.warning("auth probe unsupported runtime=\(request.runtime.rawValue, privacy: .public)")
                return .probeUnsupported(note: note)
            case .missingBinary(let detail):
                return .failed(detail)
            }
        }
        Self.log.warning("auth session timed out runtime=\(request.runtime.rawValue, privacy: .public)")
        return .timedOut
    }

    func evaluateProbe(_ request: RuntimeAuthSessionRequest) async -> RuntimeAuthProbeEvaluation {
        guard case .probe(let binaryOverride, let args, let semantic) = request.remediation.verification else {
            return .unsupported(note: "No status probe for \(request.runtime.displayName).")
        }

        let path: String
        if let binaryOverride {
            path = detectExecutable(binaryOverride)
            guard !path.isEmpty else {
                return .missingBinary("\(binaryOverride) was not found on this Mac.")
            }
        } else {
            path = request.executablePath
            guard !path.isEmpty else {
                return .missingBinary("\(request.runtime.displayName) executable is not configured.")
            }
        }

        // Pin the locale: the authenticated-session heuristic matches
        // English substrings, and a localized CLI would otherwise spin the
        // poll loop to its time cap on non-English systems.
        let environment = RuntimeProcessEnvironment.enriched(extraVariables: [
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1"
        ])
        let result = await probeRunner.run(
            path: path,
            args: args,
            timeout: probeTimeout,
            environment: environment
        )

        switch result.outcome {
        case .timedOut, .cancelled:
            return .indeterminate
        case .launchFailed(let reason):
            return .missingBinary(reason)
        case .exited:
            break
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let authenticated: Bool
        switch semantic {
        case .authenticatedSession:
            authenticated = result.isSuccess && RuntimeReadinessDiagnostics.showsAuthenticatedSession(output)
        case .configuredCredentials:
            authenticated = result.isSuccess && OpenCodeCLIRuntime.authListShowsConfiguredCredentials(output)
        case .nonEmptyStdout:
            authenticated = result.isSuccess
                && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if authenticated { return .authenticated }

        // An older CLI without the status subcommand is indistinguishable
        // from "signed out" by exit code alone — without this check the
        // poll loop would run to its cap and blame the user.
        if !result.isSuccess, Self.looksLikeUnsupportedProbe(output) {
            return .unsupported(
                note: "\(request.runtime.displayName) does not support its sign-in status command on this version. Update the CLI, or continue and let the first task confirm the account."
            )
        }
        return .signedOut
    }

    /// One-line "last we saw" string for the UI status — keeps the
    /// terminology aligned with what the user's terminal would show.
    static func observation(for evaluation: RuntimeAuthProbeEvaluation, runtime: AgentRuntimeID) -> String {
        switch evaluation {
        case .authenticated: return "\(runtime.displayName) reports an authenticated session."
        case .signedOut:
            if runtime == .openCodeCLI { return "Still no credentials. Finish `opencode auth login` in Terminal." }
            return "Still signed out. Finish the sign-in in Terminal."
        case .indeterminate: return "Probe didn't complete in time — retrying."
        case .unsupported: return "This CLI version doesn't expose a status probe."
        case .missingBinary(let detail): return detail
        }
    }

    static func looksLikeUnsupportedProbe(_ output: String) -> Bool {
        let lower = output.lowercased()
        // Negative auth phrasing means the probe worked and the user is
        // signed out — never classify that as unsupported.
        if ["not logged in", "not authenticated", "not signed in", "logged out", "login required"]
            .contains(where: lower.contains) {
            return false
        }
        return ["unknown command", "unknown subcommand", "unrecognized subcommand",
                "unexpected argument", "invalid subcommand", "no such command"]
            .contains(where: lower.contains)
    }
}

enum RuntimeAuthProbeEvaluation: Equatable, Sendable {
    case authenticated
    case signedOut
    case indeterminate
    case unsupported(note: String)
    case missingBinary(String)
}
