import Foundation
import ASTRACore

/// How aggressively ASTRA wraps provider CLI processes in a macOS Seatbelt
/// (`sandbox-exec`) profile.
///
/// - `off`: never wrap.
/// - `bestEffort`: wrap when the platform supports it; if the sandbox cannot be
///   applied (e.g. `sandbox-exec` missing, no execution path), log a fallback
///   and run unconfined rather than failing the task.
/// - `strict`: wrap always; if the sandbox cannot be applied, fail the run
///   closed instead of running unconfined.
enum ExecutionSandboxEnforcement: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case bestEffort = "best_effort"
    case strict

    var id: String { rawValue }

    /// Tolerant parser so an unknown/legacy stored value defaults to the safe
    /// best-effort behavior rather than silently disabling the sandbox.
    static func normalized(_ rawValue: String?) -> ExecutionSandboxEnforcement {
        guard let rawValue else { return .bestEffort }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "off", "disabled", "none":
            return .off
        case "strict", "enforced":
            return .strict
        case "best_effort", "besteffort", "default":
            return .bestEffort
        default:
            return ExecutionSandboxEnforcement(rawValue: normalized) ?? .bestEffort
        }
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .bestEffort: "Best effort"
        case .strict: "Strict"
        }
    }

    var helpText: String {
        switch self {
        case .off:
            "Agent processes run without an OS sandbox. Only ASTRA's in-app permission checks apply."
        case .bestEffort:
            "Confine agent file writes to the workspace using macOS Seatbelt. If the sandbox can't be applied, the run continues unconfined and is logged."
        case .strict:
            "Require the macOS Seatbelt sandbox. If it can't be applied, the run is blocked. Auto (autonomous) runs always use strict."
        }
    }
}

/// Resolved configuration for a single sandbox decision. Pure value type so the
/// decision logic is testable without touching `UserDefaults`.
struct ExecutionSandboxSettings: Sendable, Equatable {
    var enforcement: ExecutionSandboxEnforcement
    /// Runtimes ASTRA wraps with its own Seatbelt profile. Providers that ship a
    /// native OS sandbox (Codex, Cursor, Antigravity) are excluded by default to
    /// avoid double-confinement breakage; they enforce via their own flags.
    var wrappedRuntimes: Set<AgentRuntimeID>
    /// Whether the profile permits outbound network. The provider CLI itself
    /// makes the model-API calls, so this stays `true` for normal runs; set
    /// `false` only for an explicit offline/locked mode.
    var allowNetwork: Bool

    /// Providers without a native OS sandbox today — wrapped by default.
    static let defaultWrappedRuntimes: Set<AgentRuntimeID> = [.claudeCode, .copilotCLI]

    /// Providers that ship their own OS sandbox (enforced via per-run flags).
    /// Excluded by default to avoid double-confinement breakage; the user can
    /// opt in to layer ASTRA's Seatbelt over them for defense-in-depth.
    static let nativeSandboxRuntimes: Set<AgentRuntimeID> = [.codexCLI, .cursorCLI, .antigravityCLI]

    /// Single source of truth for the unset-defaults behavior. `current(...)`
    /// (which reads `UserDefaults`) and the `SettingsView` `@AppStorage`
    /// declarations both derive their defaults from these, so the resolved
    /// behavior and the UI's initial state cannot drift apart.
    static let defaultEnforcement: ExecutionSandboxEnforcement = .bestEffort
    static let defaultAllowNetwork = true
    static let defaultLayerNativeProviders = false

    init(
        enforcement: ExecutionSandboxEnforcement,
        wrappedRuntimes: Set<AgentRuntimeID> = ExecutionSandboxSettings.defaultWrappedRuntimes,
        allowNetwork: Bool = true
    ) {
        self.enforcement = enforcement
        self.wrappedRuntimes = wrappedRuntimes
        self.allowNetwork = allowNetwork
    }

    func shouldWrap(runtime: AgentRuntimeID) -> Bool {
        enforcement != .off && wrappedRuntimes.contains(runtime)
    }

