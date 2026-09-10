import Foundation
import ASTRACore
import ASTRAModels

/// What a provider says about accepting the MCP servers ASTRA supplies.
///
/// ASTRA's connectors reach an agent as an MCP server (`astra_host`). A provider
/// can refuse to run it for reasons that live entirely outside ASTRA — an
/// enterprise requirements bundle, for one — and refuse it *silently*: the
/// server is listed in the launch manifest, the CLI accepts the argument, and
/// the agent simply never sees the tools. Recording the provider's own answer
/// is what lets a launch stop instead of paying for a turn that cannot work.
enum RuntimeProviderMCPPolicy: Equatable, Sendable {
    /// Never asked, or the answer could not be read. Treated as permitted
    /// everywhere: a diagnostic that fails must not become an outage.
    case unknown
    case permitted
    /// The provider positively reported that it will not run the server.
    /// `policyName` is whatever the provider called the policy, when it named
    /// one — never ASTRA's guess, and never the provider's raw debug text.
    case serversDisabled(policyName: String?)

    var refusesServers: Bool {
        if case .serversDisabled = self { return true }
        return false
    }

    var policyName: String? {
        if case .serversDisabled(let name) = self { return name }
        return nil
    }

    /// Short, stable label for logs and capability evidence.
    var evidence: String {
        switch self {
        case .unknown: "codex-mcp-list:unknown"
        case .permitted: "codex-mcp-list:servers-permitted"
        case .serversDisabled(let name): "codex-mcp-list:servers-disabled(\(name ?? "unnamed-policy"))"
        }
    }
}

/// The persisted form of a policy answer, with the time it was obtained.
struct RuntimeProviderMCPPolicySnapshot: Codable, Equatable, Sendable {
    var serversPermitted: Bool
    var policyName: String?
    var checkedAt: Date
}

/// Asks the Codex CLI whether it will accept ASTRA's host-control MCP server,
/// caches the answer, and hands it to the launch path.
///
/// Modeled on `CodexModelAvailabilityService`: a protocol-shaped probe so tests
/// never shell out, a `UserDefaults` snapshot as the cache, and a refresh that
/// persists only answers it actually understood.
struct CodexMCPPolicyService {
    /// Codex re-pulls its enterprise requirements bundle from the cloud on a
    /// one-hour TTL (`~/.codex/cloud-config-bundle-cache.json`), so an answer
    /// older than that can already be wrong and one newer than that cannot be
    /// improved by asking again. Matching the provider's own TTL keeps ASTRA
    /// from inventing a second, disagreeing notion of freshness.
    static let cacheLifetime: TimeInterval = 3600

    var probe: any CodexMCPPolicyProbing = CodexMCPListPolicyProbe()
    var detectExecutable: @Sendable () -> String = { CodexCLIRuntime.detectPath() }
    /// The server name and command ASTRA would really inject at launch, so the
    /// question asked is the question that matters.
    var serverID: String = HostControlPlaneMCPProjection.serverID
    var serverCommand: String = HostControlBrokerReadiness.helperPath

