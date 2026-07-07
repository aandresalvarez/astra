import Foundation
import ASTRACore
import ASTRAPersistence
import ASTRAModels

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

/// How the Seatbelt profile treats filesystem reads. This is intentionally
/// separate from `ExecutionSandboxEnforcement`: Best Effort can audit read-scope
/// misses without breaking provider runs, while Strict always enforces them.
enum ExecutionSandboxReadScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case open
    case audit
    case enforce

    var id: String { rawValue }

    static func normalized(_ rawValue: String?) -> ExecutionSandboxReadScope {
        guard let rawValue else { return .audit }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "open", "write_only", "writeonly", "off", "disabled":
            return .open
        case "audit", "report", "observe", "monitor":
            return .audit
        case "enforce", "enforced", "strict":
            return .enforce
        default:
            return ExecutionSandboxReadScope(rawValue: normalized) ?? .audit
        }
    }

    var displayName: String {
        switch self {
        case .open: "Open"
        case .audit: "Audit"
        case .enforce: "Enforce"
        }
    }

    var helpText: String {
        switch self {
        case .open:
            "Sandboxed agents keep broad filesystem reads except privacy-sensitive media and app roots; writes remain workspace-scoped."
        case .audit:
            "Sandboxed agents keep broad reads and log strict-scope misses, while hard-blocking privacy-sensitive media and app roots unless explicitly granted."
        case .enforce:
            "Sandboxed agents can read only explicit workspace/input paths, provider state, ASTRA task folders, temporary paths, and system/toolchain roots."
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
    /// Whether runtime filesystem reads are open, audited against the strict
    /// allowlist, or enforced by the Seatbelt profile.
    var readScope: ExecutionSandboxReadScope

    /// Providers without a native OS sandbox today — wrapped by default.
    static let defaultWrappedRuntimes: Set<AgentRuntimeID> = [.claudeCode, .copilotCLI, .openCodeCLI]

    /// Providers that ship their own OS sandbox (enforced via per-run flags).
    /// Excluded by default to avoid double-confinement breakage; the user can
    /// opt in to layer ASTRA's Seatbelt over them for defense-in-depth.
    static let nativeSandboxRuntimes: Set<AgentRuntimeID> = [.codexCLI, .cursorCLI, .antigravityCLI]

    /// Providers that drop their own confinement in autonomous mode (the
    /// `--dangerously-bypass…` / `--force --sandbox disabled` /
    /// `--dangerously-skip-permissions` flags) AND are not wrapped by default.
    /// In autonomous, their native sandbox is off, so ASTRA must wrap them or
    /// the most dangerous mode runs with no kernel boundary at all. Because the
    /// provider sandbox is bypassed here, wrapping is NOT double-confinement.
    static let autonomousForcedWrapRuntimes: Set<AgentRuntimeID> =
        nativeSandboxRuntimes.union([.openCodeCLI])

    /// Single source of truth for the unset-defaults behavior. `current(...)`
    /// (which reads `UserDefaults`) and the `SettingsView` `@AppStorage`
    /// declarations both derive their defaults from these, so the resolved
    /// behavior and the UI's initial state cannot drift apart.
    static let defaultEnforcement: ExecutionSandboxEnforcement = .bestEffort
    static let defaultAllowNetwork = true
    static let defaultLayerNativeProviders = false
    static let defaultReadScope: ExecutionSandboxReadScope = .audit

    init(
        enforcement: ExecutionSandboxEnforcement,
        wrappedRuntimes: Set<AgentRuntimeID> = ExecutionSandboxSettings.defaultWrappedRuntimes,
        allowNetwork: Bool = ExecutionSandboxSettings.defaultAllowNetwork,
        readScope: ExecutionSandboxReadScope? = nil
    ) {
        self.enforcement = enforcement
        self.wrappedRuntimes = wrappedRuntimes
        self.allowNetwork = allowNetwork
        self.readScope = readScope ?? Self.defaultReadScope(for: enforcement)
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
        // Autonomous is the broadest-permission mode (launched with
        // `--dangerously-skip-permissions`), so it must always run under a
        // kernel boundary — including when the stored setting is Off. Escalating
        // to strict (fail-closed) matches the "Auto (autonomous) runs always use
        // strict" contract shown in Settings and this function's own doc above.
        // Without escalating from `.off`, an Off + autonomous run would execute
        // with no OS sandbox at all — the most dangerous mode, unconfined.
        if permissionPolicy == .autonomous, enforcement != .strict {
            enforcement = .strict
        }

        // Network is allowed unless an explicit Bool `false` is stored. A
        // non-Bool / corrupt value falls back to the default (network on) — a
        // deliberate fail-open so a damaged preference can't silently sever the
        // CLI's model API; the offline control is a user-set Bool toggle.
        let allowNetwork = defaults.object(forKey: AppStorageKeys.sandboxAllowNetwork) as? Bool ?? defaultAllowNetwork
        let layerNative = defaults.object(forKey: AppStorageKeys.sandboxLayerNativeProviders) as? Bool ?? defaultLayerNativeProviders
        var readScope = ExecutionSandboxReadScope.normalized(
            defaults.string(forKey: AppStorageKeys.sandboxReadScope)
        )
        if enforcement == .strict {
            readScope = .enforce
        } else if enforcement == .off {
            readScope = .open
        }

        var wrappedRuntimes = defaultWrappedRuntimes
        if layerNative {
            wrappedRuntimes.formUnion(nativeSandboxRuntimes)
        }
        // In autonomous mode the self-sandboxing providers
        // (autonomousForcedWrapRuntimes) bypass their own confinement, so
        // ASTRA's wrap is their only remaining boundary — force it on for them
        // regardless of the layering toggle. Claude/Copilot are already in
        // defaultWrappedRuntimes.
        if permissionPolicy == .autonomous {
            wrappedRuntimes.formUnion(autonomousForcedWrapRuntimes)
        }

        return ExecutionSandboxSettings(
            enforcement: enforcement,
            wrappedRuntimes: wrappedRuntimes,
            allowNetwork: allowNetwork,
            readScope: readScope
        )
    }

    private static func defaultReadScope(for enforcement: ExecutionSandboxEnforcement) -> ExecutionSandboxReadScope {
        switch enforcement {
        case .off:
            return .open
        case .bestEffort:
            return defaultReadScope
        case .strict:
            return .enforce
        }
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

/// Wraps provider CLI launches in a macOS Seatbelt profile. Best Effort keeps
/// the long-standing write boundary and can audit read-scope misses; Strict
/// additionally denies filesystem reads outside ASTRA's readable allowlist.
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
/// - The write boundary is `(allow default)` + `(deny file-write*)` + scoped
///   re-allows. In Strict, the profile also denies `file-read*` and re-allows
///   only explicit workspace/input paths, provider state, temporary paths, and
///   system/toolchain roots. In Audit, a `debug deny file-read*` rule reports
///   would-deny reads without disabling the write boundary.
/// - Privacy-sensitive home/media/app roots are hard-denied even in Open/Audit
///   read scope so provider probes cannot trigger macOS TCC prompts under
///   ASTRA's name. A path inside those roots is re-allowed only when it is also
///   an explicit workspace/input/task root for the run.
enum ExecutionSandbox: Sendable {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// System and toolchain roots providers commonly need to execute CLIs,
    /// dynamic libraries, developer tools, Homebrew installs, and shell support
    /// files. User data locations such as `/Applications`, `~/Pictures`, and
    /// `~/Music` are deliberately not included.
    static let defaultReadableSystemRoots: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr",
        "/usr/local",
        "/opt/homebrew",
        "/opt/local",
        "/Library/Frameworks",
        "/Library/Developer",
        "/Library/Apple",
        // Network-capable host CLIs (gcloud, ssh helpers, provider CLIs) consult
        // system DNS, proxy, and managed-preference state while resolving hosts.
        // These are system configuration roots, not user document locations.
        "/Library/Managed Preferences",
        "/Library/Preferences",
        "/Applications/Xcode.app",
        "/private/etc",
        // macOS resolves `/bin/sh` through this selector on some systems.
        // Shell-script CLIs such as `gcloud` can fail before their own code runs
        // if Seatbelt cannot read the selector symlink.
        "/private/var/select",
        // /var/run holds host runtime state — the mDNSResponder name-resolution
        // socket, other system daemon sockets, lock/pid files — that network-
        // capable provider CLIs reach (e.g. to resolve hostnames). Read-only
        // system state, not user data. Could be narrowed to the specific socket
        // paths (e.g. /var/run/mDNSResponder) once the exact need is pinned down.
        "/private/var/run",
        "/etc",
        "/dev"
    ]

    // MARK: - Developer toolchain

    /// The active developer directory (full Xcode or the standalone Command Line
    /// Tools), resolved the way Apple's tool shims (`/usr/bin/git`, `clang`, `make`)
    /// resolve it: an explicit `DEVELOPER_DIR`, then the `xcode-select` link, then
    /// the standalone CLT. Sandboxed providers run those shims constantly (e.g.
    /// `git` for repo context); if the profile can't read this directory the shim
    /// falls back to the system "install the command line developer tools" dialog
    /// even though the tools are installed — and when `xcode-select` points at
    /// `/Applications/Xcode.app`, the privacy deny on `/Applications` is exactly
    /// what blocks it. Resolved without spawning a process (cheap, side-effect free).
    static func activeDeveloperDirectory(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        // 1. Respect an explicit, existing DEVELOPER_DIR — a deliberate override wins.
        if let explicit = environment["DEVELOPER_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty, fileManager.fileExists(atPath: explicit) {
            return explicit
        }
        // 2. Prefer the standalone Command Line Tools. It lives in an already-readable,
        //    non-privacy-protected root (`/Library/Developer`) and — unlike full Xcode —
        //    needs no license acceptance, so the sandboxed git/clang shims just work
        //    without re-allowing `/Applications` or tripping the Xcode license gate.
        let commandLineTools = "/Library/Developer/CommandLineTools"
        if fileManager.fileExists(atPath: commandLineTools) {
            return commandLineTools
        }
        // 3. Fall back to whatever `xcode-select` points at (typically Xcode under
        //    `/Applications`), which the read-allow + protected re-allow below expose.
        if let linked = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           linked.hasPrefix("/"), fileManager.fileExists(atPath: linked) {
            return linked
        }
        return nil
    }

    /// The directory the sandbox must grant read access to so Apple's tool shims can
    /// both *resolve* and *validate* the toolchain. A full Xcode shim stats the app
    /// bundle's `Info.plist`/`version.plist` (siblings of `Contents/Developer`), so
    /// the whole `.app` bundle is granted; the standalone Command Line Tools need
    /// only their own directory. Granting the read-only Xcode bundle is safe — it is
    /// system tooling, not user data, and already world-readable outside the sandbox.
    static func developerToolchainGrantRoot(_ developerDirectory: String) -> String {
        if let appRange = developerDirectory.range(of: ".app/", options: [.caseInsensitive]) {
            return String(developerDirectory[..<appRange.lowerBound]) + ".app"
        }
        return developerDirectory
    }

    /// The active developer toolchain as canonical sandbox path spellings, for the
    /// read allowlist and the protected-read re-allow. Empty when none resolves.
    static func developerDirectoryRoots(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> [String] {
        guard let directory = activeDeveloperDirectory(environment: environment, fileManager: fileManager),
              let canonical = canonicalize(developerToolchainGrantRoot(directory)) else { return [] }
        var seen: Set<String> = []
        return sandboxPathSpellings(canonical).filter { seen.insert($0).inserted }
    }

    /// `DEVELOPER_DIR` to pin into a wrapped provider's environment so toolchain
    /// shims resolve deterministically without reading `/var/db/xcode_select_link`
    /// (which the restricted read scope deliberately does not expose). Empty when
    /// none resolves or the plan already sets it (a deliberate value is respected).
    static func developerDirectoryEnvironment(
        plan: AgentRuntimeProcessLaunchPlan,
        fileManager: FileManager = .default
    ) -> [String: String] {
        if plan.environment["DEVELOPER_DIR"]?.isEmpty == false { return [:] }
        guard let directory = activeDeveloperDirectory(environment: plan.environment, fileManager: fileManager) else {
            return [:]
        }
        return ["DEVELOPER_DIR": directory]
    }

    /// `base` with the entries of `extra` not already present appended, order preserved.
    private static func appendingUnique(_ base: [String], _ extra: [String]) -> [String] {
        var seen = Set(base)
        return base + extra.filter { seen.insert($0).inserted }
    }

    // MARK: - Decision

    static func decide(
        plan: AgentRuntimeProcessLaunchPlan,
        providerHomeDirectory: String,
        additionalWritablePaths: [String] = [],
        additionalReadablePaths: [String]? = nil,
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
            additionalWritablePaths: additionalWritablePaths,
            canonicalWorkspace: workspace
        )
        // Defense-in-depth: `writableRoots` always seeds at least the workspace
        // and `/tmp`, so this is currently unreachable — but it keeps the
        // invariant explicit (never wrap with an empty allowlist, which would
        // produce an all-writes-denied profile) if that derivation ever changes.
        guard !roots.isEmpty else {
            return unavailable("no_writable_roots")
        }

        let readAdditionalPaths = additionalReadablePaths ?? additionalWritablePaths
        let explicitReadRoots = explicitlyGrantedReadableRoots(
            plan: plan,
            additionalReadablePaths: readAdditionalPaths,
            canonicalWorkspace: workspace
        )
        // The active developer toolchain must stay readable wherever it lives, or
        // the providers' `git`/`clang` shims hit the system "install command line
        // developer tools" dialog. Folded into the read allowlist (so restricted
        // scope allows it regardless of location) and, below, into the protected
        // re-allow (so a toolchain under `/Applications` survives the privacy deny).
        let developerRoots = developerDirectoryRoots(environment: plan.environment, fileManager: fileManager)
        let readableRoots = settings.readScope == .open
            ? []
            : appendingUnique(
                readableRoots(
                    plan: plan,
                    providerHomeDirectory: providerHomeDirectory,
                    additionalReadablePaths: readAdditionalPaths,
                    canonicalWorkspace: workspace
                ),
                developerRoots
            )
        let readableMetadataRoots = settings.readScope == .open
            ? []
            : readableMetadataRoots(for: readableRoots)
        let protectedReadRoots = protectedReadRoots()
        let explicitProtectedReadAllowRoots = protectedReadAllowRoots(
            // Toolchain dirs under a protected root (Xcode at `/Applications/Xcode.app`)
            // are re-allowed in every scope; the filter drops toolchain dirs that
            // aren't under a protected root (e.g. the standalone CLT), which need no
            // re-allow.
            explicitReadRoots: explicitReadRoots + developerRoots,
            protectedReadRoots: protectedReadRoots
        )
        let protectedWriteDenyRoots = protectedWriteDenyRoots(plan: plan, writableRoots: roots)
        let profile = makeProfile(
            writableRootCount: roots.count,
            readableRootCount: readableRoots.count,
            readableMetadataRootCount: readableMetadataRoots.count,
            protectedReadRootCount: protectedReadRoots.count,
            explicitProtectedReadAllowRootCount: explicitProtectedReadAllowRoots.count,
            protectedWriteDenyRootCount: protectedWriteDenyRoots.count,
            allowNetwork: settings.allowNetwork,
            readScope: settings.readScope
        )
        let arguments = makeArguments(
            profile: profile,
            writableRoots: roots,
            readableRoots: readableRoots,
            readableMetadataRoots: readableMetadataRoots,
            protectedReadRoots: protectedReadRoots,
            explicitProtectedReadAllowRoots: explicitProtectedReadAllowRoots,
            protectedWriteDenyRoots: protectedWriteDenyRoots,
            executablePath: plan.executablePath,
            arguments: plan.arguments
        )
        let wrapped = rewrite(
            plan,
            executablePath: sandboxExecPath,
            arguments: arguments,
            extraEnvironment: developerDirectoryEnvironment(plan: plan, fileManager: fileManager)
        )
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

    /// Canonical roots that must never enter the *writable allowlist*, no matter
    /// which source produced them (workspace, `directoriesToCreate`,
    /// `providerHomeDirectory`, `TMPDIR`). A misconfigured provider home or
    /// `TMPDIR` of `/` would otherwise emit `ROOT_N=/` and make the whole
    /// filesystem writable while still reporting the sandbox as applied.
    ///
    /// This is `overlyBroadRoots` minus the shared temp root: `/private/tmp`
    /// (canonical form of `/tmp`) is *intentionally* writable for every run, even
    /// though it is too broad to serve as the workspace anchor.
    static let forbiddenWritableRoots: Set<String> = overlyBroadRoots.subtracting(["/tmp", "/private/tmp"])

    /// Whether `canonicalRoot` is too broad to grant write access to.
    static func isForbiddenWritableRoot(_ canonicalRoot: String) -> Bool {
        forbiddenWritableRoots.contains(canonicalRoot)
    }

    /// Whether `canonicalRoot` is too broad to grant read access to under
    /// Strict. System/toolchain roots and `/private/tmp` are allowed, but broad
    /// user-data roots such as `/Users`, `/Applications`, and `/Library` are not.
    static func isForbiddenReadableRoot(_ canonicalRoot: String) -> Bool {
        if canonicalRoot == "/private/tmp" { return false }
        if canonicalReadableSystemRoots.contains(canonicalRoot) { return false }
        return overlyBroadRoots.contains(canonicalRoot)
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
        additionalWritablePaths: [String] = [],
        canonicalWorkspace: String
    ) -> [String] {
        var raw: [String] = [canonicalWorkspace]
        raw.append(contentsOf: plan.directoriesToCreate)
        // Workspaces can span multiple paths; agents are granted (and prompted to
        // use) the workspace's additional paths + input dirs via `--add-dir`, and
        // the in-band policy guard treats them as write roots. Mirror that here so
        // the kernel boundary doesn't block legitimate writes outside the primary
        // path. Overly-broad entries are still dropped by the final filter.
        raw.append(contentsOf: additionalWritablePaths)

        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHome.isEmpty {
            raw.append(trimmedHome)
            if let canonicalHome = canonicalize(trimmedHome), !isOverlyBroadRoot(canonicalHome) {
                for relative in plan.sandboxHomeStateAccess.explicitHomeWritableRelativePaths {
                    raw.append((trimmedHome as NSString).appendingPathComponent(relative))
                }
            }
        } else if let envHome = plan.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !envHome.isEmpty,
                  let canonicalHome = canonicalize(envHome),
                  !isOverlyBroadRoot(canonicalHome) {
            // If the provider runtime intentionally launches with a HOME, allow
            // only that provider's own state under it. Do not grant the HOME
            // root or generic shared cache/config roots from an inherited home.
            for relative in plan.sandboxHomeStateAccess.inheritedHomeWritableRelativePaths {
                raw.append((envHome as NSString).appendingPathComponent(relative))
            }
        }

        if let tmp = plan.environment["TMPDIR"], !tmp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw.append(tmp)
        }
        raw.append("/tmp")

        // Drop any root that is too broad to grant write access to — regardless of
        // which source produced it — so a misconfigured provider home / TMPDIR / `/`
        // can never widen the allowlist to most of the filesystem. (`/private/tmp`
        // is deliberately retained; see `forbiddenWritableRoots`.)
        var seen: Set<String> = []
        return raw
            .compactMap { canonicalize($0) }
            .flatMap(sandboxPathSpellings)
            .filter { root in
                guard !isForbiddenWritableRoot(root) else { return false }
                return seen.insert(root).inserted
        }
    }

    static func readableRoots(
        plan: AgentRuntimeProcessLaunchPlan,
        providerHomeDirectory: String,
        additionalReadablePaths: [String] = [],
        canonicalWorkspace: String
    ) -> [String] {
        var raw: [String] = [canonicalWorkspace]
        raw.append(contentsOf: plan.directoriesToCreate)
        raw.append(contentsOf: plan.sandboxReadablePaths)
        raw.append(contentsOf: additionalReadablePaths)
        raw.append(contentsOf: providerStateRoots(plan: plan, providerHomeDirectory: providerHomeDirectory))

        if let executable = canonicalize(plan.executablePath) {
            raw.append((executable as NSString).deletingLastPathComponent)
        }
        if let shimDirectory = plan.browserShimDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shimDirectory.isEmpty {
            raw.append(shimDirectory)
        }
        if let tmp = plan.environment["TMPDIR"], !tmp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw.append(tmp)
        }
        raw.append("/tmp")
        raw.append(contentsOf: defaultReadableSystemRoots)

        var seen: Set<String> = []
        return raw
            .compactMap { canonicalize($0) }
            .flatMap(sandboxPathSpellings)
            .filter { root in
                guard !isForbiddenReadableRoot(root) else { return false }
                return seen.insert(root).inserted
        }
    }

    static func protectedReadRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        var seen: Set<String> = []
        return PrivacySensitivePathPolicy.protectedDirectoryPaths(homeDirectory: homeDirectory)
            .compactMap { canonicalize($0) }
            .flatMap(sandboxPathSpellings)
            .filter { seen.insert($0).inserted }
    }

    static func explicitlyGrantedReadableRoots(
        plan: AgentRuntimeProcessLaunchPlan,
        additionalReadablePaths: [String] = [],
        canonicalWorkspace: String
    ) -> [String] {
        var raw: [String] = [canonicalWorkspace]
        raw.append(contentsOf: plan.directoriesToCreate)
        raw.append(contentsOf: plan.sandboxReadablePaths)
        raw.append(contentsOf: additionalReadablePaths)

        var seen: Set<String> = []
        return raw
            .compactMap { canonicalize($0) }
            .flatMap(sandboxPathSpellings)
            .filter { root in
                guard !isForbiddenReadableRoot(root) else { return false }
                return seen.insert(root).inserted
        }
    }

    static func protectedReadAllowRoots(
        explicitReadRoots: [String],
        protectedReadRoots: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return explicitReadRoots
            .filter { explicitRoot in
                protectedReadRoots.contains { protectedRoot in
                    isSameOrDescendant(explicitRoot, of: protectedRoot)
                }
            }
            .filter { seen.insert($0).inserted }
    }

    static func readableMetadataRoots(for readableRoots: [String]) -> [String] {
        var seen: Set<String> = ["/"]
        var result: [String] = []
        for root in readableRoots {
            var current = root
            while current != "/" && !current.isEmpty {
                for spelling in sandboxPathSpellings(current) where seen.insert(spelling).inserted {
                    result.append(spelling)
                }
                let parent = (current as NSString).deletingLastPathComponent
                guard parent != current else { break }
                current = parent
            }
        }
        return result
    }

    /// Specific files to keep read-only even though they sit inside a writable
    /// root (e.g. injection-sensitive config under a shared provider home). Only
    /// paths that actually fall under a granted writable root are emitted — a
    /// deny for a path nothing can write would be a no-op. Returned as literal
    /// spellings so only the exact files (not their parents) are denied.
    static func protectedWriteDenyRoots(
        plan: AgentRuntimeProcessLaunchPlan,
        writableRoots: [String]
    ) -> [String] {
        guard !plan.sandboxProtectedWriteDenyPaths.isEmpty else { return [] }
        var seen: Set<String> = []
        return plan.sandboxProtectedWriteDenyPaths
            .compactMap { canonicalize($0) }
            .filter { path in writableRoots.contains { isSameOrDescendant(path, of: $0) } }
            .flatMap(sandboxPathSpellings)
            .filter { seen.insert($0).inserted }
    }

    private static func providerStateRoots(
        plan: AgentRuntimeProcessLaunchPlan,
        providerHomeDirectory: String
    ) -> [String] {
        let trimmedHome = providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let home: String
        let relativePaths: [String]
        if !trimmedHome.isEmpty {
            home = trimmedHome
            relativePaths = plan.sandboxHomeStateAccess.explicitHomeWritableRelativePaths
        } else if let envHome = plan.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !envHome.isEmpty {
            home = envHome
            relativePaths = plan.sandboxHomeStateAccess.inheritedHomeWritableRelativePaths
        } else {
            return []
        }
        guard !home.isEmpty,
              let canonicalHome = canonicalize(home),
              !isOverlyBroadRoot(canonicalHome) else {
            return []
        }
        return relativePaths.map { relative in
            (home as NSString).appendingPathComponent(relative)
        }
    }

    private static var canonicalReadableSystemRoots: Set<String> {
        Set(defaultReadableSystemRoots.compactMap(canonicalize))
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// The HOME ASTRA can safely reason about for provider-owned state. A caller
    /// must pass an explicit provider home or set HOME in the launch plan; ASTRA
    /// never falls back to its own process home for sandbox grants.
    static func effectiveHome(plan: AgentRuntimeProcessLaunchPlan, providerHomeDirectory: String) -> String {
        if !providerHomeDirectory.isEmpty {
            return providerHomeDirectory
        }
        if let envHome = plan.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            return envHome
        }
        return ""
    }

    // MARK: - Profile generation

    /// Generates the Seatbelt profile. Writable roots are referenced positionally
    /// as `(param "ROOT_<i>")` so the actual paths are supplied out-of-band via
    /// `sandbox-exec -D` and never interpolated into this text.
    static func makeProfile(
        writableRootCount: Int,
        readableRootCount: Int = 0,
        readableMetadataRootCount: Int = 0,
        protectedReadRootCount: Int = 0,
        explicitProtectedReadAllowRootCount: Int = 0,
        protectedWriteDenyRootCount: Int = 0,
        allowNetwork: Bool,
        readScope: ExecutionSandboxReadScope = .open
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)"
        ]
        switch readScope {
        case .open:
            break
        case .audit:
            lines.append("(debug deny file-read*)")
            lines.append(contentsOf: readAllowBlock(
                readableRootCount: readableRootCount,
                readableMetadataRootCount: readableMetadataRootCount
            ))
        case .enforce:
            lines.append("(deny file-read*)")
            lines.append(contentsOf: readAllowBlock(
                readableRootCount: readableRootCount,
                readableMetadataRootCount: readableMetadataRootCount
            ))
        }
        lines.append(contentsOf: protectedReadDenyBlock(protectedReadRootCount: protectedReadRootCount))
        lines.append(contentsOf: explicitProtectedReadAllowBlock(
            explicitProtectedReadAllowRootCount: explicitProtectedReadAllowRootCount
        ))
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
        // Carve specific files back out of the writable allow above. Last match
        // wins in SBPL, so this deny overrides the broad write-allow for exactly
        // these literals (e.g. shared-home config the next session would load).
        lines.append(contentsOf: protectedWriteDenyBlock(protectedWriteDenyRootCount: protectedWriteDenyRootCount))

        return lines.joined(separator: "\n") + "\n"
    }

    private static func protectedWriteDenyBlock(protectedWriteDenyRootCount: Int) -> [String] {
        guard protectedWriteDenyRootCount > 0 else { return [] }
        var deny: [String] = ["(deny file-write*"]
        for index in 0..<protectedWriteDenyRootCount {
            deny.append("    (literal (param \"\(protectedWriteDenyRootParameterName(index))\"))")
        }
        deny.append(")")
        return deny
    }

    private static func readAllowBlock(
        readableRootCount: Int,
        readableMetadataRootCount: Int
    ) -> [String] {
        var lines: [String] = ["(allow file-read*"]
        lines.append("    (literal \"/\")")
        for index in 0..<readableRootCount {
            lines.append("    (subpath (param \"\(readRootParameterName(index))\"))")
        }
        lines.append("    (subpath \"/dev\"))")
        // Ancestor directories of readable roots get METADATA-ONLY access: the
        // kernel can stat/resolve a path through them, but the sandboxed process
        // cannot list their contents (readdir). This lets a deep auth root like
        // ~/.copilot be reached without granting a readable listing of ~ or
        // /Users. file-read* on the roots themselves (above) still allows the
        // actual reads.
        if readableMetadataRootCount > 0 {
            lines.append("(allow file-read-metadata")
            for index in 0..<readableMetadataRootCount {
                lines.append("    (literal (param \"\(readMetadataRootParameterName(index))\"))")
            }
            lines.append(")")
        }
        return lines
    }

    private static func protectedReadDenyBlock(protectedReadRootCount: Int) -> [String] {
        guard protectedReadRootCount > 0 else { return [] }
        var deny: [String] = ["(deny file-read*"]
        for index in 0..<protectedReadRootCount {
            deny.append("    (subpath (param \"\(protectedReadRootParameterName(index))\"))")
        }
        deny.append(")")
        return deny
    }

    private static func explicitProtectedReadAllowBlock(
        explicitProtectedReadAllowRootCount: Int
    ) -> [String] {
        guard explicitProtectedReadAllowRootCount > 0 else { return [] }
        var allow: [String] = ["(allow file-read*"]
        for index in 0..<explicitProtectedReadAllowRootCount {
            allow.append("    (subpath (param \"\(explicitProtectedReadAllowRootParameterName(index))\"))")
        }
        allow.append(")")
        return allow
    }

    static func rootParameterName(_ index: Int) -> String {
        "ROOT_\(index)"
    }

    static func readRootParameterName(_ index: Int) -> String {
        "READ_ROOT_\(index)"
    }

    static func protectedReadRootParameterName(_ index: Int) -> String {
        "PROTECTED_READ_ROOT_\(index)"
    }

    static func explicitProtectedReadAllowRootParameterName(_ index: Int) -> String {
        "EXPLICIT_PROTECTED_READ_ALLOW_ROOT_\(index)"
    }

    static func readMetadataRootParameterName(_ index: Int) -> String {
        "READ_LITERAL_ROOT_\(index)"
    }

    static func protectedWriteDenyRootParameterName(_ index: Int) -> String {
        "PROTECTED_WRITE_DENY_ROOT_\(index)"
    }

    /// Assembles the full `sandbox-exec` argument vector:
    /// `-p <profile> -D ROOT_0=<path> -D READ_ROOT_0=<path> ... <realExecutable> <realArgs...>`.
    static func makeArguments(
        profile: String,
        writableRoots: [String],
        readableRoots: [String] = [],
        readableMetadataRoots: [String] = [],
        protectedReadRoots: [String] = [],
        explicitProtectedReadAllowRoots: [String] = [],
        protectedWriteDenyRoots: [String] = [],
        executablePath: String,
        arguments: [String]
    ) -> [String] {
        var result: [String] = ["-p", profile]
        for (index, root) in writableRoots.enumerated() {
            result.append("-D")
            result.append("\(rootParameterName(index))=\(root)")
        }
        for (index, root) in readableRoots.enumerated() {
            result.append("-D")
            result.append("\(readRootParameterName(index))=\(root)")
        }
        for (index, root) in readableMetadataRoots.enumerated() {
            result.append("-D")
            result.append("\(readMetadataRootParameterName(index))=\(root)")
        }
        for (index, root) in protectedReadRoots.enumerated() {
            result.append("-D")
            result.append("\(protectedReadRootParameterName(index))=\(root)")
        }
        for (index, root) in explicitProtectedReadAllowRoots.enumerated() {
            result.append("-D")
            result.append("\(explicitProtectedReadAllowRootParameterName(index))=\(root)")
        }
        for (index, root) in protectedWriteDenyRoots.enumerated() {
            result.append("-D")
            result.append("\(protectedWriteDenyRootParameterName(index))=\(root)")
        }
        result.append(canonicalize(executablePath) ?? executablePath)
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

    /// Seatbelt usually matches the `/private/...` real path, but script exec and
    /// a few system shims can report firmlink spellings such as `/var/...`.
    /// Keep both forms for already-approved roots without widening to their
    /// parent directories.
    private static func sandboxPathSpellings(_ canonicalPath: String) -> [String] {
        var result = [canonicalPath]
        let aliases = [
            (canonical: "/private/var", visible: "/var"),
            (canonical: "/private/tmp", visible: "/tmp"),
            (canonical: "/private/etc", visible: "/etc")
        ]
        for alias in aliases {
            if canonicalPath == alias.canonical {
                result.append(alias.visible)
            } else if canonicalPath.hasPrefix(alias.canonical + "/") {
                result.append(alias.visible + String(canonicalPath.dropFirst(alias.canonical.count)))
            }
        }
        return result
    }

    // MARK: - Plan rewriting

    private static func rewrite(
        _ plan: AgentRuntimeProcessLaunchPlan,
        executablePath: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: plan.runtime,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectory: plan.currentDirectory,
            // Merge keeps any value the plan already set (a deliberate DEVELOPER_DIR
            // wins over the resolved one).
            environment: extraEnvironment.isEmpty
                ? plan.environment
                : plan.environment.merging(extraEnvironment) { current, _ in current },
            browserShimDirectory: plan.browserShimDirectory,
            providerVersion: plan.providerVersion,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: plan.directoriesToCreate,
            sandboxReadablePaths: plan.sandboxReadablePaths,
            sandboxHomeStateAccess: plan.sandboxHomeStateAccess,
            sandboxProtectedWriteDenyPaths: plan.sandboxProtectedWriteDenyPaths,
            providerDetectedFields: plan.providerDetectedFields,
            commandPlannedFields: plan.commandPlannedFields,
            interactiveAsk: plan.interactiveAsk,
            pathMapper: plan.pathMapper,
            executionEnvironment: plan.executionEnvironment
        )
    }
}
