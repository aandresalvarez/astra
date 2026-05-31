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

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return Int(process.terminationStatus)
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

    @Test("parseOpenPullRequest decodes the first open PR from gh JSON")
    func parseOpenPullRequestDecodes() {
        let json = """
        [{"number":42,"url":"https://github.com/example/repo/pull/42","title":"Add login","isDraft":false,"state":"OPEN"}]
        """
        let pr = GitService.parseOpenPullRequest(from: json)
        #expect(pr?.number == 42)
        #expect(pr?.url == "https://github.com/example/repo/pull/42")
        #expect(pr?.title == "Add login")
        #expect(pr?.isDraft == false)
    }

    @Test("parseOpenPullRequest returns nil for an empty list or garbage")
    func parseOpenPullRequestEmpty() {
        #expect(GitService.parseOpenPullRequest(from: "[]") == nil)
        #expect(GitService.parseOpenPullRequest(from: "") == nil)
        #expect(GitService.parseOpenPullRequest(from: "not json") == nil)
    }

    @Test("fromCreatedURL extracts the PR number from a created URL")
    func refFromCreatedURL() {
        let ref = GitHubPullRequestRef.fromCreatedURL("https://github.com/example/repo/pull/123")
        #expect(ref?.number == 123)
        #expect(ref?.url == "https://github.com/example/repo/pull/123")
        #expect(GitHubPullRequestRef.fromCreatedURL("https://github.com/example/repo") == nil)
    }

    @Test("pullRequestLocator extracts owner and repository from PR URL")
    func pullRequestLocatorParsesURL() {
        let locator = GitService.pullRequestLocator(from: "https://github.example.edu/coral/astra/pull/95")
        #expect(locator?.owner == "coral")
        #expect(locator?.name == "astra")
        #expect(GitService.pullRequestLocator(from: "https://github.example.edu/coral/astra") == nil)
    }

    @Test("decodePullRequestComments keeps unresolved review comments and conversation comments")
    func decodePullRequestComments() throws {
        let pr = GitHubPullRequestRef(
            number: 95,
            url: "https://github.com/coral/astra/pull/95",
            title: "Repository polish"
        )
        let json = """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "comments": {
                  "nodes": [
                    {
                      "author": { "login": "reviewer" },
                      "body": "Please add a diagnostic note.",
                      "createdAt": "2026-05-30T10:00:00Z",
                      "url": "https://github.com/coral/astra/pull/95#issuecomment-1"
                    }
                  ]
                },
                "reviewThreads": {
                  "nodes": [
                    {
                      "isResolved": false,
                      "path": "Astra/Services/GitService.swift",
                      "line": 120,
                      "comments": {
                        "nodes": [
                          {
                            "author": { "login": "copilot" },
                            "body": "This lookup should not swallow JSON failures.",
                            "createdAt": "2026-05-30T11:00:00Z",
                            "url": "https://github.com/coral/astra/pull/95#discussion_r1"
                          }
                        ]
                      }
                    },
                    {
                      "isResolved": true,
                      "path": "Astra/Views/Old.swift",
                      "line": 2,
                      "comments": {
                        "nodes": [
                          {
                            "author": { "login": "copilot" },
                            "body": "Resolved thread.",
                            "createdAt": "2026-05-30T12:00:00Z",
                            "url": "https://github.com/coral/astra/pull/95#discussion_r2"
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let summary = try #require(GitService.decodePullRequestComments(from: json, pullRequest: pr))
        #expect(summary.totalCommentCount == 2)
        #expect(summary.unresolvedThreadCount == 1)
        #expect(summary.issueCommentCount == 1)
        #expect(summary.comments.first?.locationLabel == "Astra/Services/GitService.swift:120")
        #expect(summary.comments.first?.preview.contains("swallow JSON failures") == true)
        #expect(summary.comments.contains { $0.body == "Resolved thread." } == false)
    }

    @Test("webURLFromRemoteURL supports common GitHub remote forms")
    func remoteURLConversion() {
        #expect(GitService.webURLFromRemoteURL("git@github.com:example/repo.git") == "https://github.com/example/repo")
        #expect(GitService.webURLFromRemoteURL("ssh://git@github.example.edu/example/repo.git") == "https://github.example.edu/example/repo")
        #expect(GitService.webURLFromRemoteURL("https://github.com/example/repo.git") == "https://github.com/example/repo")
        #expect(GitService.webURLFromRemoteURL("") == nil)
    }

    // MARK: - gh pr list lookup (fake CLI)

    @Test("findOpenPullRequest returns the branch's open PR via gh")
    func findOpenPullRequestFindsPR() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' '[{"number":42,"url":"https://github.com/example/repo/pull/42","title":"Add login","isDraft":false,"state":"OPEN"}]'
        exit 0
        """)

        let pr = await GitService.shared.findOpenPullRequest(
            repoPath: repo,
            head: "feature/login",
            ghPathOverride: fakeGH.path
        )

        #expect(pr?.number == 42)
        #expect(pr?.title == "Add login")

        let recordedArgs = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recordedArgs.contains("pr"))
        #expect(recordedArgs.contains("list"))
        #expect(recordedArgs.contains("--head"))
        #expect(recordedArgs.contains("feature/login"))
        #expect(recordedArgs.contains("--state"))
        #expect(recordedArgs.contains("open"))
    }

    @Test("findOpenPullRequest returns nil when no PR exists")
    func findOpenPullRequestNone() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s' '[]'
        exit 0
        """)

        let pr = await GitService.shared.findOpenPullRequest(
            repoPath: repo,
            head: "feature/x",
            ghPathOverride: fakeGH.path
        )
        #expect(pr == nil)
    }

    @Test("findOpenPullRequest returns nil when gh is unavailable")
    func findOpenPullRequestNoGh() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let pr = await GitService.shared.findOpenPullRequest(
            repoPath: repo,
            head: "feature/x",
            ghPathOverride: URL(fileURLWithPath: repo).appendingPathComponent("nope").path
        )
        #expect(pr == nil)
    }

    @Test("lookupOpenPullRequest distinguishes gh lookup failure from no PR")
    func lookupOpenPullRequestInvalidJSONIsUnavailable() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s' 'not-json'
        exit 0
        """)

        let head = "feature/lookup-log-\(UUID().uuidString.prefix(8))"
        let result = await GitService.shared.lookupOpenPullRequest(
            repoPath: repo,
            head: head,
            ghPathOverride: fakeGH.path
        )

        if case .unavailable(let detail) = result {
            #expect(detail.contains("could not read"))
        } else {
            Issue.record("Expected unavailable lookup result, got \(result)")
        }

        AppLogger.flushForTesting()
        let log = (try? String(contentsOf: AppLogger.mainLogFile, encoding: .utf8)) ?? ""
        #expect(log.contains("git.pull_request_lookup")
            && log.contains("head=\(head)")
            && log.contains("result=unavailable")
            && log.contains("reason=invalid_json"))
    }

    @Test("lookupPullRequestComments invokes gh GraphQL and returns actionable comments")
    func lookupPullRequestCommentsUsesGraphQL() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-comment-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        cat <<'JSON'
        {
          "data": {
            "repository": {
              "pullRequest": {
                "comments": { "nodes": [] },
                "reviewThreads": {
                  "nodes": [
                    {
                      "isResolved": false,
                      "path": "GitService.swift",
                      "line": 44,
                      "comments": {
                        "nodes": [
                          {
                            "author": { "login": "copilot" },
                            "body": "Use a stable identity here.",
                            "createdAt": "2026-05-30T11:00:00Z",
                            "url": "https://github.com/coral/astra/pull/95#discussion_r1"
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        JSON
        exit 0
        """)

        let pr = GitHubPullRequestRef(
            number: 95,
            url: "https://github.com/coral/astra/pull/95",
            title: "Repo panel"
        )
        let result = await GitService.shared.lookupPullRequestComments(
            repoPath: repo,
            pullRequest: pr,
            ghPathOverride: fakeGH.path
        )

        let summary = try #require(result.summary)
        #expect(summary.totalCommentCount == 1)
        #expect(summary.unresolvedThreadCount == 1)
        #expect(summary.comments[0].locationLabel == "GitService.swift:44")

        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("api"))
        #expect(args.contains("graphql"))
        #expect(args.contains("owner=coral"))
        #expect(args.contains("name=astra"))
        #expect(args.contains("number=95"))
    }

    @Test("default remote and web URL do not require origin")
    func defaultRemoteDoesNotRequireOrigin() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(runShell("git init -b main", in: repo) == 0)
        #expect(runShell("git remote add upstream git@github.example.edu:example/repo.git", in: repo) == 0)

        let remote = await GitService.shared.getDefaultRemote(at: repo)
        let url = await GitService.shared.getRemoteURL(at: repo, remote: remote)

        #expect(remote == "upstream")
        #expect(url == "https://github.example.edu/example/repo")
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
