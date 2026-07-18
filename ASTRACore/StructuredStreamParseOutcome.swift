/// Distinguishes a structured line that a provider parser intentionally owns
/// from a line that belongs to a fallback format.
///
/// An empty event array is valid for a recognized line, so it must never be
/// used as the fallback signal. Conflating those states can turn lifecycle
/// JSON into transcript text or an unknown provider event.
enum StructuredStreamParseOutcome<Event> {
    case recognized([Event])
    case unrecognized

    func resolvingUnrecognized(with fallback: () -> [Event]) -> [Event] {
        switch self {
        case .recognized(let events):
            return events
        case .unrecognized:
            return fallback()
        }
    }
}
