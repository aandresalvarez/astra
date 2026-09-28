import Foundation
import ASTRACore

extension AntigravityCLIRuntimeAdapter {
    /// How long `agy` itself waits on the model before giving up. It gives up
    /// first: it then exits 0 with empty stdout about two seconds later and
    /// names the timeout on stderr, which is no evidence about the account.
    static let liveCheckPrintTimeoutSeconds = 25
    /// ASTRA's own kill timer, the backstop when `agy` cannot stop itself. It
    /// sits above `liveCheckPrintTimeoutSeconds` plus `agy`'s exit lag so the
    /// CLI's own message can be read instead of always losing the race.
    static let liveCheckKillTimeoutSeconds: TimeInterval = 30

    func antigravityLiveAccountCheck(
        executable: String,
        providerHomeDirectory: String,
        authMode: AntigravityAuthMode,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let title = "Antigravity account"
        let args = [
            "--print",
            "Reply with ASTRA_READY only.",
            "--print-timeout",
            "\(Self.liveCheckPrintTimeoutSeconds)s",
            "--sandbox"
        ]
        var extraVars: [String: String] = [
            "NO_COLOR": "1",
            "AGY_CLI_HIDE_ACCOUNT_INFO": "1",
        ]
        let parentTerm = ProcessInfo.processInfo.environment["TERM"]
        extraVars["TERM"] = parentTerm ?? "xterm-256color"
        let environment = AntigravityCLIRuntime.probeEnvironment(
            mode: authMode,
            providerHomeDirectory: providerHomeDirectory,
            extraVariables: extraVars
        )

        let result = await probes.run(
            path: executable,
            args: args,
            timeout: Self.liveCheckKillTimeoutSeconds,
            environment: environment
        )
        if let unanswered = RuntimeReadinessCheck.inconclusiveProbe(
            id: "antigravity-account",
            title: title,
            result: result,
            timeout: Self.liveCheckKillTimeoutSeconds
        ) {
            return unanswered
        }
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "antigravity-account",
                title: title,
                detail: antigravityLiveAccountFailureDetail(result),
                state: .blocked,
                remediation: authMode != .adc
                    ? "Run `agy` in Terminal, complete Google Sign-In, then click Check Again."
                    : "Confirm `gcloud auth application-default login` (and `set-quota-project`) are set up, then click Check Again."
            )
        }
        if antigravityReadinessOutputContainsReadyLine(result.stdout) {
            return RuntimeReadinessCheck(
                id: "antigravity-account",
                title: title,
                detail: "Live non-interactive check completed with `agy --print --sandbox`.",
                state: .ready,
                remediation: nil
            )
        }
        if let unanswered = antigravityLiveCheckWithoutAnswer(result, title: title) {
            return unanswered
        }
        return RuntimeReadinessCheck(
            id: "antigravity-account",
            title: title,
            detail: antigravityLiveAccountEmptySuccessDetail(result),
            state: .blocked,
            remediation: "Run `agy --print 'Reply with ASTRA_READY only.' --print-timeout \(Self.liveCheckPrintTimeoutSeconds)s --sandbox` in Terminal and confirm it prints ASTRA_READY."
        )
    }

    func antigravityAccountDeferredCheck() -> RuntimeReadinessCheck {
        RuntimeReadinessCheck(
            id: "antigravity-account",
            title: "Antigravity account",
            detail: "CLI is available. Run Check Again in Settings for a live non-interactive account check.",
            state: .ready,
            remediation: nil
        )
    }

    private func antigravityReadinessOutputContainsReadyLine(_ stdout: String) -> Bool {
        stdout
            .components(separatedBy: .newlines)
            .contains { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "ASTRA_READY"
            }
    }

    /// `agy` exits 0 with nothing on stdout when its own print timeout fires,
    /// and also when it printed nothing at all. Neither shows the account is
    /// broken, so neither may block a launch. Anything else it said on a
    /// clean exit is left to the caller as evidence.
    private func antigravityLiveCheckWithoutAnswer(
        _ result: RunResult,
        title: String
    ) -> RuntimeReadinessCheck? {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.lowercased().contains("print timeout") {
            return RuntimeReadinessCheck.inconclusive(
                id: "antigravity-account",
                title: title,
                reason: "Antigravity stopped waiting for the model after \(Self.liveCheckPrintTimeoutSeconds)s"
            )
        }
        guard stdout.isEmpty, stderr.isEmpty else { return nil }
        return RuntimeReadinessCheck.inconclusive(
            id: "antigravity-account",
            title: title,
            reason: "the live check exited successfully but printed nothing"
        )
    }

    private func antigravityLiveAccountEmptySuccessDetail(_ result: RunResult) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = RuntimeReadinessRedactor.redacted(stdout.isEmpty ? stderr : stdout)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Live Antigravity check exited successfully but did not print ASTRA_READY: \(String(evidence.prefix(180)))"
    }

    /// Only reached for a process that ran to completion and failed; a
    /// timeout, launch failure, or cancellation is handled before this.
    private func antigravityLiveAccountFailureDetail(_ result: RunResult) -> String {
        let code = result.exitCode ?? -1
        let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
        let sanitized = RuntimeReadinessRedactor.redacted(evidence)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return "Live Antigravity check exited with status \(code)."
        }
        return "Live Antigravity check exited with status \(code): \(String(sanitized.prefix(180)))"
    }
}
