import Testing
@testable import ASTRA

@Suite("Formatters")
struct FormattersTests {

    @Test("formatTokens handles zero")
    func zero() { #expect(Formatters.formatTokens(0) == "0") }

    @Test("formatTokens handles small numbers")
    func small() { #expect(Formatters.formatTokens(999) == "999") }

    @Test("formatTokens handles thousands")
    func thousands() { #expect(Formatters.formatTokens(1500) == "1.5k") }

    @Test("formatTokens handles exact thousand")
    func exactThousand() { #expect(Formatters.formatTokens(1000) == "1.0k") }

    @Test("formatTokens handles millions")
    func millions() { #expect(Formatters.formatTokens(1_500_000) == "1.5M") }

    @Test("fileIcon for Swift files")
    func swiftIcon() { #expect(Formatters.fileIcon(for: "/src/main.swift") == "swift") }

    @Test("fileIcon for Python files")
    func pythonIcon() { #expect(Formatters.fileIcon(for: "script.py") == "chevron.left.forwardslash.chevron.right") }

    @Test("fileIcon for JSON files")
    func jsonIcon() { #expect(Formatters.fileIcon(for: "data.json") == "doc.text") }

    @Test("fileIcon for unknown extension")
    func unknownIcon() { #expect(Formatters.fileIcon(for: "file.xyz") == "doc") }

    @Test("fileIcon for markdown")
    func markdownIcon() { #expect(Formatters.fileIcon(for: "README.md") == "doc.plaintext") }

    @Test("shortenIdentifierTokens preserves normal prose")
    func shortenIdentifierTokensLeavesProseAlone() {
        #expect(Formatters.shortenIdentifierTokens("Review the workspace import flow") == "Review the workspace import flow")
    }

    @Test("shortenIdentifierTokens middle-ellipsizes long identifiers")
    func shortenIdentifierTokensKeepsIdentifierHeadAndTail() {
        let input = "Inspect project-alpha-prod-eu.table_long_identifier_notes_archive"
        let output = Formatters.shortenIdentifierTokens(input)

        #expect(output == "Inspect project-al…es_archive")
    }
}
