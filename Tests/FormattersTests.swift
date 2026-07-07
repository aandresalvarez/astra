import Testing
import ASTRAPersistence
import ASTRACore
import ASTRAModels
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

    @Test("fileIcon for Quarto markdown")
    func quartoMarkdownIcon() { #expect(Formatters.fileIcon(for: "starr_common.qmd") == "doc.plaintext") }

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

    @Test("sidebarTaskTitle preserves word-boundary prefix and suffix")
    func sidebarTaskTitleKeepsScannableEdges() {
        let input = "Count patients in two destination cohorts with BigQuery"
        let output = Formatters.sidebarTaskTitle(input)

        #expect(output == "Count · patients … with BigQuery")
    }

    @Test("sidebarTaskTitle keeps suffix for similarly-prefixed tasks")
    func sidebarTaskTitleKeepsDisambiguatingSuffix() {
        let input = "Query BigQuery MRN destination table row access for cohort export"
        let output = Formatters.sidebarTaskTitle(input)

        #expect(output == "Query · BigQuery … cohort export")
    }

    @Test("sidebarTaskTitlePresentation separates generic action from task object")
    func sidebarTaskTitlePresentationSeparatesGenericAction() {
        let output = Formatters.sidebarTaskTitlePresentation("Create a component smoke file")

        #expect(output.prefix == "Create")
        #expect(output.primary == "component smoke file")
        #expect(output.displayTitle == "Create · component smoke file")
        #expect(output.fullTitle == "Create a component smoke file")
    }

    @Test("sidebarTaskTitlePresentation keeps repeated-prefix tasks distinguishable")
    func sidebarTaskTitlePresentationKeepsRepeatedPrefixTasksDistinguishable() {
        let titles = [
            "Create component smoke file",
            "Create local smoke file",
            "Create HEDIS 2030 agents",
            "Build basic login HTML"
        ]
        let presentations = titles.map { Formatters.sidebarTaskTitlePresentation($0) }

        #expect(presentations.map(\.prefix) == ["Create", "Create", "Create", "Build"])
        #expect(presentations.map(\.primary) == [
            "component smoke file",
            "local smoke file",
            "HEDIS 2030 agents",
            "basic login HTML"
        ])
        #expect(presentations.allSatisfy { !$0.displayTitle.contains("…") })
    }

    @Test("sidebarTaskTitlePresentation keeps ordinary prose readable")
    func sidebarTaskTitlePresentationKeepsOrdinaryProseReadable() {
        let output = Formatters.sidebarTaskTitlePresentation(
            "Create component smoke file"
        )

        #expect(output.primary == "component smoke file")
        #expect(!output.primary.contains(" … "))
    }

    @Test("sidebarTaskTitlePresentation collapses exact repeated title halves")
    func sidebarTaskTitlePresentationCollapsesRepeatedTitleHalves() {
        let output = Formatters.sidebarTaskTitlePresentation(
            "Build 3D Rubik's cube solverBuild 3D Rubik's cube solver"
        )

        #expect(output.prefix == "Build")
        #expect(output.primary == "3D Rubik's cube solver")
        #expect(output.fullTitle == "Build 3D Rubik's cube solverBuild 3D Rubik's cube solver")
    }
}
