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
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
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
        #expect(GitService.normalizeBaseBranch("upstream/main", remote: "upstream") == "main")
        #expect(GitService.normalizeBaseBranch("feature/topic", remote: "upstream") == "feature/topic")
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

    @Test("decodeOpenPullRequests returns structured diagnostics for malformed payloads")
    func decodeOpenPullRequestsDiagnostics() {
        let missingNumber = """
        [{"url":"https://github.com/example/repo/pull/42","title":"Add login","isDraft":false,"state":"OPEN"}]
        """
        let missingNumberResult = GitService.decodeOpenPullRequestsResult(from: missingNumber)

        #expect(missingNumberResult.value == nil)
        #expect(missingNumberResult.diagnostic.status == .decodeFailed)
        #expect(missingNumberResult.diagnostic.typeName == "Array<GitHubPullRequestRef>")
        #expect(missingNumberResult.diagnostic.codingPath?.contains("number") == true)
        #expect(missingNumberResult.diagnostic.errorDescription?.contains("Missing key number") == true)

        let emptyResult = GitService.decodeOpenPullRequestsResult(from: "")
        #expect(emptyResult.value == nil)
        #expect(emptyResult.diagnostic.status == .emptyInput)
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
                      "path": "Astra/Services/Git/GitService.swift",
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
        #expect(summary.comments.first?.locationLabel == "Astra/Services/Git/GitService.swift:120")
        #expect(summary.comments.first?.preview.contains("swallow JSON failures") == true)
        #expect(summary.comments.contains { $0.body == "Resolved thread." } == false)
        #expect(summary.isTruncated == false)
        #expect(summary.latestCommentCreatedAt == "2026-05-30T11:00:00Z")
    }

    @Test("decodePullRequestComments flags truncated GraphQL connections")
    func decodePullRequestCommentsFlagsTruncatedConnections() throws {
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
                  "totalCount": 101,
                  "pageInfo": { "hasNextPage": true },
                  "nodes": [
                    {
                      "author": { "login": "reviewer" },
                      "body": "Visible comment.",
                      "createdAt": "2026-05-30T10:00:00Z",
                      "url": "https://github.com/coral/astra/pull/95#issuecomment-1"
                    }
                  ]
                },
                "reviewThreads": {
                  "totalCount": 0,
                  "pageInfo": { "hasNextPage": false },
                  "nodes": []
                }
              }
            }
          }
        }
        """

        let summary = try #require(GitService.decodePullRequestComments(from: json, pullRequest: pr))
        #expect(summary.totalCommentCount == 1)
        #expect(summary.isTruncated == true)
    }

    @Test("decodePullRequestComments returns structured diagnostics for malformed GraphQL payloads")
    func decodePullRequestCommentsDiagnostics() {
        let pr = GitHubPullRequestRef(
            number: 95,
            url: "https://github.com/coral/astra/pull/95",
            title: "Repository polish"
        )
        let result = GitService.decodePullRequestCommentsResult(
            from: #"{"data":{"repository":{"pullRequest":{"comments":"not-a-connection"}}}}"#,
            pullRequest: pr
        )

        #expect(result.value == nil)
        #expect(result.diagnostic.status == .decodeFailed)
        #expect(result.diagnostic.typeName == "GitHubPullRequestCommentsGraphQLResponse")
        #expect(result.diagnostic.codingPath?.contains("comments") == true)
        #expect(result.diagnostic.errorDescription?.contains("Type mismatch") == true)
    }

    @Test("decodePullRequestChecks summarizes passing pending and failing checks")
    func decodePullRequestChecksSummarizesStates() throws {
        let json = """
        {
          "statusCheckRollup": [
            { "__typename": "CheckRun", "name": "unit", "status": "COMPLETED", "conclusion": "SUCCESS" },
            { "__typename": "CheckRun", "name": "ui", "status": "IN_PROGRESS", "conclusion": null },
            { "__typename": "StatusContext", "context": "lint", "state": "FAILURE" },
            { "__typename": "StatusContext", "context": "docs", "state": "SUCCESS" }
          ]
        }
        """

        let summary = try #require(GitService.decodePullRequestChecks(from: json))

        #expect(summary.totalCount == 4)
        #expect(summary.passingCount == 2)
        #expect(summary.pendingCount == 1)
        #expect(summary.failingCount == 1)
        #expect(summary.state == .failing)
    }

    @Test("decodePullRequestChecks returns structured diagnostics for malformed rollups")
    func decodePullRequestChecksDiagnostics() {
        let result = GitService.decodePullRequestChecksResult(from: #"{"statusCheckRollup":"bad"}"#)

        #expect(result.value == nil)
        #expect(result.diagnostic.status == .decodeFailed)
        #expect(result.diagnostic.typeName == "GitHubPullRequestChecksViewResponse")
        #expect(result.diagnostic.codingPath == "statusCheckRollup")
        #expect(result.diagnostic.errorDescription?.contains("Type mismatch") == true)
    }

    @Test("webURLFromRemoteURL supports common GitHub remote forms")
    func remoteURLConversion() {
        #expect(GitService.webURLFromRemoteURL("git@github.com:example/repo.git") == "https://github.com/example/repo")
        #expect(GitService.webURLFromRemoteURL("ssh://git@github.example.edu/example/repo.git") == "https://github.example.edu/example/repo")
        #expect(GitService.webURLFromRemoteURL("https://github.com/example/repo.git") == "https://github.com/example/repo")
        #expect(GitService.webURLFromRemoteURL("") == nil)
    }

    @Test("reviewed remotes become explicit GitHub CLI repository targets")
    func githubRepositoryArgumentUsesReviewedHostAndRepository() {
        #expect(
            GitService.githubRepositoryArgument(from: "https://github.com/example/repo")
                == "github.com/example/repo"
        )
        #expect(
            GitService.githubRepositoryArgument(from: "https://github.example.edu/coral/astra.git")
                == "github.example.edu/coral/astra"
        )
        #expect(
            GitService.githubRepositoryArgument(from: "git@github.com:example/repo.git")
                == "github.com/example/repo"
        )
        #expect(
            GitService.githubRepositoryArgument(from: "ssh://git@github.example.edu/coral/astra.git")
                == "github.example.edu/coral/astra"
        )
        #expect(GitService.githubRepositoryArgument(from: "https://github.com/example") == nil)
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

    @Test("targeted lookup passes the reviewed remote to gh repo selection")
    func targetedLookupUsesReviewedRepository() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-targeted-lookup-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' '[{"number":42,"url":"https://github.example.edu/coral/astra/pull/42","title":"Targeted","isDraft":true,"state":"OPEN"}]'
        exit 0
        """)

        let result = await GitService.shared.lookupOpenPullRequest(
            repoPath: repo,
            remoteURL: "https://github.example.edu/coral/astra",
            head: "feature/reviewed-target",
            ghPathOverride: fakeGH.path
        )

        #expect(result.pullRequest?.number == 42)
        let arguments = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--repo"))
        #expect(arguments.contains("github.example.edu/coral/astra"))
        #expect(arguments.contains("--head"))
        #expect(arguments.contains("feature/reviewed-target"))
    }

    @Test("targeted creation uses reviewed repo and a noninteractive plain head")
    func targetedCreationUsesReviewedRepository() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-targeted-create-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' 'https://github.example.edu/coral/astra/pull/43'
        exit 0
        """)

        let url = try await GitService.shared.createPullRequest(
            repoPath: repo,
            remoteURL: "https://github.example.edu/coral/astra",
            base: "main",
            head: "feature/reviewed-target",
            title: "Targeted publication",
            body: "Body",
            isDraft: true,
            ghPathOverride: fakeGH.path
        )

        #expect(url == "https://github.example.edu/coral/astra/pull/43")
        let arguments = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--repo"))
        #expect(arguments.contains("github.example.edu/coral/astra"))
        #expect(arguments.contains("--head"))
        #expect(arguments.contains("feature/reviewed-target"))
        #expect(!arguments.contains("coral:feature/reviewed-target"))
        #expect(arguments.contains("--draft"))
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

    @Test("authoritative remote lookup ignores a stale remote-tracking ref")
    func authoritativeRemoteLookupIgnoresStaleTrackingRef() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = URL(fileURLWithPath: root).appendingPathComponent("work", isDirectory: true)
        let remote = URL(fileURLWithPath: root).appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        #expect(runShell("git init --bare '\(remote.path)'", in: root) == 0)
        #expect(runShell("git init -b main", in: repository.path) == 0)
        #expect(runShell("git config user.email astra@example.com", in: repository.path) == 0)
        #expect(runShell("git config user.name ASTRA", in: repository.path) == 0)
        #expect(runShell("git remote add upstream '\(remote.path)'", in: repository.path) == 0)

        let file = repository.appendingPathComponent("value.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(runShell("git add value.txt && git commit -m one && git push -u upstream main", in: repository.path) == 0)
        let firstSHA = try #require(await GitService.shared.getCommitSHA("HEAD", at: repository.path))

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(runShell("git add value.txt && git commit -m two && git push upstream main", in: repository.path) == 0)
        let secondSHA = try #require(await GitService.shared.getCommitSHA("HEAD", at: repository.path))
        #expect(firstSHA != secondSHA)

        // Deliberately rewind only the local tracking ref after the real remote
        // advanced. rev-parse is stale; ls-remote must still return commit two.
        #expect(runShell("git update-ref refs/remotes/upstream/main \(firstSHA)", in: repository.path) == 0)
        #expect(await GitService.shared.getCommitSHA("upstream/main", at: repository.path) == firstSHA)

        let result = await GitService.shared.lookupRemoteCommitSHA(
            remote: "upstream",
            branch: "main",
            at: repository.path
        )

        #expect(result == .found(secondSHA))
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

    @Test("draft pull request creation passes the explicit gh draft flag")
    func createDraftPullRequestRunsGhWithDraftFlag() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let argsFile = URL(fileURLWithPath: repo).appendingPathComponent("gh-draft-args.txt")
        let fakeGH = URL(fileURLWithPath: repo).appendingPathComponent("gh")
        try writeExecutable(at: fakeGH, contents: """
        #!/bin/sh
        printf '%s\n' "$@" > '\(argsFile.path)'
        printf '%s\n' 'https://github.com/example/repo/pull/43'
        exit 0
        """)

        let url = try await GitService.shared.createPullRequest(
            repoPath: repo,
            base: "main",
            head: "feature/draft",
            title: "Draft change",
            body: "Still under review.",
            isDraft: true,
            ghPathOverride: fakeGH.path
        )

        #expect(url == "https://github.com/example/repo/pull/43")
        let recordedArgs = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recordedArgs.split(separator: "\n").contains("--draft"))
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
