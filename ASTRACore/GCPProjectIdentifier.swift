import Foundation

/// Admission control on the value the workspace wizard hands to
/// `gcloud projects describe`.
///
/// A production field arrived holding `som-rit-phi-starr-dev` with a second
/// project ID appended to it seven times over. It was shipped verbatim as one
/// argument, and the user got `INVALID_ARGUMENT` from Google — a message about
/// their Google account for what was a garbled text field. Nothing between the
/// field and the subprocess ever asked whether the value could be a project at
/// all.
///
/// The rules are Google's own, and deliberately shallow: this decides whether a
/// value is *shaped* like a project, never whether it exists. Only `gcloud` can
/// answer the second question, and this must not stand in its way.
///
/// - A project ID is 6–30 characters of lowercase letters, digits and hyphens,
///   starts with a letter, and does not end with a hyphen.
/// - A project *number* — all digits — is also accepted by
///   `gcloud projects describe`, so it is accepted here too.
///
/// Anything else is refused before the subprocess runs, with a reason the user
/// can act on.
public enum GCPProjectIdentifier {
    public static let minimumLength = 6
    public static let maximumLength = 30

    /// Why this value cannot be a GCP project, or `nil` if it plausibly is one.
    ///
    /// An empty value returns `nil`: "you have not filled this in yet" is the
    /// caller's message to write, and it is not the same as "what you typed is
    /// wrong".
    public static func rejectionReason(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Project numbers are a legitimate argument and follow none of the ID
        // rules below, so they are settled first.
        if trimmed.allSatisfy(\.isASCIINumber) { return nil }

        if trimmed.contains(where: \.isWhitespace) {
            return "A GCP project ID cannot contain spaces. Enter one project, like my-project-123."
        }
        if trimmed.count > maximumLength {
            // The case that started this. Naming the length is what tells
            // someone their field holds more than one project.
            return """
                A GCP project ID is at most \(maximumLength) characters; this one is \
                \(trimmed.count). Check the field holds a single project ID, like \
                my-project-123.
                """
        }
        if trimmed.count < minimumLength {
            return "A GCP project ID is at least \(minimumLength) characters."
        }
        guard let first = trimmed.first, first.isASCIILowercaseLetter else {
            return "A GCP project ID starts with a lowercase letter."
        }
        if trimmed.hasSuffix("-") {
            return "A GCP project ID cannot end with a hyphen."
        }
        if let offending = trimmed.first(where: { !$0.isPermittedInProjectID }) {
            return """
                A GCP project ID uses only lowercase letters, digits and hyphens; \
                this one contains "\(offending)".
                """
        }
        return nil
    }

    public static func isPlausible(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && rejectionReason(for: trimmed) == nil
    }

    /// A version of an untrusted value that is safe to put in a sentence.
    ///
    /// The failure message used to interpolate the raw field while the process
    /// output beside it was newline-collapsed and truncated — so the one part
    /// of the message that could be arbitrarily long and arbitrarily shaped was
    /// the only part nothing cleaned up.
    public static func displayValue(_ value: String, maximumLength: Int = 48) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maximumLength else { return collapsed }
        return collapsed.prefix(maximumLength) + "…"
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
    var isASCIILowercaseLetter: Bool { isASCII && isLowercase && isLetter }
    var isPermittedInProjectID: Bool {
        isASCIINumber || isASCIILowercaseLetter || self == "-"
    }
}
