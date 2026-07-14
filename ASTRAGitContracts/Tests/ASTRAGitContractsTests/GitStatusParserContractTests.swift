import Testing
@testable import ASTRAGitContracts

@Suite("Git Status Parser Contracts")
struct GitStatusParserContractTests {
    @Test("Porcelain parser preserves staged unstaged conflict and untracked entries")
    func parsesPorcelainEntries() {
        let output = """
         M unstaged.swift
        M  staged.swift
        UU conflicted.swift
        ?? new.swift
        """

        let files = GitStatusParser.parsePorcelain(output)

        #expect(files == [
            GitStatusFile(relativePath: "unstaged.swift", status: "M", isStaged: false),
            GitStatusFile(relativePath: "staged.swift", status: "M", isStaged: true),
            GitStatusFile(relativePath: "conflicted.swift", status: "UU", isStaged: false),
            GitStatusFile(relativePath: "new.swift", status: "?", isStaged: false)
        ])
    }

    @Test("NUL porcelain parser keeps rename and copy source paths")
    func parsesPorcelainZRenameAndCopyEntries() {
        let output = [
            "R  Sources/NewName.swift",
            "Sources/OldName.swift",
            "C  Sources/Copied.swift",
            "Sources/Original.swift"
        ].joined(separator: "\0") + "\0"

        let files = GitStatusParser.parsePorcelainZ(output)

        #expect(files == [
            GitStatusFile(
                relativePath: "Sources/NewName.swift",
                status: "R",
                isStaged: true,
                originalPath: "Sources/OldName.swift"
            ),
            GitStatusFile(
                relativePath: "Sources/Copied.swift",
                status: "C",
                isStaged: true,
                originalPath: "Sources/Original.swift"
            )
        ])
    }
}
