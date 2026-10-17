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
        case verified
        case timedOut
    }

    @Published private(set) var phases: [String: Phase] = [:]

    private let check: @Sendable (RepairAction) async -> Bool
    private let run: @MainActor (RepairAction) -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let interval: TimeInterval
    private let maxAttempts: Int
    private let requiredPasses: Int
    private var polls: [String: Task<Void, Never>] = [:]

    init(
        check: @escaping @Sendable (RepairAction) async -> Bool = PluginRepairCoordinator.liveCheck,
        run: @escaping @MainActor (RepairAction) -> Void = { RepairActionRunner.run($0) },
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
            repair.checkExpect ?? ""
        ].joined(separator: "\u{1F}")
    }

    func phase(for repair: RepairAction, owner: String) -> Phase? {
        phases[Self.key(repair, owner: owner)]
    }

    /// Runs `repair` and, when it has a check, polls until it passes.
    /// `onVerified` runs once, on the main actor, after the check passes.
    func start(_ repair: RepairAction, owner: String, onVerified: @escaping @MainActor () -> Void = {}) {
        let key = Self.key(repair, owner: owner)
        polls[key]?.cancel()
        run(repair)
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

    /// Re-runs the component's check exactly as the health check does.
    nonisolated static func liveCheck(_ repair: RepairAction) async -> Bool {
        guard let binary = repair.checkBinary else { return true }
        // With the stopped run's variables, the check runs the CLI as that
        // run did: a token the task projected, not ASTRA's own login.
        if let environment = repair.checkEnvironment, !environment.isEmpty {
            let path = RuntimePathResolver.detectExecutablePath(named: binary)
            guard !path.isEmpty else { return false }
            let merged = ProcessInfo.processInfo.environment.merging(environment) { _, projected in projected }
            let result = await ProcessBinaryRunner().run(
                path: path, args: repair.checkArguments ?? ["--version"], timeout: 10, environment: merged
            )
            guard result.exitCode == 0 else { return false }
            if repair.checkExpect == SemanticCheck.stdoutNonEmpty.rawValue {
                return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        let status = await EnvironmentHealthChecker().check(
            binary: binary,
            livenessArgs: repair.checkArguments ?? ["--version"],
            semantic: repair.checkExpect.flatMap(SemanticCheck.init(rawValue:))
        )
        return status.isUsable
    }
}
