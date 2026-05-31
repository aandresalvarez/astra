import Foundation
import Testing
@testable import ASTRA

@Suite("Git Authoring Service")
struct GitAuthoringServiceTests {

    // MARK: - Commit suggestion parser — prefixed output

    @Test("Parses well-formed prefixed commit suggestion")
    func parsesPrefixedCommitSuggestion() {
        let output = """
        Some narration line.
        ASTRA_COMMIT_SUGGESTION {"subject":"Add sync row","body":"Combines pull and push into a single action.","type":"feat"}
        """
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Add sync row")
        #expect(parsed?.type == "feat")
        #expect(parsed?.body == "Combines pull and push into a single action.")
    }

    @Test("Parses prefixed commit suggestion with leading whitespace on prefix line")
    func parsesPrefixedCommitWithLeadingWhitespace() {
        let output = "   ASTRA_COMMIT_SUGGESTION {\"subject\":\"Fix\",\"body\":\"\",\"type\":\"fix\"}"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Fix")
    }

    @Test("Parses prefixed commit when followed by trailing text")
    func parsesPrefixedCommitWithTrailingText() {
        let output = """
        ASTRA_COMMIT_SUGGESTION {"subject":"Refactor","body":"","type":"refactor"}
        Some trailing narration.
        """
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Refactor")
        #expect(parsed?.type == "refactor")
    }

    // MARK: - Commit suggestion parser — unprefixed fallback

    @Test("Falls back to first JSON object when prefix is missing")
    func parsesUnprefixedCommitSuggestion() {
        let output = "Sure, here is the result:\n{\"subject\":\"Fix typo\",\"body\":\"\",\"type\":\"fix\"}"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Fix typo")
        #expect(parsed?.type == "fix")
    }

