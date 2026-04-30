import Foundation

/// Declares that a plugin package (skill, connector, tool) needs a local
/// CLI to be installed, reachable, and in a usable state before the user
/// can expect it to work.
///
/// Used by the plugin catalog to render preflight badges ("✓ gcloud
/// found") and by the onboarding wizard to surface actionable remediation
/// instead of a raw "command not found" at task runtime.
///
/// Kept `Codable` so built-in specs can be serialised into seeded catalog
/// JSON later if desired. The semantic check is an enum (not a closure)
/// for the same reason.
public struct CLIPrerequisite: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity: we key caches on `binary`, so two specs for the
    /// same binary share a result. The struct's `id` is a synthesised
    /// composite so SwiftUI lists can key on it if they want per-package
    /// rendering.
    public var id: String { "\(binary):\(livenessArgs.joined(separator: " "))" }

    /// Short binary name as it should appear on PATH, e.g. `gcloud`,
    /// `docker`, `claude`.
    public var binary: String

    /// Arguments for the liveness probe, usually `["--version"]`.
    public var livenessArgs: [String]

    /// Optional second-level probe. `nil` = exit-0 is sufficient.
    public var semantic: SemanticCheck?

    /// Customer-facing label, e.g. "Google Cloud CLI".
    public var displayName: String

    /// One-line explanation of why the package needs it, e.g.
    /// "Used to manage GCP resources and auth." Shown under the badge.
    public var purpose: String

    /// Where to install it. A URL the user can click.
    public var installURL: URL?

    /// One-line install hint, typically a copy-pasteable shell command,
    /// e.g. "`brew install --cask google-cloud-sdk`" or "Download the
    /// Docker Desktop installer". Markdown is allowed.
    public var installHint: String

    /// If the semantic check surfaces `.unauthenticated`, this is the
    /// follow-up command the user should run, e.g. "`gcloud auth login`".
    /// `nil` = no specific fix beyond install.
    public var authHint: String?

    public init(
        binary: String,
        livenessArgs: [String] = ["--version"],
        semantic: SemanticCheck? = nil,
        displayName: String,
        purpose: String,
        installURL: URL? = nil,
        installHint: String = "",
        authHint: String? = nil
    ) {
        self.binary = binary
        self.livenessArgs = livenessArgs
        self.semantic = semantic
        self.displayName = displayName
        self.purpose = purpose
        self.installURL = installURL
        self.installHint = installHint
        self.authHint = authHint
    }
}

// MARK: - Common built-ins

/// Ready-made specs for the CLIs the app is opinionated about. Defined
/// here (not next to the plugin packages) because the Claude CLI itself
/// is a prereq of *every* task, not just one package — onboarding
/// consumes the same spec.
public enum CommonCLIPrerequisites {
    public static let claude = CLIPrerequisite(
        binary: "claude",
        livenessArgs: ["--version"],
        displayName: "Claude Code CLI",
        purpose: "Runs every task. ASTRA is a front-end for claude-code.",
        installURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup"),
        installHint: "Install via npm: `npm install -g @anthropic-ai/claude-code`",
        authHint: "Run `claude /login` or set `ANTHROPIC_API_KEY`."
    )

    public static let copilot = CLIPrerequisite(
        binary: "copilot",
        livenessArgs: ["--version"],
        displayName: "GitHub Copilot CLI",
        purpose: "Runs tasks through the user's GitHub Copilot subscription.",
        installURL: URL(string: "https://github.com/features/copilot/cli"),
        installHint: "Install via Homebrew: `brew install copilot-cli` or npm: `npm install -g @github/copilot`",
        authHint: "Run `copilot` and use `/login`, or set a GitHub token with Copilot access."
    )

    public static let githubCLI = CLIPrerequisite(
        binary: "gh",
        displayName: "GitHub CLI",
        purpose: "Runs GitHub commands for repository workflows.",
        installURL: URL(string: "https://cli.github.com/"),
        installHint: "Install via Homebrew: `brew install gh`",
        authHint: "Run `gh auth login`."
    )

    public static let githubAuth = CLIPrerequisite(
        binary: "gh",
        livenessArgs: ["auth", "status"],
        displayName: "GitHub login",
        purpose: "An authenticated GitHub CLI session is required for issues, pull requests, and Actions.",
        installHint: "Run `gh auth login`.",
        authHint: "Run `gh auth login`."
    )

    public static let gcloud = CLIPrerequisite(
        binary: "gcloud",
        livenessArgs: ["--version"],
        semantic: nil,
        displayName: "Google Cloud CLI",
        purpose: "Invokes GCP APIs for the Google Cloud skill.",
        installURL: URL(string: "https://cloud.google.com/sdk/docs/install"),
        installHint: "Install via Homebrew: `brew install --cask google-cloud-sdk`",
        authHint: "Run `gcloud auth login` to sign in."
    )

    /// Second spec for the auth state — separate entry so the catalog
    /// renders "installed ✓, not authenticated ⚠" as two distinct lines
    /// and each has its own remediation link.
    public static let gcloudAuth = CLIPrerequisite(
        binary: "gcloud",
        livenessArgs: ["auth", "list", "--format=value(account)"],
        semantic: .stdoutNonEmpty,
        displayName: "Google Cloud login",
        purpose: "At least one active account is required for API calls.",
        installURL: nil,
        installHint: "",
        authHint: "Run `gcloud auth login` to sign in."
    )

    public static let docker = CLIPrerequisite(
        binary: "docker",
        livenessArgs: ["version", "--format", "{{.Client.Version}}"],
        semantic: .stderrNoDaemonError,
        displayName: "Docker",
        purpose: "Talks to the local Docker daemon for Docker-based workflows.",
        installURL: URL(string: "https://docs.docker.com/desktop/install/mac-install/"),
        installHint: "Install Docker Desktop and make sure it's running.",
        authHint: "Start Docker Desktop if the daemon is unreachable."
    )
}
