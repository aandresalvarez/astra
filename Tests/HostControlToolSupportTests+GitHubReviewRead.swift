import Foundation
import Testing
import ASTRAGitContracts
@testable import HostControlToolSupport
@testable import ASTRA

extension HostControlToolSupportTests {
    @Test("The task read uses the panel query and host credential context")
    func readsThroughHost() throws {
        let runner = ReviewReadRunner()
        let server = server(runner)
        let response = try call(server, arguments: ["pr", "review-threads", "7", "--repo", "example/project"])
        let request = try #require(runner.requests.first)
        #expect(request.arguments == GitHubReviewThreads.pullRequestArguments(
            owner: "example", name: "project", number: 7, pageSize: 20, includeConversation: false
        ))
        #expect(request.executable == "/host/bin/gh")
        #expect(request.environment == ["GH_CONFIG_DIR": "/host/gh-config"])
        #expect(request.directory == "/host/checkout")
        #expect(request.timeout == 120)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let text = try text(response)
        #expect(text.contains(runner.result.stdout))
        #expect(text.hasPrefix("command: gh\n"))
        #expect(text.contains("api graphql -f query="))
    }

    @Test("Thread and nested reply pagination keep opaque values literal")
    func pagination() throws {
        let runner = ReviewReadRunner()
        let server = server(runner)
        _ = try call(server, arguments: [
            "pr", "review-threads", "7", "--repo", "example/project", "--after", "@opaque", "--limit", "2"
        ])
        #expect(runner.requests[0].arguments == GitHubReviewThreads.pullRequestArguments(
            owner: "example", name: "project", number: 7, pageSize: 2, after: "@opaque", includeConversation: false
        ))
        _ = try call(server, arguments: ["pr", "thread-comments", "PRRT_example", "--after", "123", "--limit", "1"])
        #expect(runner.requests[1].arguments == GitHubReviewThreads.commentArguments(
            threadID: "PRRT_example", pageSize: 1, after: "123"
        ))
        let arguments = runner.requests[1].arguments
        let after = try #require(arguments.firstIndex(of: "after=123"))
        #expect(arguments[after - 1] == "-f")
        let query = try #require(arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("... on PullRequestReviewThread"))
        #expect(query.contains("hasNextPage endCursor"))
        #expect(query.contains("isResolved isOutdated"))
        #expect(!query.contains("mutation"))
    }

    @Test("Invalid review reads and raw API calls never reach gh")
    func validatesBeforeLaunch() throws {
        let runner = ReviewReadRunner()
        let server = server(runner)
        let invalid = [
            ["pr", "review-threads"],
            ["pr", "review-threads", "7"],
            ["pr", "review-threads", "0", "--repo", "example/project"],
            ["pr", "review-threads", "2147483648", "--repo", "example/project"],
            ["pr", "review-threads", "7", "--repo", "../project"],
            ["pr", "review-threads", "7", "--repo", "https://github.com/example/project"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--repo", "other/project"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--limit", "0"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--limit", "101"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--limit", "1.5"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--after", "cursor\ncommand"],
            ["pr", "review-threads", "7", "--repo", "example/project", "--after", ""],
            ["pr", "review-threads", "7", "--repo", "example/project", "--after", String(repeating: "x", count: 2049)],
            ["pr", "review-threads", "7", "--repo", "example/project", "--input", "/private/file"],
            ["pr", "review-threads", "7", "--repo", "example/project", "-f", "query=mutation {}"],
            ["pr", "thread-comments", "PRRT_example", "--repo", "example/project"],
            ["pr", "thread-comments", "PRRT_example", "--hostname", "untrusted.test"],
            ["api", "graphql", "-f", "query=mutation {}"],
            ["api", "--method", "GET", "repos/example/project/pulls/7/comments"]
        ]
        for arguments in invalid {
            #expect(try call(server, arguments: arguments)["error"] != nil, "\(arguments)")
        }
        #expect(runner.requests.isEmpty)
    }

    @Test("Authentication errors, timeouts and capped responses stay visible")
    func failuresRemainErrors() throws {
        let runner = ReviewReadRunner()
        let server = server(runner, byteLimit: 256)
        runner.result = HostControlCommandResult(command: "gh", arguments: [], exitCode: 1,
                                                 stdout: "", stderr: "GitHub rejected this repository read")
        let failure = try call(server, arguments: ["pr", "thread-comments", "PRRT_example"])
        #expect((failure["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(try text(failure).contains("GitHub rejected this repository read"))
        runner.result = HostControlCommandResult(command: "gh", arguments: [], exitCode: 0,
                                                 stdout: "", stderr: "", timedOut: true)
        #expect(try text(call(server, arguments: ["pr", "thread-comments", "PRRT_example"])).contains("timed_out: true"))
        runner.result = HostControlCommandResult(command: "gh", arguments: [], exitCode: 0,
                                                 stdout: String(repeating: "comment", count: 200), stderr: "")
        let capped = try call(server, arguments: ["pr", "thread-comments", "PRRT_example"])
        #expect((capped["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(try text(capped).contains("stdout_truncated: true"))
    }

    @Test("Review reads require the enabled GitHub tool")
    func requiresCapability() throws {
        let runner = ReviewReadRunner()
        let server = HostControlMCPServer(configuration: .init(allowedTools: ["history"]), processRunner: runner)
        #expect(try call(server, arguments: ["pr", "review-threads", "7", "--repo", "example/project"])["error"] != nil)
        #expect(runner.requests.isEmpty)
    }

    @Test("Both advertised transports can express the read without a write request")
    func transportGuidance() {
        let mcp = GitHubCapabilityLaunchContext.reviewThreadGuidance(usesCLIRelay: false)
        #expect(mcp.contains(#"{"arguments":["pr","review-threads","NUMBER","--repo","OWNER/REPO"]}"#))
        #expect(mcp.contains("Git panel's host GitHub login"))
        #expect(mcp.contains("earlier turns"))
        let relay = GitHubCapabilityLaunchContext.reviewThreadGuidance(usesCLIRelay: true)
        #expect(relay.contains("astra-host-control github -- pr review-threads"))
        #expect(!relay.contains("mcp__"))
        let command = "astra-host-control github -- pr review-threads 7 --repo example/project --limit 2"
        #expect(HostControlCLIRelayPolicy.allows(command))
        #expect(!HostControlCLIRelayPolicy.isTypedExternalAction(command))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control github -- pr thread-comments PRRT_example --after YWJj"))
    }

    private func server(_ runner: ReviewReadRunner, byteLimit: Int = 256 * 1024) -> HostControlMCPServer {
        HostControlMCPServer(
            configuration: .init(githubExecutable: "/host/bin/gh", allowedTools: ["github"],
                                 currentDirectory: "/host/checkout", environment: ["GH_CONFIG_DIR": "/host/gh-config"]),
            processRunner: runner,
            processLimits: .init(outputByteLimit: byteLimit)
        )
    }

    private func call(_ server: HostControlMCPServer, arguments: [String]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "github", "arguments": ["arguments": arguments]]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try #require(server.handleLine(String(decoding: data, as: UTF8.self)))
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func text(_ response: [String: Any]) throws -> String {
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }
}

private final class ReviewReadRunner: HostControlProcessRunning {
    struct Request {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
        let environment: [String: String]
        let directory: String?
    }

    var requests: [Request] = []
    var result = HostControlCommandResult(
        command: "gh", arguments: [], exitCode: 0,
        stdout: """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{
          "pageInfo":{"hasNextPage":false,"endCursor":"end"},
          "nodes":[{
            "id":"PRRT_example","isResolved":true,"isOutdated":true,
            "path":"Source.swift","line":null,"originalLine":4,
            "comments":{
              "pageInfo":{"hasNextPage":true,"endCursor":"replies"},
              "nodes":[{
                "author":{"login":"reviewer"},
                "body":"Preserve the existing behavior.",
                "url":"https://github.com/example/project/pull/7#discussion_r1"
              }]
            }
          }]
        }}}}}
        """,
        stderr: ""
    )

    func run(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval,
             environment: [String: String], currentDirectory: String?) -> HostControlCommandResult {
        requests.append(.init(executable: executablePath, arguments: arguments, timeout: timeoutSeconds,
                              environment: environment, directory: currentDirectory))
        var response = result
        response.command = executablePath
        response.arguments = arguments
        return response
    }
}