    @Test("Falls back to first JSON object when multiple objects present")
    func parsesFirstJSONObjectOnly() {
        let output = "{\"subject\":\"First\",\"body\":\"\",\"type\":\"feat\"} and also {\"subject\":\"Second\",\"body\":\"\",\"type\":\"fix\"}"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "First")
    }

    @Test("Handles JSON with nested braces in body")
    func parsesJSONWithNestedBraces() {
        let output = "{\"subject\":\"Add config\",\"body\":\"Uses {\\\"key\\\": \\\"val\\\"}\",\"type\":\"feat\"}"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Add config")
        #expect(parsed?.body.contains("{") == true)
    }

    @Test("Handles JSON with escaped quotes in subject")
    func parsesJSONWithEscapedQuotes() {
        let output = "{\"subject\":\"Fix \\\"edge\\\" case\",\"body\":\"\",\"type\":\"fix\"}"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Fix \"edge\" case")
    }

    // MARK: - Commit suggestion parser — failure cases

    @Test("Returns nil for malformed JSON")
    func parsesMalformedCommitSuggestion() {
        let output = "ASTRA_COMMIT_SUGGESTION {\"subject\":\"oops\""
        #expect(GitAuthoringParser.parseCommit(from: output) == nil)
    }

    @Test("Returns nil when no JSON is present")
    func parsesEmptyCommitSuggestion() {
        #expect(GitAuthoringParser.parseCommit(from: "Nothing to see here") == nil)
    }

    @Test("Returns nil for empty string")
    func parsesEmptyString() {
        #expect(GitAuthoringParser.parseCommit(from: "") == nil)
    }

    @Test("Returns nil for JSON missing required fields")
    func parsesMissingFields() {
        let output = "{\"subject\":\"Only subject\"}"
        #expect(GitAuthoringParser.parseCommit(from: output) == nil)
    }

    @Test("Returns nil for JSON with wrong field types")
    func parsesWrongTypes() {
        let output = "{\"subject\":123,\"body\":true,\"type\":\"fix\"}"
        #expect(GitAuthoringParser.parseCommit(from: output) == nil)
    }

    @Test("Extracts JSON object embedded in array via fallback")
    func parsesArrayWrappedJSON() {
        let output = "[{\"subject\":\"Fix\",\"body\":\"\",\"type\":\"fix\"}]"
        let parsed = GitAuthoringParser.parseCommit(from: output)
        #expect(parsed?.subject == "Fix")
    }

    // MARK: - CommitSuggestion model

    @Test("Normalized commit truncates over-long subjects to 72 chars")
    func normalizedCommitTruncatesSubject() {
        let suggestion = CommitSuggestion(
            subject: String(repeating: "a", count: 200),
            body: "  body  ",
            type: "feat"
        )
        let normalized = suggestion.normalized()
        #expect(normalized.subject.count == 72)
        #expect(normalized.body == "body")
    }

    @Test("Normalized commit preserves subjects at exactly 72 chars")
    func normalizedCommitPreserves72Chars() {
        let subject = String(repeating: "x", count: 72)
        let suggestion = CommitSuggestion(subject: subject, body: "", type: "feat")
        #expect(suggestion.normalized().subject.count == 72)
    }

    @Test("Normalized commit trims whitespace from all fields")
    func normalizedCommitTrimsWhitespace() {
        let suggestion = CommitSuggestion(
            subject: "  Add feature  ",
            body: "\n  Some body  \n",
            type: "  feat  "
        )
        let normalized = suggestion.normalized()
        #expect(normalized.subject == "Add feature")
        #expect(normalized.body == "Some body")
        #expect(normalized.type == "feat")
    }

    @Test("Formatted commit joins subject and body with blank line")
    func formattedCommitMessage() {
        let suggestion = CommitSuggestion(subject: "Subj", body: "Body line", type: "feat")
        #expect(suggestion.formatted == "Subj\n\nBody line")
    }

    @Test("Formatted commit omits body when empty")
    func formattedCommitOmitsEmptyBody() {
        let bodyless = CommitSuggestion(subject: "Subj", body: "", type: "feat")
        #expect(bodyless.formatted == "Subj")
    }

    @Test("Formatted commit omits body when whitespace-only")
    func formattedOmitsWhitespaceBody() {
        let suggestion = CommitSuggestion(subject: "Fix bug", body: "   \n  ", type: "fix")
        #expect(suggestion.formatted == "Fix bug")
    }

    // MARK: - PR suggestion parser

    @Test("Parses well-formed prefixed PR suggestion")
    func parsesPrefixedPRSuggestion() {
        let output = """
        ASTRA_PR_SUGGESTION {"title":"Add Repository panel","body":"## Summary\\nAdds the panel."}
        """
        let parsed = GitAuthoringParser.parsePR(from: output)
        #expect(parsed?.title == "Add Repository panel")
        #expect(parsed?.body.contains("## Summary") == true)
    }

    @Test("Parses PR suggestion via JSON fallback")
    func parsesUnprefixedPRSuggestion() {
        let output = "Here you go:\n{\"title\":\"Refactor auth\",\"body\":\"Cleans up middleware.\"}"
        let parsed = GitAuthoringParser.parsePR(from: output)
        #expect(parsed?.title == "Refactor auth")
        #expect(parsed?.body == "Cleans up middleware.")
    }

    @Test("Returns nil for invalid PR JSON")
    func parsesInvalidPRSuggestion() {
        #expect(GitAuthoringParser.parsePR(from: "ASTRA_PR_SUGGESTION not json") == nil)
    }

    @Test("Returns nil for PR JSON missing title")
    func parsesPRMissingTitle() {
        let output = "{\"body\":\"Only body\"}"
        #expect(GitAuthoringParser.parsePR(from: output) == nil)
    }

    @Test("Parses PR with multiline markdown body")
    func parsesPRWithMultilineBody() {
        let output = """
        ASTRA_PR_SUGGESTION {"title":"Add feature","body":"## Summary\\n- Item 1\\n- Item 2\\n\\n## Changes\\n- Changed X"}
        """
        let parsed = GitAuthoringParser.parsePR(from: output)
        #expect(parsed?.title == "Add feature")
        #expect(parsed?.body.contains("## Summary") == true)
        #expect(parsed?.body.contains("## Changes") == true)
    }

    // MARK: - PRSuggestion model

    @Test("PRSuggestion normalized trims whitespace from title and body")
    func prSuggestionNormalized() {
        let suggestion = PRSuggestion(title: "  Add feature  ", body: "  ## Summary\nDone  ")
        let normalized = suggestion.normalized()
        #expect(normalized.title == "Add feature")
        #expect(normalized.body == "## Summary\nDone")
    }

    @Test("PRSuggestion normalized handles empty fields")
    func prSuggestionNormalizedEmpty() {
        let suggestion = PRSuggestion(title: "", body: "")
        let normalized = suggestion.normalized()
        #expect(normalized.title == "")
        #expect(normalized.body == "")
    }

    // MARK: - Prompt builders

    @Test("Commit prompt includes diff and recent commit subjects")
    func commitPromptIncludesContext() {
        let prompt = GitAuthoringPromptBuilder.commitPrompt(
            diff: "diff --git a/foo b/foo",
            recentSubjects: ["fix: bug", "feat: thing"]
        )
        #expect(prompt.contains("diff --git a/foo b/foo"))
        #expect(prompt.contains("fix: bug"))
        #expect(prompt.contains("feat: thing"))
        #expect(prompt.contains("ASTRA_COMMIT_SUGGESTION"))
    }

    @Test("Commit prompt handles empty recent subjects")
    func commitPromptEmptyRecent() {
        let prompt = GitAuthoringPromptBuilder.commitPrompt(diff: "diff", recentSubjects: [])
        #expect(prompt.contains("(no recent commits)"))
    }

    @Test("Commit prompt includes JSON format instruction")
    func commitPromptIncludesFormatInstruction() {
        let prompt = GitAuthoringPromptBuilder.commitPrompt(diff: "diff", recentSubjects: [])
        #expect(prompt.contains("\"subject\""))
        #expect(prompt.contains("\"body\""))
        #expect(prompt.contains("\"type\""))
    }

    @Test("Commit prompt forbids tool use and exploration")
    func commitPromptForbidsToolUse() {
        let prompt = GitAuthoringPromptBuilder.commitPrompt(
            diff: "diff --git a/foo b/foo",
            recentSubjects: ["fix: prior"]
        )
        #expect(prompt.contains("Do NOT use any tools"))
        #expect(prompt.contains("Answer immediately"))
        #expect(prompt.contains("Staged diff:"))
    }

    @Test("Commit prompt does not invite repository exploration")
    func commitPromptDoesNotInviteExploration() {
        let prompt = GitAuthoringPromptBuilder.commitPrompt(diff: "diff", recentSubjects: [])
        #expect(!prompt.contains("Read the staged diff"))
        #expect(!prompt.contains("(truncated)"))
    }

    @Test("PR prompt forbids tool use and exploration")
    func prPromptForbidsToolUse() {
        let prompt = GitAuthoringPromptBuilder.prPrompt(
            branch: "feat/x",
            base: "main",
            log: "- feat: thing",
            diffStat: "1 file changed"
        )
        #expect(prompt.contains("Do NOT use any tools"))
        #expect(prompt.contains("Answer immediately"))
    }

    @Test("PR prompt includes branch, base, log and diffstat")
    func prPromptIncludesContext() {
        let prompt = GitAuthoringPromptBuilder.prPrompt(
            branch: "feature/x",
            base: "origin/main",
            log: "- feat: do thing",
            diffStat: " 1 file changed, 1 insertion(+)"
        )
        #expect(prompt.contains("feature/x"))
        #expect(prompt.contains("origin/main"))
        #expect(prompt.contains("- feat: do thing"))
        #expect(prompt.contains("1 file changed"))
        #expect(prompt.contains("ASTRA_PR_SUGGESTION"))
    }

    @Test("PR prompt marks empty log/diffstat instead of emitting blanks")
    func prPromptEmpty() {
        let prompt = GitAuthoringPromptBuilder.prPrompt(
            branch: "b",
            base: "origin/main",
            log: "",
            diffStat: ""
        )
        #expect(prompt.contains("(empty)"))
    }

    @Test("PR prompt includes markdown section instructions")
    func prPromptIncludesSections() {
        let prompt = GitAuthoringPromptBuilder.prPrompt(
            branch: "feat/x", base: "main", log: "log", diffStat: "stat"
        )
        #expect(prompt.contains("## Summary"))
        #expect(prompt.contains("## Changes"))
    }

    // MARK: - GitAuthoringError descriptions

    @Test("emptyDiff error has descriptive message")
    func emptyDiffError() {
        let error = GitAuthoringError.emptyDiff
        #expect(error.errorDescription?.contains("nothing to summarize") == true)
    }

    @Test("helperModelUnavailable error mentions configuration")
    func helperModelUnavailableError() {
        let error = GitAuthoringError.helperModelUnavailable
        #expect(error.errorDescription?.contains("Configure") == true)
    }

    @Test("providerFailed error includes message")
    func providerFailedError() {
        let error = GitAuthoringError.providerFailed("connection refused")
        #expect(error.errorDescription?.contains("connection refused") == true)
    }

    @Test("invalidOutput error includes detail")
    func invalidOutputError() {
        let error = GitAuthoringError.invalidOutput("garbage data")
        #expect(error.errorDescription?.contains("garbage data") == true)
    }

    // MARK: - AgentGitAuthoringService — empty diff guard

    @Test("suggestCommitMessage throws emptyDiff for empty diff")
    func suggestCommitThrowsOnEmptyDiff() async {
        let service = AgentGitAuthoringService(
            utilityRuntime: .claude()
        )
        do {
            _ = try await service.suggestCommitMessage(
                repoPath: "/tmp/nonexistent",
                diff: "",
                recentSubjects: []
            )
            Issue.record("Expected emptyDiff error")
        } catch let error as GitAuthoringError {
            #expect(error == .emptyDiff)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("suggestCommitMessage throws emptyDiff for whitespace-only diff")
    func suggestCommitThrowsOnWhitespaceDiff() async {
        let service = AgentGitAuthoringService(
            utilityRuntime: .claude()
        )
        do {
            _ = try await service.suggestCommitMessage(
                repoPath: "/tmp/nonexistent",
                diff: "   \n\t  \n  ",
                recentSubjects: []
            )
            Issue.record("Expected emptyDiff error")
        } catch let error as GitAuthoringError {
            #expect(error == .emptyDiff)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Git status porcelain parsing

@Suite("Git Status Parsing")
struct GitStatusParsingTests {
    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return Int(process.terminationStatus)
        } catch {
            return -1
        }
    }

    private func makeTempGitRepo() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-status-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(runShell("git init -b main", in: path) == 0)
        return path
    }

    @Test("Parses staged modified file")
    func parseStagedModified() {
        let output = "M  file.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "file.swift")
        #expect(files[0].status == "M")
        #expect(files[0].isStaged == true)
    }

    @Test("Parses unstaged modified file")
    func parseUnstagedModified() {
        let output = " M file.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "file.swift")
        #expect(files[0].status == "M")
        #expect(files[0].isStaged == false)
    }

    @Test("Parses file modified in both index and worktree")
    func parseBothModified() {
        let output = "MM file.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 2)
        let staged = files.first(where: { $0.isStaged })
        let unstaged = files.first(where: { !$0.isStaged })
        #expect(staged?.status == "M")
        #expect(unstaged?.status == "M")
    }

    @Test("Parses staged added file")
    func parseStagedAdded() {
        let output = "A  newfile.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].status == "A")
        #expect(files[0].isStaged == true)
    }

    @Test("Repository diff presentation classifies friendly colored lines")
    func repositoryDiffPresentationClassifiesLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         final class Example {
        -    let title = "Old"
        +    let title = "New"
        +    let count = 1
         }
        """

        let lines = RepositoryDiffPresentation.lines(from: diff)

        #expect(lines[0].kind == .fileHeader)
        #expect(lines[1].kind == .fileHeader)
        #expect(lines[2].kind == .fileHeader)
        #expect(lines[3].kind == .fileHeader)
        #expect(lines[4].kind == .hunkHeader)
        #expect(lines[5].kind == .context)
        #expect(lines[6].kind == .deletion)
        #expect(lines[7].kind == .addition)
        #expect(lines[8].kind == .addition)
        #expect(lines[9].kind == .context)
    }

    @Test("Repository diff presentation preserves hunk patches")
    func repositoryDiffPresentationPreservesHunkPatches() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
        -old
        +new
        @@ -8,2 +8,3 @@
         keep
        +added
        """

        let hunks = RepositoryDiffPresentation.hunks(from: diff)

        #expect(hunks.count == 2)
        #expect(hunks[0].lines.first?.kind == .hunkHeader)
        #expect(hunks[0].lines.contains { $0.kind == .deletion })
        #expect(hunks[0].lines.contains { $0.kind == .addition })
        #expect(hunks[0].patch.hasPrefix("diff --git a/file.swift b/file.swift\nindex 1111111..2222222 100644\n--- a/file.swift\n+++ b/file.swift\n@@ -1,2 +1,2 @@"))
        #expect(hunks[0].patch.hasSuffix("+new\n"))
        #expect(hunks[1].patch.contains("@@ -8,2 +8,3 @@"))
        #expect(hunks[1].patch.hasSuffix("+added\n"))
    }

    @Test("Repository diff presentation preserves long source lines")
    func repositoryDiffPresentationPreservesLongSourceLines() {
        let longLine = "+        #expect(task.goal.contains(\"re-fetch the latest unresolved GitHub review comments before editing and preserve every diagnostic URL\"))"
        let diff = """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,1 +1,2 @@
         context
        \(longLine)
        """

        let lines = RepositoryDiffPresentation.lines(from: diff)
        let addedLine = lines.first { $0.kind == .addition }

        #expect(addedLine?.text == longLine)
    }

    @Test("Parses staged deleted file")
    func parseStagedDeleted() {
        let output = "D  removed.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].status == "D")
        #expect(files[0].isStaged == true)
    }

    @Test("Parses untracked file as unstaged only — regression guard")
    func parseUntrackedFile() {
        let output = "?? newfile.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "newfile.swift")
        #expect(files[0].status == "?")
        #expect(files[0].isStaged == false)
    }

    @Test("Untracked files must never appear as staged — regression")
    func untrackedNeverStaged() {
        let output = "?? untracked.txt\n?? another.txt"
        let files = GitService.parseStatusPorcelain(output)
        let stagedFiles = files.filter { $0.isStaged }
        #expect(stagedFiles.isEmpty, "Untracked files must not be marked as staged")
    }

    @Test("Mixed status: staged, unstaged, and untracked files")
    func parseMixedStatus() {
        let output = """
        M  staged.swift
         M unstaged.swift
        A  added.swift
        ?? untracked.swift
        D  deleted.swift
        """
        let files = GitService.parseStatusPorcelain(output)

        let staged = files.filter { $0.isStaged }
        let unstaged = files.filter { !$0.isStaged }

        #expect(staged.count == 3)
        #expect(unstaged.count == 2)
        #expect(staged.contains(where: { $0.relativePath == "staged.swift" && $0.status == "M" }))
        #expect(staged.contains(where: { $0.relativePath == "added.swift" && $0.status == "A" }))
        #expect(staged.contains(where: { $0.relativePath == "deleted.swift" && $0.status == "D" }))
        #expect(unstaged.contains(where: { $0.relativePath == "unstaged.swift" && $0.status == "M" }))
        #expect(unstaged.contains(where: { $0.relativePath == "untracked.swift" && $0.status == "?" }))
    }

    @Test("Handles empty porcelain output (clean tree)")
    func parseEmptyOutput() {
        #expect(GitService.parseStatusPorcelain("").isEmpty)
    }

    @Test("Handles renamed file in porcelain")
    func parseRenamedFile() {
        let output = "R  old.swift -> new.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].status == "R")
        #expect(files[0].isStaged == true)
        #expect(files[0].relativePath == "new.swift")
        #expect(files[0].originalPath == "old.swift")
        #expect(files[0].displayPath == "old.swift -> new.swift")
        #expect(files[0].pathspecs == ["old.swift", "new.swift"])
    }

    @Test("NUL porcelain parses rename target and skips source payload")
    func parseNulRenamedFile() {
        let output = "R  new.swift\0old.swift\0"
        let files = GitService.parseStatusPorcelainZ(output)
        #expect(files.count == 1)
        #expect(files[0].status == "R")
        #expect(files[0].isStaged == true)
        #expect(files[0].relativePath == "new.swift")
        #expect(files[0].originalPath == "old.swift")
    }

    @Test("Conflicted porcelain status is a single unstaged conflict row")
    func parseConflictedFile() {
        let output = "UU conflicted.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "conflicted.swift")
        #expect(files[0].status == "UU")
        #expect(files[0].isStaged == false)
        #expect(files[0].isConflict == true)
    }

    @Test("Git status file identity is stable across refreshes")
    func statusFileIdentityIsStable() {
        let first = GitStatusFile(relativePath: "Astra/Services/GitService.swift", status: "M", isStaged: false)
        let second = GitStatusFile(relativePath: "Astra/Services/GitService.swift", status: "M", isStaged: false)
        #expect(first.id == second.id)
    }

    @Test("Git repository identity is stable across scans")
    func repositoryIdentityIsStable() {
        let path = "/tmp/astra-repo-\(UUID().uuidString)"
        let first = GitRepositoryInfo(name: "Astra", path: path, subtitle: "Root", roleLabel: "Primary")
        let second = GitRepositoryInfo(name: "Astra", path: path, subtitle: "Root", roleLabel: "Primary")

        #expect(first.id == second.id)
        #expect(first.id == WorkspacePathPresentation.standardizedPath(path))
    }

    @Test("Untracked file diff synthesizes an add-style preview")
    func untrackedFileDiffSynthesizesPreview() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let fileURL = URL(fileURLWithPath: repo).appendingPathComponent("new.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let file = GitStatusFile(relativePath: "new.swift", status: "?", isStaged: false)
        let diff = await GitService.shared.getFileDiff(at: repo, file: file)

        #expect(diff.kind == .untracked)
        #expect(diff.hasDiff)
        #expect(diff.diff.contains("new file mode"))
        #expect(diff.diff.contains("+let value = 1"))
    }

    @Test("Tracked file diff is scoped to the selected changed file")
    func trackedFileDiffIsScopedToFile() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        try "old\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("edited.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "same\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(runShell("git add edited.txt other.txt && git -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' commit -m init", in: repo) == 0)

        try "new\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("edited.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "changed but not selected\n".write(
            to: URL(fileURLWithPath: repo).appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        let file = GitStatusFile(relativePath: "edited.txt", status: "M", isStaged: false)
        let diff = await GitService.shared.getFileDiff(at: repo, file: file)

        #expect(diff.kind == .unstaged)
        #expect(diff.diff.contains("--- a/edited.txt"))
        #expect(diff.diff.contains("+++ b/edited.txt"))
        #expect(diff.diff.contains("-old"))
        #expect(diff.diff.contains("+new"))
        #expect(!diff.diff.contains("other.txt"))
    }

    @Test("Diff hunk patch can be applied to the git index")
    func diffHunkPatchCanBeAppliedToIndex() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let fileURL = URL(fileURLWithPath: repo).appendingPathComponent("edited.txt")
        try "old\n".write(to: fileURL, atomically: true, encoding: .utf8)
        #expect(runShell("git add edited.txt && git -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' commit -m init", in: repo) == 0)
        try "new\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let patch = """
        diff --git a/edited.txt b/edited.txt
        index 3367afd..3e75765 100644
        --- a/edited.txt
        +++ b/edited.txt
        @@ -1 +1 @@
        -old
        +new

        """
        try await GitService.shared.applyDiffPatchToIndex(patch, at: repo)
        let cached = await GitService.shared.getStagedDiff(at: repo, limit: 4096)

        #expect(cached.contains("+new"))
        #expect(cached.contains("-old"))
    }

    @Test("NUL porcelain preserves spaces and shell-sensitive file names")
    func parseNulPorcelainPreservesPaths() {
        let output = "?? --flag file.swift\0 M dir with spaces/file.swift\0"
        let files = GitService.parseStatusPorcelainZ(output)
        #expect(files.count == 2)
        #expect(files[0].relativePath == "--flag file.swift")
        #expect(files[0].isStaged == false)
        #expect(files[1].relativePath == "dir with spaces/file.swift")
        #expect(files[1].isStaged == false)
    }

    @Test("Skips lines shorter than 3 characters")
    func parseShortLines() {
        let output = "M\n \nM  valid.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "valid.swift")
    }

    @Test("Handles file paths with spaces")
    func parsePathsWithSpaces() {
        let output = "M  path with spaces/file name.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 1)
        #expect(files[0].relativePath == "path with spaces/file name.swift")
    }

    @Test("Staged add plus worktree modification")
    func parseStagedAddWithWorktreeModification() {
        let output = "AM newfile.swift"
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 2)
        #expect(files[0].isStaged == true)
        #expect(files[0].status == "A")
        #expect(files[1].isStaged == false)
        #expect(files[1].status == "M")
    }

    @Test("Large number of files parsed correctly")
    func parseManyFiles() {
        let lines = (0..<100).map { "M  file\($0).swift" }
        let output = lines.joined(separator: "\n")
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 100)
        #expect(files.allSatisfy { $0.isStaged && $0.status == "M" })
    }

    @Test("Only untracked files produces zero staged entries — regression scenario")
    func onlyUntrackedProducesNoStaged() {
        let output = """
        ?? file1.swift
        ?? file2.swift
        ?? dir/file3.swift
        """
        let files = GitService.parseStatusPorcelain(output)
        #expect(files.count == 3)
        #expect(files.allSatisfy { !$0.isStaged })
        #expect(files.allSatisfy { $0.status == "?" })
    }

    @Test("PR authoring context is byte-limited with a truncation marker")
    func contextLimitTruncatesByBytes() {
        let text = String(repeating: "abc", count: 200)
        let limited = GitService.limitedContext(text, maxBytes: 50)
        #expect(limited.utf8.count <= 70)
        #expect(limited.hasSuffix("...[truncated]"))
    }
}
