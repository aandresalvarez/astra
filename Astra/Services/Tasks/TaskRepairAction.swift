import Foundation
import ASTRACore

/// Executes an admitted external repair, or verifies a manual one. It never
/// resumes a task: the existing lifecycle service owns that separate action.
@MainActor
enum TaskRepairAction {
    struct Guidance: Equatable, Sendable {
        let title: String
        let detail: String
    }

    static func perform(
        _ candidate: RepairAction?,
        check: @MainActor (RepairAction) async -> Bool = { await PluginRepairCoordinator.liveCheck($0) },
        run: @MainActor (RepairAction) -> Void = { RepairActionRunner.run($0) }
    ) async -> Guidance? {
        guard !Task.isCancelled else { return nil }
        guard let candidate else {
            return Guidance(title: "Setup unavailable", detail: "Reopen the task to refresh its setup instructions.")
        }
        let repair = candidate.targetingCredentialStore(candidate.checkEnvironment)
        switch repair.strategy {
        case .terminal where repair.command != nil:
            run(repair)
            return nil
        case .url:
            if let url = repair.url, RepairAction.isSafeRepairURL(url) { run(repair); return nil }
            return Guidance(title: "Manual setup required", detail: "Open the provider's trusted setup page, then return to this task.")
        case .terminal:
            guard repair.checkBinary != nil else {
                return Guidance(title: repair.title, detail: repair.detail)
            }
            let passed = await check(repair)
            guard !Task.isCancelled else { return nil }
            return passed
                ? Guidance(title: "Setup check passed", detail: "The configured check passed. Choose Resume or Retry to continue the task.")
                : Guidance(title: "Setup needs attention", detail: repair.detail + " Resume or Retry will verify access again after setup.")
        case .deviceCode, .credentialForm:
            return Guidance(title: "Manual setup required", detail: "Reconnect this account in workspace settings, then resume or retry the task.")
        }
    }
}
