import Foundation

/// Owns the launch probe so both worker cancellation and caller cancellation
/// reach the subprocess, even before the runtime process runner has started.
@MainActor
final class AntigravityLaunchPreparation {
    private let defaults: UserDefaults
    private let timeoutSeconds: TimeInterval
    private var pending: Task<Bool, Never>?

    init(defaults: UserDefaults = .standard, timeoutSeconds: TimeInterval = 8) {
        self.defaults = defaults
        self.timeoutSeconds = timeoutSeconds
    }

    @discardableResult
    func prepare(executablePath: String, homeDirectory: String, taskID: UUID) async -> Bool {
        guard !Task.isCancelled else { return true }
        let preparation = Task {
            await AntigravityCLIRuntime.probeStructuredOutputSupportBeforeLaunch(
                executablePath: executablePath, providerHomeDirectory: homeDirectory,
                taskID: taskID, defaults: defaults, timeoutSeconds: timeoutSeconds
            ).stopped
        }
        pending = preparation
        defer { pending = nil }
        return await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    func cancel() { pending?.cancel() }
}
