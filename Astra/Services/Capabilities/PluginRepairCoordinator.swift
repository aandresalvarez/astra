import Foundation
import ASTRACore

/// Runs a plugin component's repair, then keeps checking until the component
/// works again (Plugins 2.0 health and repair: detect → show → repair →
/// verify).
///
/// A sign-in typed into Terminal finishes outside ASTRA, so there is nothing
/// to wait on: the coordinator re-runs the component's own check every few
/// seconds, needs two passes in a row (one can land mid-login), and gives up
/// after a few minutes so a forgotten Terminal window does not poll forever.
/// A repair with no check (a credential form, a page with nothing to probe)
/// just runs.
@MainActor
final class PluginRepairCoordinator: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case refused
        case verified
        case timedOut
    }

    @Published private(set) var phases: [String: Phase] = [:]

    private let check: @Sendable (RepairAction) async -> Bool
    private let run: @MainActor (RepairAction) -> RepairActionRunner.Outcome
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let interval: TimeInterval
    private let maxAttempts: Int
    private let requiredPasses: Int
    private var polls: [String: Task<Void, Never>] = [:]

    init(
        check: @escaping @Sendable (RepairAction) async -> Bool = { await PluginRepairCoordinator.liveCheck($0) },
        run: @escaping @MainActor (RepairAction) -> RepairActionRunner.Outcome = { RepairActionRunner.run($0) },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        interval: TimeInterval = 5,
        maxWait: TimeInterval = 300,
        requiredPasses: Int = 2
    ) {
        self.check = check
        self.run = run
        self.sleep = sleep
        self.interval = interval
        self.maxAttempts = max(1, Int(maxWait / max(interval, 0.001)))
        self.requiredPasses = requiredPasses
    }

    /// One poll per owner and repair contract. `owner` names the package (and
    /// component) the row belongs to: two plugins can declare the same
    /// component name and command, and must not share, or cancel, one poll.
    /// The whole check is part of the key, so the same command checked two
    /// ways is two polls. The check environment is not: it is set per check
    /// and can hold a token.
    static func key(_ repair: RepairAction, owner: String) -> String {
        [
            owner,
            repair.componentName,
            repair.strategy.rawValue,
            repair.command ?? "",
            repair.url?.absoluteString ?? "",
            repair.checkBinary ?? "",
            (repair.checkArguments ?? []).joined(separator: "\u{1E}"),
            repair.checkExpect ?? "",
            repair.checkTimeout.map(String.init(describing:)) ?? ""
        ].joined(separator: "\u{1F}")
    }

    func phase(for repair: RepairAction, owner: String) -> Phase? {
        phases[Self.key(repair, owner: owner)]
    }

    func statusText(for repair: RepairAction, owner: String) -> String? {
        switch phase(for: repair, owner: owner) {
        case .waiting: "Checking…"
        case .refused: "Couldn't start repair. Check the CLI installation or repair link, then try again."
        default: nil
        }
    }

    /// Runs `repair` and, when it has a check, polls until it passes.
    /// `onVerified` runs once, on the main actor, after the check passes.
    func start(_ repair: RepairAction, owner: String, onVerified: @escaping @MainActor () -> Void = {}) {
        let key = Self.key(repair, owner: owner)
        polls[key]?.cancel()
        polls[key] = nil
        let outcome = run(repair)
        if outcome == .refused, repair.command != nil || repair.url != nil {
            phases[key] = .refused
            return
        }
        // A guidance-only Check intentionally has nothing to launch.
        guard repair.checkBinary != nil else {
            phases[key] = nil
            return
        }
        phases[key] = .waiting
        // The loop holds the coordinator only between sleeps, so a view that
        // goes away (and cancels, below) is not kept alive by its polling.
        let sleep = self.sleep
        let check = self.check
        let interval = self.interval
        let attempts = maxAttempts
        let required = requiredPasses
        polls[key] = Task { [weak self] in
            var passes = 0
            for _ in 0..<attempts {
                await sleep(interval)
                if Task.isCancelled || self == nil { return }
                passes = await check(repair) ? passes + 1 : 0
                if Task.isCancelled { return }
                if passes >= required {
                    self?.phases[key] = .verified
                    onVerified()
                    return
                }
            }
            self?.phases[key] = .timedOut
        }
    }

    func cancelAll() {
        polls.values.forEach { $0.cancel() }
        // A cancelled poll will never move its phase on: a view shown again
        // would say "Checking…" forever.
        for key in polls.keys where phases[key] == .waiting { phases[key] = nil }
        polls.removeAll()
    }

    /// Re-runs the component's check exactly as the health check does. The
    /// executable it runs must be the CLI (`TrustedExecutablePath`): one the
    /// stopped run's own `PATH` finds, or a declared path, must be an
    /// installed copy once symlinks resolve (`isInstalled`, injectable for
    /// tests); one ASTRA's own lookup finds by name must be absolute.
    nonisolated static func liveCheck(
        _ repair: RepairAction,
        runner: any BinaryRunner = ProcessBinaryRunner(),
        isInstalled: @escaping @Sendable (String) -> Bool = { TrustedExecutablePath.isInstalled($0) }
    ) async -> Bool {
        guard let binary = repair.checkBinary else { return true }
        if let timeout = repair.checkTimeout {
            guard timeout.isFinite, CLIPrerequisite.slowStartTimeoutRange.contains(timeout) else { return false }
        }
        // Only a read-only status check is run (`HealthCheckPolicy`).
        let arguments = repair.checkArguments ?? ["--version"]
        let existenceOnly = HealthCheckPolicy.isExistenceOnly(binary: binary, arguments: arguments)
        guard existenceOnly || HealthCheckPolicy.isReadOnly(binary: binary, arguments: arguments) else { return false }
        // With the stopped run's variables, the check runs the CLI as that
        // run did: a token the task projected, not ASTRA's own login.
        if let environment = repair.checkEnvironment, !environment.isEmpty {
            let path = checkExecutablePath(binary, environment: environment, workingDirectory: repair.checkWorkingDirectory)
            let searchedByASTRA = environment["PATH"] == nil && !binary.contains("/")
            // Found is all an existence check asks; it runs nothing.
            if existenceOnly { return path.hasPrefix("/") }
            guard searchedByASTRA ? path.hasPrefix("/") : isInstalled(path) else { return false }
            let merged = ProcessInfo.processInfo.environment.merging(environment) { _, projected in projected }
            let result = await runner.run(
                path: path, args: repair.checkArguments ?? ["--version"], timeout: repair.checkTimeout ?? 10, environment: merged
            )
            guard result.exitCode == 0 else { return false }
            // Every declared semantic test, on stdout and stderr, as the
            // health check applies it: `docker version` exits 0 with the
            // daemon down and says so only on stderr.
            let semantic = repair.checkExpect.flatMap(SemanticCheck.init(rawValue:))
            return semantic?.passes(stdout: result.stdout, stderr: result.stderr) ?? true
        }
        let status = await EnvironmentHealthChecker(runner: runner, isInstalled: isInstalled).check(
            binary: binary,
            livenessArgs: repair.checkArguments ?? ["--version"],
            semantic: repair.checkExpect.flatMap(SemanticCheck.init(rawValue:)),
            timeout: repair.checkTimeout ?? EnvironmentHealthChecker.defaultLivenessTimeout
        )
        return status.isUsable
    }

    /// The executable the resumed run's shell would start: with a projected
    /// `PATH`, the first match on it (as the shell resolves it), else ASTRA's
    /// usual lookup. Empty when the projected `PATH` has none. A relative
    /// entry (`./tools`), or an empty one (the current directory), is where
    /// the shell looks from the run's `workingDirectory`, never ASTRA's own;
    /// without one such entries are skipped.
    nonisolated static func checkExecutablePath(
        _ binary: String, environment: [String: String], workingDirectory: String? = nil
    ) -> String {
        guard let projected = environment["PATH"], !binary.contains("/") else {
            return RuntimePathResolver.detectExecutablePath(named: binary)
        }
        return projected.split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { entry -> String? in
                if entry.hasPrefix("/") { return String(entry) }
                return workingDirectory.map { ($0 as NSString).appendingPathComponent(String(entry)) }
            }
            .map { ($0 as NSString).appendingPathComponent(binary) }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}
