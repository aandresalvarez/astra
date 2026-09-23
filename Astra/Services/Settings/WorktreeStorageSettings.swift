import Foundation
import ASTRAModels

/// Owner of the worktree-storage preferences. Services read them on every
/// evaluation, so a change applies to the next automatic pass without an
/// observer. Backed by `UserDefaults` directly rather than a property wrapper,
/// which keeps the settings view off the architecture-fitness ratchet.
enum WorktreeStorageSettings {
    static let defaultAutomaticReclaimEnabled = true
    static let defaultIdleThresholdHours = 48
    /// Choices offered in Settings, in hours.
    static let idleThresholdHourOptions = [24, 48, 72, 168]

    static func isAutomaticReclaimEnabled(in defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` reads a missing key as false; this setting defaults on.
        guard defaults.object(forKey: AppStorageKeys.worktreeAutoReclaimEnabled) != nil else {
            return defaultAutomaticReclaimEnabled
        }
        return defaults.bool(forKey: AppStorageKeys.worktreeAutoReclaimEnabled)
    }

    static func setAutomaticReclaimEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppStorageKeys.worktreeAutoReclaimEnabled)
    }

    /// The stored threshold when it is one of the offered choices, else the
    /// default.
    static func idleThresholdHours(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: AppStorageKeys.worktreeIdleThresholdHours) != nil else {
            return defaultIdleThresholdHours
        }
        let stored = defaults.integer(forKey: AppStorageKeys.worktreeIdleThresholdHours)
        return idleThresholdHourOptions.contains(stored) ? stored : defaultIdleThresholdHours
    }

    static func setIdleThresholdHours(_ hours: Int, in defaults: UserDefaults = .standard) {
        defaults.set(hours, forKey: AppStorageKeys.worktreeIdleThresholdHours)
    }

    /// Policy thresholds for the current settings. Removal suggestions have no
    /// setting in v1.
    static func thresholds(in defaults: UserDefaults = .standard) -> WorktreeReclaimThresholds {
        WorktreeReclaimThresholds(
            reclaimAfter: TimeInterval(idleThresholdHours(in: defaults)) * 60 * 60,
            suggestRemovalAfter: WorktreeReclaimThresholds.standard.suggestRemovalAfter
        )
    }

    static func label(forIdleThresholdHours hours: Int) -> String {
        hours % 24 == 0 && hours > 24 ? "\(hours / 24) days" : "\(hours) hours"
    }
}
