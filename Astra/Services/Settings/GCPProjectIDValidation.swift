import Foundation

/// Shape validation for a Google Cloud project ID.
///
/// ASTRA used to test this field for non-emptiness alone, which let a
/// structurally impossible value reach Vertex. A field that had accumulated
/// eleven space-separated copies of a real project ID (284 characters) passed
/// every check, the Runtime tab reported the provider **Ready**, and every
/// call then came back `403 Permission denied on resource project …` with
/// `reason: CONSUMER_INVALID` — an error the user cannot act on, because
/// nothing in ASTRA ever said the value was wrong. Task 5FB5E95B died that way
/// five times in four minutes, 519 ms and zero tokens per attempt.
///
/// The rules below are Google's documented constraints for a project ID, so
/// they can be checked locally with no network call. What they cannot tell us
/// is whether a *well-formed* ID exists or is one the caller may use; that
/// answer only comes from the API. The point of validating here is narrower
/// and worth stating: a value that fails these rules can never succeed, so
/// reporting it as configured is always a lie.
enum GCPProjectIDValidation {
    /// Google's documented bounds for a project ID.
    static let minimumLength = 6
    static let maximumLength = 30

    enum Failure: Equatable, Sendable {
        case empty
        case tooShort(length: Int)
        case tooLong(length: Int)
        case invalidFirstCharacter
        case trailingHyphen
        case disallowedCharacters(Set<Character>)

        /// Written for the person looking at the Settings field, so it names
        /// the observed value's problem rather than restating the whole rule.
        var message: String {
            switch self {
            case .empty:
                return "Project ID is required for Vertex routing."
            case .tooShort(let length):
                return "Project ID must be at least \(GCPProjectIDValidation.minimumLength) characters (this one is \(length))."
            case .tooLong(let length):
                return "Project ID must be at most \(GCPProjectIDValidation.maximumLength) characters (this one is \(length)). A much longer value usually means the field was pasted into more than once."
            case .invalidFirstCharacter:
                return "Project ID must start with a lowercase letter."
            case .trailingHyphen:
                return "Project ID cannot end with a hyphen."
            case .disallowedCharacters(let characters):
                let listed = characters.sorted().map(GCPProjectIDValidation.describe).joined(separator: " ")
                return "Project ID may only contain lowercase letters, digits, and hyphens. Remove: \(listed)"
            }
        }
    }

    /// Names a character the user has to find and delete. A bare `String.init`
    /// is enough for a visible one, but the value that motivated this type was
    /// eleven copies joined by *spaces*, and "Remove:  " reads as a bug rather
    /// than as an instruction.
    static func describe(_ character: Character) -> String {
        switch character {
        case " ": return "space"
        case "\t": return "tab"
        case "\n", "\r": return "line break"
        default:
            return character.isWhitespace ? "whitespace" : String(character)
        }
    }

    /// `nil` when the trimmed value is a well-formed project ID.
    static func failure(for rawValue: String) -> Failure? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }

        // Length comes first so a value pasted in repeatedly is diagnosed as
        // that. The real one — eleven space-separated copies, 284 characters —
        // is *also* full of disallowed spaces, and "Remove: space" sends the
        // user hunting for a typo in a field whose real problem is that it
        // holds eleven project IDs.
        if value.count > maximumLength {
            return .tooLong(length: value.count)
        }

        let disallowed = Set(value.filter { !$0.isASCII || !($0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-") })
        if !disallowed.isEmpty {
            return .disallowedCharacters(disallowed)
        }
        if value.count < minimumLength {
            return .tooShort(length: value.count)
        }
        guard let first = value.first, first.isLetter else {
            return .invalidFirstCharacter
        }
        if value.hasSuffix("-") {
            return .trailingHyphen
        }
        return nil
    }

    static func isValid(_ rawValue: String) -> Bool {
        failure(for: rawValue) == nil
    }
}