    /// Builds settings from persisted defaults.
    ///
    /// - Enforcement defaults to best-effort; broad-permission (`autonomous`)
    ///   runs are escalated to strict so the most dangerous mode always has a
    ///   kernel boundary.
    /// - Network is allowed by default (the CLI needs its model API); turning it
    ///   off produces an offline profile.
    /// - Self-sandboxing providers are only wrapped when the user opts in to
    ///   layering.
    static func current(
        permissionPolicy: PermissionPolicy,
        defaults: UserDefaults = .standard
    ) -> ExecutionSandboxSettings {
        var enforcement = ExecutionSandboxEnforcement.normalized(
            defaults.string(forKey: AppStorageKeys.sandboxEnforcement)
        )
        if enforcement == .bestEffort, permissionPolicy == .autonomous {
            enforcement = .strict
        }

        // Network is allowed unless an explicit Bool `false` is stored. A
        // non-Bool / corrupt value falls back to the default (network on) — a
        // deliberate fail-open so a damaged preference can't silently sever the
        // CLI's model API; the offline control is a user-set Bool toggle.
        let allowNetwork = defaults.object(forKey: AppStorageKeys.sandboxAllowNetwork) as? Bool ?? defaultAllowNetwork
        let layerNative = defaults.object(forKey: AppStorageKeys.sandboxLayerNativeProviders) as? Bool ?? defaultLayerNativeProviders

        var wrappedRuntimes = defaultWrappedRuntimes
        if layerNative {
            wrappedRuntimes.formUnion(nativeSandboxRuntimes)
        }

        return ExecutionSandboxSettings(
            enforcement: enforcement,
            wrappedRuntimes: wrappedRuntimes,
            allowNetwork: allowNetwork
        )
    }
}

/// Outcome of a sandbox-wrapping decision. The caller (the process runner) owns
/// the side effects — auditing and turning `failClosed` into a process result —
/// while this type stays pure and testable.
enum ExecutionSandboxDecision: Equatable {
    /// Sandbox applied. `plan` is the rewritten launch plan whose executable is
    /// `sandbox-exec`. `writableRoots` is the canonical write allowlist (for
    /// auditing).
    case applied(plan: AgentRuntimeProcessLaunchPlan, writableRoots: [String])
    /// Sandbox intentionally not applied (disabled, runtime excluded,
    /// unsupported platform). Run the original plan unchanged.
    case skipped(reason: String)
    /// Sandbox wanted but could not be applied under best-effort. Run the
    /// original plan unchanged and surface a warning.
    case fallback(reason: String)
    /// Sandbox wanted but could not be applied under strict enforcement. The
    /// run must not proceed unconfined.
    case failClosed(reason: String)
}

