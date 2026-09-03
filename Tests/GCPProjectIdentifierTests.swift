import Foundation
import Testing
import ASTRACore

/// Covers the admission check that stands between the workspace wizard's GCP
/// project field and `gcloud projects describe`.
///
/// The bug it exists for: the field held `som-rit-phi-starr-dev` with a second
/// project ID appended seven times over, and every character of it was handed
/// to `gcloud` as a single argument. The user saw Google's `INVALID_ARGUMENT`,
/// which reads as a problem with their cloud account rather than with a text
/// field that had been pasted into repeatedly.
@Suite("GCP project identifier")
struct GCPProjectIdentifierTests {
    @Test("Ordinary project IDs are accepted")
    func plausibleIdentifiersPass() {
        for value in [
            "my-project-123",
            "som-rit-phi-starr-dev",
            "astra1",
            "a12345",
            String(repeating: "a", count: 30)
        ] {
            #expect(
                GCPProjectIdentifier.rejectionReason(for: value) == nil,
                "\(value) is a valid project ID and must not be refused"
            )
        }
    }

    /// `gcloud projects describe` takes a project number just as happily as an
    /// ID, and a number follows none of the ID rules — it is all digits and can
    /// be shorter than six characters.
    @Test("Project numbers are accepted")
    func projectNumbersPass() {
        #expect(GCPProjectIdentifier.rejectionReason(for: "123456789012") == nil)
        #expect(GCPProjectIdentifier.rejectionReason(for: "42") == nil)
    }

    /// The value that was actually in the field.
    @Test("A field holding several concatenated projects is refused by length")
    func repeatedPasteIsRefused() {
        let garbled = "som-rit-phi-starr-dev"
            + String(repeating: "upo-nero-phi-su-deid-jsl", count: 7)

        let reason = GCPProjectIdentifier.rejectionReason(for: garbled)
        #expect(reason != nil, "The value that produced INVALID_ARGUMENT in production was let through")
        #expect(reason?.contains("30") == true, "The reason should name the limit the value broke")
        #expect(
            reason?.contains(garbled) != true,
            "The reason must not echo the whole malformed value back into the UI"
        )
    }

    @Test("Malformed values are refused with a reason that names the rule")
    func malformedValuesAreRefused() {
        let cases: [(value: String, expectation: String)] = [
            ("my project", "spaces"),
            ("abc", "least"),
            ("1project", "lowercase letter"),
            ("My-Project-123", "lowercase letter"),
            ("my-project-", "hyphen"),
            ("my_project_1", "lowercase letters, digits and hyphens")
        ]
        for (value, expectation) in cases {
            let reason = GCPProjectIdentifier.rejectionReason(for: value)
            #expect(reason != nil, "\(value) should be refused")
            #expect(
                reason?.localizedCaseInsensitiveContains(expectation) == true,
                "\(value) was refused as \"\(reason ?? "")\", which never mentions \(expectation)"
            )
        }
    }

    /// "You have not filled this in" is the caller's message, and it is not the
    /// same thing as "what you typed is wrong". Conflating them would tell
    /// someone their empty field is malformed.
    @Test("An empty value is not treated as malformed")
    func emptyValueIsNotARejection() {
        #expect(GCPProjectIdentifier.rejectionReason(for: "") == nil)
        #expect(GCPProjectIdentifier.rejectionReason(for: "   \n ") == nil)
        #expect(!GCPProjectIdentifier.isPlausible(""))
        #expect(!GCPProjectIdentifier.isPlausible("   "))
    }

    @Test("Surrounding whitespace does not make a valid project invalid")
    func whitespaceIsTrimmed() {
        #expect(GCPProjectIdentifier.isPlausible("  my-project-123\n"))
    }

    /// The failure message used to interpolate the raw field while the process
    /// output beside it was collapsed and truncated — so the one part that
    /// could be arbitrarily long was the only part nothing cleaned up.
    @Test("Display values are collapsed and bounded")
    func displayValueIsBounded() {
        let long = String(repeating: "abcde-", count: 40)
        let shown = GCPProjectIdentifier.displayValue(long)
        #expect(shown.count <= 49, "Bounded to the limit plus the ellipsis, got \(shown.count)")
        #expect(shown.hasSuffix("…"))

        #expect(GCPProjectIdentifier.displayValue("one\ntwo\tthree") == "one two three")
        #expect(GCPProjectIdentifier.displayValue("my-project-123") == "my-project-123")
    }
}
