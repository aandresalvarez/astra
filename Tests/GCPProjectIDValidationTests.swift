import Testing
@testable import ASTRA

@Suite("GCP Project ID Validation")
struct GCPProjectIDValidationTests {
    @Test("Well-formed project IDs pass")
    func wellFormedIDsPass() {
        for value in ["example-project", "abc123", "a-b-c-1-2-3", "project1", String(repeating: "a", count: 30)] {
            #expect(GCPProjectIDValidation.failure(for: value) == nil, "\(value) should be valid")
        }
    }

    @Test("Surrounding whitespace is trimmed rather than rejected")
    func whitespaceIsTrimmed() {
        #expect(GCPProjectIDValidation.isValid("  example-project\n"))
    }

    @Test("Empty is reported as required, not as malformed")
    func emptyIsRequired() {
        #expect(GCPProjectIDValidation.failure(for: "") == .empty)
        #expect(GCPProjectIDValidation.failure(for: "   ") == .empty)
    }

    /// The value that motivated this type: a Settings field pasted into eleven
    /// times, 165 characters long, which the old non-emptiness check accepted.
    @Test("A repeatedly pasted project ID is reported as too long")
    func repeatedlyPastedIDIsTooLong() {
        let pasted = String(repeating: "example-project", count: 11)
        #expect(GCPProjectIDValidation.failure(for: pasted) == .tooLong(length: pasted.count))
        let message = GCPProjectIDValidation.Failure.tooLong(length: pasted.count).message
        #expect(message.contains("at most 30 characters"))
        #expect(message.contains("\(pasted.count)"))
        // Naming the likely cause is the point — the field looked fine because
        // the overflow was scrolled out of sight.
        #expect(message.contains("pasted into more than once"))
    }

    @Test("Length, first character, and trailing hyphen are each reported")
    func structuralRulesAreReported() {
        #expect(GCPProjectIDValidation.failure(for: "abc") == .tooShort(length: 3))
        #expect(GCPProjectIDValidation.failure(for: "1project") == .invalidFirstCharacter)
        #expect(GCPProjectIDValidation.failure(for: "project-") == .trailingHyphen)
    }

    @Test("Disallowed characters are listed so the user can find them")
    func disallowedCharactersAreListed() {
        guard case .disallowedCharacters(let characters)? = GCPProjectIDValidation.failure(for: "My_Project!") else {
            Issue.record("Expected disallowed characters for My_Project!")
            return
        }
        #expect(characters == Set(["M", "P", "_", "!"]))
        let message = GCPProjectIDValidation.Failure.disallowedCharacters(characters).message
        for character in characters {
            #expect(message.contains(String(character)))
        }
    }

    /// Length is checked before the positional rules on purpose: a value that
    /// is both over-long and starts with a digit should read as pasted twice,
    /// which is the actionable diagnosis.
    @Test("An over-long value is reported as too long, not as a bad first character")
    func lengthIsReportedBeforePositionalRules() {
        #expect(GCPProjectIDValidation.failure(for: String(repeating: "1", count: 40)) == .tooLong(length: 40))
    }
}