/// Wraps provider CLI launches in a macOS Seatbelt profile that confines
/// filesystem writes to an allowlist anchored on the task's execution
/// directory, while leaving reads broad and (by default) network open.
///
/// The single integration point is `decide(plan:providerHomeDirectory:settings:)`,
/// called from `AgentRuntimeProcessRunner` between launch-plan creation and
/// process construction. When wrapping applies, the returned plan's executable
/// becomes `/usr/bin/sandbox-exec` and the original executable + args are
/// appended after the profile and `-D` parameters.
///
/// Design notes (see docs/specs/2026-06-06-seatbelt-execution-sandbox-plan.md):
/// - Writable paths are passed as `sandbox-exec -D` parameters and referenced in
///   the profile via `(param "...")`, never string-interpolated, so a path
///   containing a quote/paren/space cannot break or escape the profile.
/// - Paths are canonicalized (tilde expanded, symlinks/firmlinks resolved to the
///   `/private` form the kernel matches against) before being trusted as roots.
/// - The profile is `(allow default)` + `(deny file-write*)` + scoped
///   re-allows. Reads stay broad because agents must read the system toolchain;
///   the security boundary is write-scoping, mirroring Codex's `workspace-write`.
enum ExecutionSandbox {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Directories under the provider HOME that CLIs need to write (config,
    /// session, and cache state). Without these the provider breaks on launch.
    static let homeWritableRelativePaths: [String] = [
        ".claude",
        ".claude.json",
        ".config",
        ".cache",
        ".codex",
        ".cursor",
        ".gemini",
        ".antigravity",
        ".npm",
        ".local/share",
        ".local/state",
        "Library/Caches"
    ]

    // MARK: - Decision

    static func decide(
        plan: AgentRuntimeProcessLaunchPlan,
        providerHomeDirectory: String,
        settings: ExecutionSandboxSettings,
        fileManager: FileManager = .default
    ) -> ExecutionSandboxDecision {
        guard settings.enforcement != .off else {
            return .skipped(reason: "disabled")
        }
        guard settings.shouldWrap(runtime: plan.runtime) else {
            return .skipped(reason: "runtime_excluded")
        }

        let unavailable: (String) -> ExecutionSandboxDecision = { reason in
            settings.enforcement == .strict ? .failClosed(reason: reason) : .fallback(reason: reason)
        }

        guard let workspace = canonicalize(plan.currentDirectory), !workspace.isEmpty else {
            return unavailable("no_execution_path")
        }
        // A workspace that canonicalizes to `/` or a top-level system root would
        // make most of the filesystem writable — a no-op sandbox that still
        // reports "OS Sandboxed". Refuse to anchor on it (fail closed under
        // strict, fall back under best-effort) rather than ship a false boundary.
        guard !isOverlyBroadRoot(workspace) else {
            return unavailable("unsafe_execution_path")
        }
        guard fileManager.isExecutableFile(atPath: sandboxExecPath) else {
            return unavailable("sandbox_exec_missing")
        }

        let roots = writableRoots(
            plan: plan,
            providerHomeDirectory: providerHomeDirectory,
            canonicalWorkspace: workspace
        )
        // Defense-in-depth: `writableRoots` always seeds at least the workspace
        // and `/tmp`, so this is currently unreachable — but it keeps the
        // invariant explicit (never wrap with an empty allowlist, which would
        // produce an all-writes-denied profile) if that derivation ever changes.
        guard !roots.isEmpty else {
            return unavailable("no_writable_roots")
        }

        let profile = makeProfile(writableRootCount: roots.count, allowNetwork: settings.allowNetwork)
        let arguments = makeArguments(
            profile: profile,
            writableRoots: roots,
            executablePath: plan.executablePath,
            arguments: plan.arguments
        )
        let wrapped = rewrite(plan, executablePath: sandboxExecPath, arguments: arguments)
        return .applied(plan: wrapped, writableRoots: roots)
    }

    // MARK: - Safety guards

    /// Canonical roots too broad to anchor a write sandbox: granting any of
    /// these as the writable workspace subpath would make most of the
    /// filesystem writable, silently defeating the boundary. Compared against
    /// the already-canonicalized (`/private`-normalized) workspace path.
    static let overlyBroadRoots: Set<String> = [
        "/",
        "/private", "/private/var", "/private/tmp", "/private/etc",
        "/var", "/tmp", "/etc",
        "/usr", "/bin", "/sbin", "/opt", "/cores",
        "/System", "/Library", "/Applications",
        "/Users", "/Volumes", "/Network", "/dev"
    ]

    /// Whether `canonicalRoot` is too broad to safely anchor the write
    /// allowlist (the filesystem root or a well-known top-level system root).
    static func isOverlyBroadRoot(_ canonicalRoot: String) -> Bool {
        overlyBroadRoots.contains(canonicalRoot)
    }

    /// Cheap, plan-free prediction of whether `decide(...)` would actually apply
    /// the sandbox for a run anchored on `workspacePath`. The preflight manifest
    /// uses this so the declared `osSandboxed` tier reflects reality —
    /// enforcement on, a usable non-broad workspace, and `sandbox-exec` present —
    /// rather than mere intent. It cannot see launch-time races (e.g.
    /// `sandbox-exec` removed between preflight and launch); those are audited at
    /// launch.
    static func willLikelyApply(
        workspacePath: String,
        settings: ExecutionSandboxSettings,
        fileManager: FileManager = .default
    ) -> Bool {
        guard settings.enforcement != .off else { return false }
        guard let workspace = canonicalize(workspacePath),
              !workspace.isEmpty,
              !isOverlyBroadRoot(workspace) else { return false }
        return fileManager.isExecutableFile(atPath: sandboxExecPath)
    }

    // MARK: - Writable roots

    static func writableRoots(
        plan: AgentRuntimeProcessLaunchPlan,
        providerHomeDirectory: String,
        canonicalWorkspace: String
    ) -> [String] {
        var raw: [String] = [canonicalWorkspace]
        raw.append(contentsOf: plan.directoriesToCreate)

        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            raw.append(trimmedHome)
        }

        let home = effectiveHome(plan: plan, providerHomeDirectory: trimmedHome)
        if !home.isEmpty {
            for relative in homeWritableRelativePaths {
                raw.append((home as NSString).appendingPathComponent(relative))
            }
        }

        if let tmp = plan.environment["TMPDIR"], !tmp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw.append(tmp)
        }
        raw.append("/tmp")

