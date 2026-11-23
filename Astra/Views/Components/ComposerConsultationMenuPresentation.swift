import Foundation

/// What the composer's Work / Consult control shows for a selection and for
/// whether Consult can start. Kept apart from the view so it can be tested.
struct ComposerConsultationMenuPresentation: Equatable {
    static let defaultHelp = "Consult reads workspace files while other tasks work. Files may change during the answer. Switch to Work to change workspace files."

    let isConsult: Bool
    let availability: TaskWorkspaceConsultationAvailability

    /// Consult is selected and cannot start: the next message would fail.
    var needsAttention: Bool { isConsult && !availability.isAvailable }

    var title: String { isConsult ? "Consult" : "Work" }

    var systemImage: String {
        if needsAttention { return "exclamationmark.triangle" }
        return isConsult ? "text.bubble" : "hammer"
    }

    /// An unavailable Consult cannot be chosen. It stays enabled while it is
    /// the current selection so the menu still shows which mode is saved.
    var consultChoiceDisabled: Bool { !availability.isAvailable && !isConsult }

    var menuNote: String? { availability.menuNote }

    var help: String {
        guard let explanation = availability.explanation else { return Self.defaultHelp }
        return needsAttention ? "\(explanation) Messages sent in Consult will not start." : explanation
    }

    var accessibilityValue: String {
        guard !availability.isAvailable else { return title }
        return needsAttention ? "Consult, cannot start" : "Work. Consult is unavailable"
    }
}
