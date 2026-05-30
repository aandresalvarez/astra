import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Coverage for creating a pull request directly via the `gh` CLI, including the
/// argument contract, URL extraction, and the missing-`gh` fallback signal.
@Suite("Git Pull Request Creation")
struct GitPullRequestTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-gh-pr-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Pure helpers

    @Test("normalizeBaseBranch strips the remote prefix")
    func normalizeBaseStripsRemote() {
        #expect(GitService.normalizeBaseBranch("origin/main") == "main")
        #expect(GitService.normalizeBaseBranch("origin/release/1.0") == "release/1.0")
        #expect(GitService.normalizeBaseBranch("main") == "main")
        #expect(GitService.normalizeBaseBranch("  origin/dev  ") == "dev")
    }

    @Test("firstURL extracts an http(s) URL from CLI output")
    func firstURLExtractsURL() {
        #expect(GitService.firstURL(in: "https://github.com/x/y/pull/3") == "https://github.com/x/y/pull/3")
        #expect(
            GitService.firstURL(in: "a pull request already exists: https://github.com/x/y/pull/9")
                == "https://github.com/x/y/pull/9"
        )
        #expect(GitService.firstURL(in: "no url here") == nil)
    }

    // MARK: - gh integration (fake CLI)

    @Test("createPullRequest invokes gh with the expected arguments and returns the URL")
    func createPullRequestRunsGh() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s\\n' 'https://github.com/example/repo/pull/42'
        exit 0
        """)

        let url = try await GitService.shared.createPullRequest(
            repoPath: repo,
            base: "origin/main",
            head: "feature/login",
            title: "Add login",
            body: "Implements login flow.",
            ghPathOverride: fakeGH.path
        )

        #expect(url == "https://github.com/example/repo/pull/42")

        let recordedArgs = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recordedArgs.contains("pr"))
        #expect(recordedArgs.contains("create"))
        #expect(recordedArgs.contains("--base"))
        #expect(recordedArgs.contains("main"))         // remote prefix stripped
        #expect(!recordedArgs.contains("origin/main"))
        #expect(recordedArgs.contains("--head"))
        #expect(recordedArgs.contains("feature/login"))
        #expect(recordedArgs.contains("Add login"))
    }

    @Test("createPullRequest surfaces an existing PR URL as success")
    func createPullRequestReturnsExistingURL() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        echo 'a pull request for branch already exists: https://github.com/example/repo/pull/7' 1>&2
        exit 1
        """)

        let url = try await GitService.shared.createPullRequest(
            repoPath: repo,
            base: "main",
            head: "feature/x",
            title: "X",
            body: "body",
            ghPathOverride: fakeGH.path
        )
        #expect(url == "https://github.com/example/repo/pull/7")
    }

    @Test("createPullRequest throws notInstalled when gh is unavailable")
    func createPullRequestThrowsWhenGhMissing() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        await #expect(throws: GitHubCLIError.self) {
            _ = try await GitService.shared.createPullRequest(
                repoPath: repo,
                base: "main",
                head: "feature/x",
                title: "X",
                body: "body",
                ghPathOverride: URL(fileURLWithPath: repo).appendingPathComponent("does-not-exist").path
            )
        }
    }
}