    @discardableResult
    func refreshAndPersist(
        executablePath: String,
        homeDirectory: String = "",
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async -> RuntimeProviderMCPPolicy {
        guard Self.answersAllowed(in: defaults) else { return .unknown }
        let configured = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configured.isEmpty ? detectExecutable() : configured
        var environment = RuntimeProcessEnvironment.enriched()
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty { environment["CODEX_HOME"] = home }
        do {
            let result = try await probe.probe(
                serverID: serverID,
                command: serverCommand,
                executablePath: executable,
                environment: environment
            )
            try Task.checkCancellation()
            let policy: RuntimeProviderMCPPolicy = result.serverEnabled
                ? .permitted
                : .serversDisabled(policyName: Self.policyName(fromDisabledReason: result.disabledReason))
            Self.persist(policy, defaults: defaults, now: now)
            AppLogger.audit(.runtimeMCPPolicy, category: "Worker", fields: [
                "runtime": AgentRuntimeID.codexCLI.rawValue,
                "result": result.serverEnabled ? "permitted" : "servers_disabled",
                "policy": policy.policyName ?? "unnamed"
            ], level: result.serverEnabled ? .debug : .warning)
            return policy
        } catch {
            // Fail open, and leave any previous answer alone. A probe that
            // times out, is cancelled, or finds no CLI has learned nothing —
            // overwriting a known "disabled" with silence would re-open the
            // exact hole this check exists to close.
            let reason = (error as? CodexMCPPolicyProbeError)?.localizedDescription
                ?? (error is CancellationError ? "The Codex MCP policy check was cancelled." : "Could not read the Codex MCP server list.")
            AppLogger.audit(.runtimeMCPPolicy, category: "Worker", fields: [
                "runtime": AgentRuntimeID.codexCLI.rawValue,
                "result": "unknown", "reason": reason
            ], level: .debug)
            return .unknown
        }
    }

    /// The cached answer while it is still fresh, and a live probe otherwise.
    /// Readiness runs on every launch, so re-asking each time would cost a
    /// subprocess to learn something the provider will not have changed.
    func policy(
        executablePath: String,
        homeDirectory: String = "",
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async -> RuntimeProviderMCPPolicy {
        guard Self.answersAllowed(in: defaults) else { return .unknown }
        guard !Self.isCacheFresh(defaults: defaults, now: now) else {
            return Self.cachedPolicy(defaults: defaults, now: now)
        }
        return await refreshAndPersist(
            executablePath: executablePath,
            homeDirectory: homeDirectory,
            defaults: defaults,
            now: now
        )
    }

    /// The launch path's synchronous read. Never probes: an admission decision
    /// runs on the main actor and the probe takes about a second, so anything
    /// that has to be asked is asked ahead of time by `warmBeforeLaunch`.
    static func cachedPolicy(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> RuntimeProviderMCPPolicy {
        guard answersAllowed(in: defaults),
              let snapshot = snapshot(defaults: defaults),
              isFresh(snapshot, now: now) else {
            return .unknown
        }
        return snapshot.serversPermitted
            ? .permitted
            : .serversDisabled(policyName: snapshot.policyName)
    }

    static func isCacheFresh(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard answersAllowed(in: defaults), let snapshot = snapshot(defaults: defaults) else {
            return false
        }
        return isFresh(snapshot, now: now)
    }

    /// The shared defaults domain inside a test process is the developer's own
    /// machine, and the answer stored there is their employer's Codex policy —
    /// a real one, which would make unrelated suites pass or fail depending on
    /// whose laptop ran them. So the shared domain is closed to tests in both
    /// directions: nothing is read from it and nothing is written to it, which
    /// leaves every suite seeing `.unknown` (the behavior that predates this
    /// check). Tests that exercise this service inject a probe and their own
    /// `UserDefaults` suite, the same contract `AstraSecureKeychainStore`
    /// imposes for the real keychain.
    static func answersAllowed(in defaults: UserDefaults) -> Bool {
        defaults !== UserDefaults.standard || !isRunningTests
    }

    private static let isRunningTests: Bool = {
        ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }()

    /// Refreshes the cached answer when it has expired, so the admission
    /// decision that follows is made against what the provider says today.
    /// Bounded by the probe's own deadline and skipped entirely while the cache
    /// is fresh, so the cost is at most one `codex mcp list` per hour.
    @MainActor
    static func warmBeforeLaunch(
        configuration: AgentRuntimeConfiguration,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async {
        guard AgentRuntimeAdapterRegistry.hasAdapter(for: .codexCLI),
              !isCacheFresh(defaults: defaults, now: now) else { return }
        let settings = AgentRuntimeAdapterRegistry.adapter(for: .codexCLI)
            .launchSettings(configuration: configuration)
        _ = await CodexMCPPolicyService().policy(
            executablePath: settings.executablePath,
            homeDirectory: settings.homeDirectory,
            defaults: defaults,
            now: now
        )
    }

    /// Pulls the policy's own name out of the provider's explanation, e.g.
    /// `requirements (enterprise-managed requirements Baseline (regulated-workspace-default-fallback))`
    /// yields `Baseline`. The name is the part an admin can act on; the rest is
    /// the provider's internal wording and must not reach the user.
    ///
    /// No provider string is matched as a trigger anywhere — `enabled: false`
    /// is the trigger. This only decides what the block is allowed to *call*
    /// the policy, and returns nil rather than guessing.
    static func policyName(fromDisabledReason reason: String?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        let pattern = #"requirements\s+([^()]+?)\s*\([^()]*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: reason,
                range: NSRange(reason.startIndex..., in: reason)
              ),
              let range = Range(match.range(at: 1), in: reason) else { return nil }
        let name = reason[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(80))
    }

    private static func persist(
        _ policy: RuntimeProviderMCPPolicy,
        defaults: UserDefaults,
        now: Date
    ) {
        let snapshot = RuntimeProviderMCPPolicySnapshot(
            serversPermitted: !policy.refusesServers,
            policyName: policy.policyName,
            checkedAt: now
        )
        guard answersAllowed(in: defaults),
              let data = try? JSONEncoder().encode(snapshot),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: AppStorageKeys.runtimeMCPPolicyKey(for: .codexCLI))
    }

    private static func snapshot(defaults: UserDefaults) -> RuntimeProviderMCPPolicySnapshot? {
        guard let raw = defaults.string(forKey: AppStorageKeys.runtimeMCPPolicyKey(for: .codexCLI)) else {
            return nil
        }
        return try? JSONDecoder().decode(RuntimeProviderMCPPolicySnapshot.self, from: Data(raw.utf8))
    }

    /// A snapshot from the future is a clock that moved, not an answer — treat
    /// it as absent rather than trusting it forever.
    private static func isFresh(_ snapshot: RuntimeProviderMCPPolicySnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.checkedAt)
        return age >= 0 && age < cacheLifetime
    }
}