        var seen: Set<String> = []
        return raw.compactMap { canonicalize($0) }.filter { seen.insert($0).inserted }
    }

    /// The HOME the spawned CLI will actually see: an explicit provider home if
    /// configured, otherwise the HOME baked into the launch environment, falling
    /// back to the process home.
    static func effectiveHome(plan: AgentRuntimeProcessLaunchPlan, providerHomeDirectory: String) -> String {
        if !providerHomeDirectory.isEmpty {
            return providerHomeDirectory
        }
        if let envHome = plan.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            return envHome
        }
        return NSHomeDirectory()
    }

    // MARK: - Profile generation

    /// Generates the Seatbelt profile. Writable roots are referenced positionally
    /// as `(param "ROOT_<i>")` so the actual paths are supplied out-of-band via
    /// `sandbox-exec -D` and never interpolated into this text.
    static func makeProfile(writableRootCount: Int, allowNetwork: Bool) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)"
        ]
        if !allowNetwork {
            lines.append("(deny network*)")
        }
        // Deny all writes, then re-allow the scoped roots. Last match wins in
        // SBPL, so the scoped allow below overrides this blanket deny.
        lines.append("(deny file-write*)")

        var allow: [String] = ["(allow file-write*"]
        for index in 0..<writableRootCount {
            allow.append("    (subpath (param \"\(rootParameterName(index))\"))")
        }
        // Device nodes (ptys, /dev/null, etc.) — provider-spawned shells need
        // these and they are not user data.
        allow.append("    (subpath \"/dev\"))")
        lines.append(contentsOf: allow)

        return lines.joined(separator: "\n") + "\n"
    }

    static func rootParameterName(_ index: Int) -> String {
        "ROOT_\(index)"
    }

    /// Assembles the full `sandbox-exec` argument vector:
    /// `-p <profile> -D ROOT_0=<path> ... <realExecutable> <realArgs...>`.
    static func makeArguments(
        profile: String,
        writableRoots: [String],
        executablePath: String,
        arguments: [String]
    ) -> [String] {
        var result: [String] = ["-p", profile]
        for (index, root) in writableRoots.enumerated() {
            result.append("-D")
            result.append("\(rootParameterName(index))=\(root)")
        }
        result.append(executablePath)
        result.append(contentsOf: arguments)
        return result
    }

    // MARK: - Path canonicalization

    /// Expands `~`, resolves symlinks, and normalizes macOS firmlinks
    /// (`/var`, `/tmp`, `/etc`) to the `/private` form the sandbox kernel matches
    /// against. Returns `nil` for empty input.
    static func canonicalize(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // An interior newline is never a legitimate path and would be dangerous
        // as a sandbox parameter value — reject rather than canonicalize it.
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var resolved = (expanded as NSString).resolvingSymlinksInPath

        // A relative path cannot anchor a kernel subpath rule; reject it instead
        // of passing a meaningless `-D` value that would silently confine nothing.
        guard resolved.hasPrefix("/") else { return nil }

        // `resolvingSymlinksInPath` may strip a leading `/private`, but the
        // kernel evaluates the `/private`-prefixed real path. Re-add it for the
        // known firmlinks so subpath matching lines up.
        for firmlink in ["/var", "/tmp", "/etc"] where resolved == firmlink || resolved.hasPrefix(firmlink + "/") {
            resolved = "/private" + resolved
            break
        }
        return resolved
    }

    // MARK: - Plan rewriting

    private static func rewrite(
        _ plan: AgentRuntimeProcessLaunchPlan,
        executablePath: String,
        arguments: [String]
    ) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: plan.runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: plan.currentDirectory,
            environment: plan.environment,
            browserShimDirectory: plan.browserShimDirectory,
            providerVersion: plan.providerVersion,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: plan.directoriesToCreate,
            providerDetectedFields: plan.providerDetectedFields,
            commandPlannedFields: plan.commandPlannedFields
        )
    }
}
