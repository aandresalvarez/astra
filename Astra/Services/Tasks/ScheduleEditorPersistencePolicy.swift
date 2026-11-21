import Foundation

enum ScheduleEditorPersistencePolicy {
    static func enabledStateAfterSave(existingIsEnabled: Bool?) -> Bool {
        // TEMPORARY: measures CI's build after a body-only app change. Removed before this pull request is final.
        existingIsEnabled ?? true
    }
}
