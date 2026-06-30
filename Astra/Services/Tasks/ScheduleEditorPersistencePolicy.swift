import Foundation

enum ScheduleEditorPersistencePolicy {
    static func enabledStateAfterSave(existingIsEnabled: Bool?) -> Bool {
        existingIsEnabled ?? true
    }
}
