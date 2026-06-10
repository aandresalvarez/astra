import Foundation
import ASTRACore

/// How ASTRA can get a missing runtime installed.
enum RuntimeInstallRemediation: Equatable {
    /// The adapter publishes a managed install plan (npm/brew) that
    /// `RuntimeCLIInstaller` can run in-app. Whether a plan actually
    /// resolves still depends on the package manager being present —
    /// callers must fall back to `installURL` when `plan(for:)` is nil.
    case managed
    /// No safe in-app installer exists (the vendor only ships an
    /// interactive or curl|bash installer). Open the official page.
    case linkOnly(URL?)
}

/// How a sign-in launched by ASTRA gets verified afterwards.
enum RuntimeAuthVerification: Equatable {
    /// Re-run a read-only status command until it reports an
    /// authenticated session. `binary` overrides which executable is
    /// probed (nil = the runtime's own binary).
    case probe(binary: String?, args: [String], semantic: RuntimeAuthProbeSemantic)
    /// The provider has no safe local status probe; the account is
    /// validated when the first task starts.
    case deferredToTaskStart(note: String)
    /// Only a manual re-check makes sense — the cheapest reliable probe
    /// is expensive (e.g. Antigravity's live model call).
    case manualRecheck(note: String)
}

enum RuntimeAuthProbeSemantic: Equatable {
    /// Output must pass `RuntimeReadinessDiagnostics.showsAuthenticatedSession`.
    case authenticatedSession
    /// Output must list at least one credential (OpenCode `auth list`).
    case configuredCredentials
    /// Exit 0 with non-empty stdout is enough (gcloud ADC token).
    case nonEmptyStdout
}

struct RuntimeAuthRemediation: Equatable {
    /// Full command handed to Terminal, shell-quoted centrally.
    let terminalCommand: String
    /// Copyable command shown in the UI. Kept free of env exports so it
    /// reads like the vendor's documented login command.
    let displayCommand: String
    /// Extra step the login needs beyond running the command.
    let instruction: String?
    let verification: RuntimeAuthVerification
}

struct RuntimeRemediation: Equatable {
    let install: RuntimeInstallRemediation
    let auth: RuntimeAuthRemediation
}

/// Single machine-readable source for "what fixes this runtime": which
/// install path exists and which login command + verification probe to
/// use. The onboarding wizard's buttons render from this table instead of
/// prose hints, so every non-ready runtime has a functional action.
enum RuntimeRemediationCatalog {
    static func remediation(
        for runtime: AgentRuntimeID,
        claudeProvider: ClaudeProvider = .anthropic
    ) -> RuntimeRemediation {
        switch runtime {
        case .claudeCode:
            return RuntimeRemediation(install: .managed, auth: claudeAuth(provider: claudeProvider))
        case .copilotCLI:
            return RuntimeRemediation(
                install: .managed,
                auth: RuntimeAuthRemediation(
                    terminalCommand: "COPILOT_HOME=\(shellQuoted(CopilotCLIRuntime.channelHome())) copilot",
                    displayCommand: "copilot",
                    instruction: "Type /login when Copilot opens, then quit it. ASTRA keeps its own Copilot home, so a plain terminal login is not visible to tasks.",
                    verification: .deferredToTaskStart(
                        note: "Copilot confirms the account when your first task starts."
                    )
                )
            )
        case .antigravityCLI:
            return RuntimeRemediation(
                install: .linkOnly(installURL(for: runtime)),
                auth: RuntimeAuthRemediation(
                    terminalCommand: "agy",
                    displayCommand: "agy",
                    instruction: "Complete Google Sign-In in your browser, then return to ASTRA and use Verify.",
                    verification: .manualRecheck(
                        note: "Verifying Antigravity runs a short live check, so ASTRA only does it on demand."
                    )
                )
            )
        case .codexCLI:
            return RuntimeRemediation(
                install: .managed,
                auth: RuntimeAuthRemediation(
                    terminalCommand: "codex login",
                    displayCommand: "codex login",
                    instruction: "A browser window opens to finish the sign-in.",
                    verification: .probe(binary: nil, args: ["login", "status"], semantic: .authenticatedSession)
                )
            )
        case .cursorCLI:
            return RuntimeRemediation(
                install: .linkOnly(installURL(for: runtime)),
                auth: RuntimeAuthRemediation(
                    terminalCommand: "cursor-agent login",
                    displayCommand: "cursor-agent login",
                    instruction: "A browser window opens to finish the sign-in.",
                    verification: .probe(binary: nil, args: ["status"], semantic: .authenticatedSession)
                )
            )
        case .openCodeCLI:
            return RuntimeRemediation(
                install: .managed,
                auth: RuntimeAuthRemediation(
                    terminalCommand: "opencode auth login",
                    displayCommand: "opencode auth login",
                    instruction: "Pick your provider and paste an API key in Terminal.",
                    verification: .probe(binary: nil, args: ["auth", "list"], semantic: .configuredCredentials)
                )
            )
        default:
            // Future runtimes fall back to the descriptor's prose hints:
            // no managed install, login command from the docs page.
            return RuntimeRemediation(
                install: .linkOnly(installURL(for: runtime)),
                auth: RuntimeAuthRemediation(
                    terminalCommand: AgentRuntimeAdapterRegistry.descriptor(for: runtime).executableName,
                    displayCommand: AgentRuntimeAdapterRegistry.descriptor(for: runtime).executableName,
                    instruction: AgentRuntimeAdapterRegistry.descriptor(for: runtime).authHint,
                    verification: .manualRecheck(note: "Re-check after signing in.")
                )
            )
        }
    }

    /// `gh auth login` flow for the optional GitHub capability — same
    /// machinery as the runtimes, so the wizard's GitHub line can offer a
    /// working sign-in too.
    static var githubAuth: RuntimeAuthRemediation {
        RuntimeAuthRemediation(
            terminalCommand: "gh auth login",
            displayCommand: "gh auth login",
            instruction: nil,
            verification: .probe(
                binary: "gh",
                args: ["auth", "status", "--hostname", "github.com"],
                semantic: .authenticatedSession
            )
        )
    }

    static func installURL(for runtime: AgentRuntimeID) -> URL? {
        AgentRuntimeAdapterRegistry.descriptor(for: runtime).prerequisite.installURL
    }

    /// POSIX single-quote escaping: wraps in single quotes and escapes
    /// embedded single quotes as `'\''`. Used for every value ASTRA
    /// interpolates into a Terminal command (paths can contain spaces —
    /// "Application Support" — or quotes).
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func claudeAuth(provider: ClaudeProvider) -> RuntimeAuthRemediation {
        switch provider {
        case .anthropic:
            return RuntimeAuthRemediation(
                terminalCommand: "claude /login",
                displayCommand: "claude /login",
                instruction: "You can also set ANTHROPIC_API_KEY instead of signing in.",
                verification: .probe(binary: nil, args: ["auth", "status"], semantic: .authenticatedSession)
            )
        case .vertex:
            return RuntimeAuthRemediation(
                terminalCommand: "gcloud auth application-default login",
                displayCommand: "gcloud auth application-default login",
                instruction: "Claude routes through Vertex AI, so sign-in happens via Google Cloud ADC.",
                verification: .probe(
                    binary: "gcloud",
                    args: ["auth", "application-default", "print-access-token", "--quiet"],
                    semantic: .nonEmptyStdout
                )
            )
        }
    }
}
