import Foundation

/// Product-level classification of a CLI's state, derived from running
/// `which` + a liveness probe + an optional semantic check against stdout.
///
/// Four cases, in rough "pain" order:
///   - `healthy`       — binary resolves, liveness probe exits 0, and any
///                       semantic check passed. User can run the skill.
///   - `unauthenticated` — binary resolves and runs but a semantic probe
///                       (e.g. `gcloud auth list`) says no active identity.
///                       User needs to log in; the app can link to the fix.
///   - `unresponsive`  — binary resolves but the liveness probe timed out
///                       or exited non-zero. Often means broken install or
///                       hung background state.
///   - `missingBinary` — `which` / PATH scan returned nothing. User needs
///                       to install it.
public enum HealthStatus: Sendable, Equatable {
    case healthy(path: String, version: String)
    case unauthenticated(detail: String)
    case unresponsive(detail: String)
    case missingBinary
}

/// A semantic check inspects liveness stdout/stderr and returns whether the
/// binary is in a "good" state *beyond* simply exiting 0. Typical use:
/// `gcloud auth list --format=value(account)` exits 0 even when the user
/// has no active account — the output is just empty. Semantic checks catch
/// that.
///
/// Encoded as an enum (not a closure) so it can be stored in `Codable`
/// prerequisite specs. The checker resolves the enum to behaviour.
public enum SemanticCheck: String, Codable, Sendable, Equatable {
    /// Pass iff stdout, trimmed, is non-empty. Used for `gcloud auth list`
    /// and similar "lists the active principal" probes.
    case stdoutNonEmpty
    /// Pass iff stderr does NOT contain "Cannot connect" — catches
    /// `docker ps` when the daemon is off (binary is installed but the
    /// user still can't use it).
    case stderrNoDaemonError
}

/// Runs `which <binary>` then a liveness probe. Translates the runner's
/// `RunResult` into a `HealthStatus` a view / install wizard can show.
///
/// Design notes:
///   - We deliberately prefer `/usr/bin/env which` over a PATH-scan to
///     match the user's actual shell lookup behaviour (respects user
///     aliases via env, doesn't care whether `which` is a builtin).
///   - `/usr/bin/env` itself is guaranteed to exist on macOS. If it
///     doesn't, the machine is broken at a level we can't recover from.
///   - Liveness timeout default is short (3s). A binary that can't answer
///     `--version` in 3s is effectively unresponsive for interactive use.
public struct EnvironmentHealthChecker: Sendable {
    public static let defaultEnvPath = "/usr/bin/env"
    public static var defaultFallbackDirectories: [String] {
        [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.astra/tools",
            "/usr/bin"
        ]
    }

    private let runner: BinaryRunner
    private let envPath: String
    /// Explicit PATH to pass to `which`. Nil = inherit. Tests inject this.
    private let overridePath: String?
    private let fallbackDirectories: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        envPath: String = EnvironmentHealthChecker.defaultEnvPath,
        overridePath: String? = nil,
        fallbackDirectories: [String] = EnvironmentHealthChecker.defaultFallbackDirectories,
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.envPath = envPath
        self.overridePath = overridePath
        self.fallbackDirectories = fallbackDirectories
        self.isExecutable = isExecutable
    }

    /// Check a single binary. Order: resolve → liveness → semantic.
    /// Any failure short-circuits and maps to the most specific status.
    public func check(
        binary: String,
        livenessArgs: [String] = ["--version"],
        semantic: SemanticCheck? = nil,
        timeout: TimeInterval = 3
    ) async -> HealthStatus {
        // Step 1: resolve path via `env which <binary>`.
        let whichEnv: [String: String]? = overridePath.map { ["PATH": $0] }
        let whichResult = await runner.run(
            path: envPath,
            args: ["which", binary],
            timeout: timeout,
            environment: whichEnv
        )

        let whichPath = whichResult.isSuccess
            ? whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let resolved = whichPath.isEmpty
            ? fallbackExecutablePath(binary: binary)
            : whichPath
        guard !resolved.isEmpty else {
            return .missingBinary
        }

        // Step 2: liveness probe. Run the resolved binary directly so we're
        // not dependent on PATH for the second hop.
        let liveness = await runner.run(
            path: resolved,
            args: livenessArgs,
            timeout: timeout,
            environment: nil
        )

        switch liveness.outcome {
        case .launchFailed(let reason):
            // `which` returned a path, but we couldn't exec it. Rare, but
            // possible with broken symlinks or permission changes.
            return .unresponsive(detail: reason)
        case .timedOut:
            return .unresponsive(detail: "timed out after \(Int(timeout))s")
        case .exited(let code) where code != 0:
            let tail = liveness.stderr.isEmpty ? liveness.stdout : liveness.stderr
            return .unresponsive(detail: "exit \(code): \(tail.trimmed(max: 120))")
        case .exited:
            break  // clean exit, fall through to semantic check
        }

        let version = liveness.stdout
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            ?? ""

        // Step 3: optional semantic check.
        if let semantic {
            if !semantic.passes(stdout: liveness.stdout, stderr: liveness.stderr) {
                return .unauthenticated(
                    detail: semantic.failureDetail(stdout: liveness.stdout, stderr: liveness.stderr)
                )
            }
        }

        return .healthy(path: resolved, version: version)
    }

    private func fallbackExecutablePath(binary: String) -> String {
        for directory in fallbackDirectories {
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent(binary)
                .path
            if isExecutable(path) {
                return path
            }
        }
        return ""
    }
}

// MARK: - SemanticCheck interpretation

public extension SemanticCheck {
    func passes(stdout: String, stderr: String) -> Bool {
        switch self {
        case .stdoutNonEmpty:
            return !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stderrNoDaemonError:
            let lowered = stderr.lowercased()
            return !(lowered.contains("cannot connect")
                || lowered.contains("daemon is not running")
                || lowered.contains("is the docker daemon running"))
        }
    }

    func failureDetail(stdout: String, stderr: String) -> String {
        switch self {
        case .stdoutNonEmpty:
            return "no active account"
        case .stderrNoDaemonError:
            return "daemon unreachable"
        }
    }
}

// MARK: - String convenience

private extension String {
    func trimmed(max: Int) -> String {
        let oneLine = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max - 1)) + "…"
    }
}
