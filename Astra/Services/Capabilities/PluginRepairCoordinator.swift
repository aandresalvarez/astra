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

    static func key(_ repair: RepairAction) -> String {
        "\(repair.componentName)|\(repair.command ?? repair.url?.absoluteString ?? repair.strategy.rawValue)"
    }

    func phase(for repair: RepairAction) -> Phase? {
        phases[Self.key(repair)]
    }

    /// Runs `repair` and, when it has a check, polls until it passes.
    /// `onVerified` runs once, on the main actor, after the check passes.
    func start(_ repair: RepairAction, onVerified: @escaping @MainActor () -> Void = {}) {
        let key = Self.key(repair)
        polls[key]?.cancel()
        run(repair)
        guard repair.checkBinary != nil else {
            phases[key] = nil
            return
        }
        phases[key] = .waiting
        polls[key] = Task { [weak self] in
            guard let self else { return }
            var passes = 0
            for _ in 0..<maxAttempts {
                await sleep(interval)
                if Task.isCancelled { return }
                passes = await check(repair) ? passes + 1 : 0
                if passes >= requiredPasses {
                    phases[key] = .verified
                    onVerified()
                    return
                }
            }
            phases[key] = .timedOut
        }
    }

    func cancelAll() {
        polls.values.forEach { $0.cancel() }
        polls.removeAll()
    }

    /// Re-runs the component's check exactly as the health check does.
    nonisolated static func liveCheck(_ repair: RepairAction) async -> Bool {
        guard let binary = repair.checkBinary else { return true }
        let status = await EnvironmentHealthChecker().check(
            binary: binary,
            livenessArgs: repair.checkArguments ?? ["--version"],
            semantic: repair.checkExpect.flatMap(SemanticCheck.init(rawValue:))
        )
        return status.isUsable
    }
}
