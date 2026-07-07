import Foundation

/// Canonical phrases for the free-text validation payloads emitted on `task.completed`
/// and `error` events.
///
/// The producer (`AgentRuntimeWorker`) writes these payloads and the consumer
/// (`TaskContextStateManager` verification inference) classifies them. Sharing one source
/// of truth means the two sides cannot drift out of sync: reword a phrase here and both
/// the emitted payload and the classifier move together, instead of a silent
/// reword on one side quietly breaking verification status on the other.
///
/// Markers are punctuation-light and matched case-insensitively as substrings so payloads
/// persisted before this type existed continue to classify unchanged.
public enum ValidationOutcomeMarker: String, CaseIterable {
    case testsPassed = "Tests passed"
    case testsFailed = "Tests failed"
    case validationError = "Validation error"
    case aiCheckPassed = "AI check passed"
    case aiCheckFlagged = "AI check flagged"
    case aiCheckError = "AI check error"

    public func matches(_ payload: String) -> Bool {
        payload.range(of: rawValue, options: .caseInsensitive) != nil
    }
}
