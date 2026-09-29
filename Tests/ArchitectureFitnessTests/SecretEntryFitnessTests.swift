import Foundation
import Testing

/// Guards the rule behind `SecretEntryField`: a credential being typed into
/// ASTRA is visible unless the person hides it.
///
/// Every credential field used to be a bare `SecureField`, which gave no way to
/// see a mistyped value. The failure that surfaced it was Jira's `JIRA_EMAIL`
/// — an address, kept in the Keychain beside the API token — refused at save
/// with "should be an email address" while the person could not see what they
/// had typed. Fixing the fields one screen at a time would leave the next
/// screen to repeat it, so the fields now share one component and this scan
/// fails if a masked-only field is built anywhere else.
///
/// This target has no package dependencies, so it is a source scan. The
/// behavioural half — that the component renders plain text by default and a
/// secure field once hidden — lives in `Tests/SecretEntryFieldTests.swift`.
@Suite("Secret entry fitness")
struct SecretEntryFitnessTests {
    /// The one file allowed to construct a masked field: the component that
    /// pairs it with a plain `TextField` and the toggle between them.
    private let componentFile = "Astra/Views/Components/SecretEntryField.swift"

    @Test("Credential entry never builds a masked-only field outside SecretEntryField")
    func credentialEntryNeverBuildsAMaskedOnlyField() throws {
        let root = repositoryRoot()
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(componentFile).path),
            "SecretEntryField moved; update `componentFile` or this scan exempts nothing."
        )

        var violations: [String] = []
        for file in try swiftFiles(under: root.appendingPathComponent("Astra")) {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != componentFile else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            if buildsMaskedField(in: source) { violations.append(relative) }
        }

        #expect(
            violations.isEmpty,
            """
            These files build a masked-only field. Use `SecretEntryField` so the value being \
            typed is visible and can be hidden — a field that only shows bullets hides typos \
            in values like JIRA_EMAIL until the save is refused: \(violations.sorted())
            """
        )
    }

    /// The scan is text-based, so it is only worth what it catches. Rebuild each
    /// shape it was written for: if a future edit stops recognising one, the
    /// guard above has gone quiet without failing.
    @Test("The scan recognises every shape it was written to catch")
    func theScanRecognisesEveryShapeItWasWrittenToCatch() {
        // The five call sites this replaced, in their original form.
        #expect(buildsMaskedField(in: #"SecureField("value", text: $newCredValue)"#))
        #expect(buildsMaskedField(in: "            SecureField(prompt, text: text)\n                .textFieldStyle(.roundedBorder)"))
        #expect(buildsMaskedField(in: "SecureField(CapabilitySetupPresentation.credentialPlaceholder(for: hint), text: Binding("))
        // Split across lines, and the native control underneath it.
        #expect(buildsMaskedField(in: "SecureField\n    (\"value\", text: $x)"))
        #expect(buildsMaskedField(in: "let field = NSSecureTextField()"))

        // …and what must stay clean: the component itself, comments about the
        // control, and names that merely contain it.
        #expect(!buildsMaskedField(in: #"SecretEntryField("value", text: $newCredValue)"#))
        #expect(!buildsMaskedField(in: "/// a bare `SecureField`, so the behaviour cannot drift"))
        #expect(!buildsMaskedField(in: "    // address; `SecureField(` never allowed either."))
        #expect(!buildsMaskedField(in: "MySecureField(text: $x)"))
        #expect(!buildsMaskedField(in: "capabilitySecureFieldHelp(label)"))
    }

    // MARK: - Scanning

    /// True when `source` constructs a `SecureField` or `NSSecureTextField` in
    /// code. Line comments are skipped so documenting the control is not a
    /// violation, and the word boundary keeps `MySecureField(` out.
    private func buildsMaskedField(in source: String) -> Bool {
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return code.range(of: #"\bSecureField\s*\("#, options: .regularExpression) != nil
            || code.range(of: #"\bNSSecureTextField\b"#, options: .regularExpression) != nil
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}
