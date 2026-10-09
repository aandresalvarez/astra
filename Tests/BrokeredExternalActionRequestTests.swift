import CryptoKit
import Foundation
import Testing
@testable import HostControlToolSupport

/// The broker half of spec decision 15: after it stages a Jira write, or reads
/// a review file the agent names, the broker asks ASTRA — and says to the agent
/// exactly what ASTRA answered. It never sends, and it never decides whether to:
/// every outcome here comes from the requester, which stands in for the app.
@Suite("Brokered external action requests", .serialized)
struct BrokeredExternalActionRequestTests {
    // MARK: - Jira

    @Test("A proposal asks ASTRA with the file the broker wrote and the digest of what it wrote")
    func proposalAsksWithTheBrokersOwnFileAndDigest() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .awaitingReview)

        let text = try resultText(try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments))

        let request = try #require(requester.connectorRequests.first)
        #expect(requester.connectorRequests.count == 1)
        #expect(value(of: "staged_path", in: text) == request.stagedPath)
        #expect(value(of: "request_digest", in: text) == request.requestDigest)
        // The digest is of the bytes on disk, so ASTRA can prove it sends them.
        let staged = try ConnectorMutationStaging.read(
            atPath: request.stagedPath, containedIn: folder, expectedDigest: request.requestDigest
        )
        #expect(staged.operation == "add_comment")
        #expect(requester.reviewRequests.isEmpty)
    }

    @Test("Awaiting review reads exactly as it did before ASTRA could send")
    func awaitingReviewIsTheReviewReply() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        for requester in [RecordingRequester(outcome: .awaitingReview), nil] {
            let object = try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments)
            let text = try resultText(object)
            #expect(try isError(object) == false)
            #expect(text.contains("sent: false"))
            #expect(text.contains("ASTRA will ask the user to review this exact payload"))
            #expect(!text.contains("sent: true"))
        }
    }

    @Test("A sent proposal returns the key and link so the agent can build on them")
    func performedReturnsTheReceipt() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .performed(BrokeredExternalActionReceipt(
            identifier: "SS-617", url: "https://jira.requests.test/browse/SS-617?focusedCommentId=10"
        )))

        let object = try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments)
        let text = try resultText(object)

        #expect(try isError(object) == false)
        #expect(text.contains("sent: true"))
        #expect(value(of: "key", in: text) == "SS-617")
        #expect(value(of: "url", in: text) == "https://jira.requests.test/browse/SS-617?focusedCommentId=10")
        #expect(text.contains("permission level (Auto) does not ask first"))
        #expect(!text.contains("sent: false"))
        #expect(!text.contains("review this exact payload"))
    }

    @Test("A refusal is an error that says nothing was sent")
    func refusedSaysNothingWasSent() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .refused(message: "The connector rejected the request (HTTP 400): bad field"))

        let object = try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments)
        let text = try resultText(object)

        #expect(try isError(object) == true)
        #expect(text.contains("sent: false"))
        #expect(value(of: "error", in: text) == "The connector rejected the request (HTTP 400): bad field")
        #expect(text.contains("nothing was sent"))
    }

    @Test("An uncertain outcome tells the agent not to propose it again")
    func uncertainSaysDoNotRetry() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .uncertain(message: "ASTRA sent this but never got an answer"))

        let object = try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments)
        let text = try resultText(object)

        #expect(try isError(object) == true)
        #expect(text.contains("sent: unknown"))
        #expect(text.contains("Do not propose it again"))
        #expect(!text.contains("sent: false"))
    }

    /// The error comes back from a provider, which can reflect what it was
    /// sent; the reply to the agent goes through the broker's redaction.
    @Test("A refusal's message is redacted before the agent sees it")
    func refusalMessageIsRedacted() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .refused(message: "echo: super-secret-token"))

        let text = try resultText(try call(server(folder, requester: requester), tool: "jira", arguments: commentArguments))

        #expect(!text.contains("super-secret-token"))
    }

    @Test("A proposal that fails validation asks ASTRA nothing")
    func invalidProposalAsksNothing() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let requester = RecordingRequester(outcome: .performed(BrokeredExternalActionReceipt(identifier: "X-1", url: nil)))
        var arguments = commentArguments
        arguments["visibility"] = "everyone"

        _ = try call(server(folder, requester: requester), tool: "jira", arguments: arguments)

        #expect(requester.connectorRequests.isEmpty)
    }

    // MARK: - GitHub review

    @Test("post_review asks ASTRA with the file's name and the digest of its bytes")
    func postReviewAsksWithNameAndDigest() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let bytes = Data(#"{"event":"COMMENT","commit_id":"abc","body":"Looks good"}"#.utf8)
        try bytes.write(to: URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json"))
        let requester = RecordingRequester(outcome: .performed(BrokeredExternalActionReceipt(
            identifier: "review 42", url: "https://github.com/example/repo/pull/12#pullrequestreview-42"
        )))

        let object = try call(server(folder, requester: requester), tool: "github", arguments: [
            "operation": "post_review", "review_file": "pr12_review.json"
        ])
        let text = try resultText(object)

        let request = try #require(requester.reviewRequests.first)
        #expect(request.fileName == "pr12_review.json")
        #expect(request.contentDigest == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(try isError(object) == false)
        #expect(text.contains("posted: true"))
        #expect(value(of: "review_url", in: text) == "https://github.com/example/repo/pull/12#pullrequestreview-42")
        #expect(requester.connectorRequests.isEmpty)
    }

    @Test("post_review without ASTRA's answer leaves the review for the user")
    func postReviewAwaitingReview() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json"))

        for requester in [RecordingRequester(outcome: .awaitingReview), nil] {
            let object = try call(server(folder, requester: requester), tool: "github", arguments: [
                "operation": "post_review", "review_file": "pr12_review.json"
            ])
            let text = try resultText(object)
            #expect(try isError(object) == false)
            #expect(text.contains("posted: false"))
            #expect(text.contains("Post review"))
        }
    }

    @Test("post_review refuses names, paths, links and extra arguments before asking ASTRA")
    func postReviewRefusesWhatItCannotRead() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json"))
        let outside = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: outside).appendingPathComponent("pr13_review.json"))
        try FileManager.default.createSymbolicLink(
            atPath: (folder as NSString).appendingPathComponent("pr13_review.json"),
            withDestinationPath: (outside as NSString).appendingPathComponent("pr13_review.json")
        )
        let requester = RecordingRequester(outcome: .performed(BrokeredExternalActionReceipt(identifier: nil, url: nil)))
        let refused: [[String: Any]] = [
            ["operation": "post_review"],
            ["operation": "post_review", "review_file": "notes.json"],
            ["operation": "post_review", "review_file": "../pr12_review.json"],
            ["operation": "post_review", "review_file": "\(folder)/pr12_review.json"],
            ["operation": "post_review", "review_file": "pr14_review.json"],
            ["operation": "post_review", "review_file": "pr13_review.json"],
            ["operation": "post_review", "review_file": "pr12_review.json", "arguments": ["pr", "view", "12"]],
            ["operation": "merge", "review_file": "pr12_review.json"]
        ]

        for arguments in refused {
            let object = try call(server(folder, requester: requester), tool: "github", arguments: arguments)
            #expect(object["error"] != nil, "\(arguments)")
        }
        #expect(requester.reviewRequests.isEmpty)
    }

    @Test("A failed or uncertain post is an error with the right instruction")
    func postReviewFailures() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("pr12_review.json"))
        let arguments: [String: Any] = ["operation": "post_review", "review_file": "pr12_review.json"]

        let refused = try call(
            server(folder, requester: RecordingRequester(outcome: .refused(message: "stale head"))),
            tool: "github", arguments: arguments
        )
        #expect(try isError(refused) == true)
        #expect(try resultText(refused).contains("posted: false"))
        #expect(try resultText(refused).contains("new file name"))

        let uncertain = try call(
            server(folder, requester: RecordingRequester(outcome: .uncertain(message: "no answer"))),
            tool: "github", arguments: arguments
        )
        #expect(try isError(uncertain) == true)
        #expect(try resultText(uncertain).contains("posted: unknown"))
        #expect(try resultText(uncertain).contains("Do not ask"))
    }

    @Test("The github tool still runs gh commands, and its schema offers post_review")
    func githubSchemaOffersPostReview() throws {
        let folder = try temporaryTaskFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let response = try #require(server(folder, requester: nil).handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let tools = try #require((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let github = try #require(tools.first { $0["name"] as? String == "github" })
        let input = try #require(github["inputSchema"] as? [String: Any])
        let properties = try #require(input["properties"] as? [String: Any])
        #expect(properties["arguments"] != nil)
        #expect(properties["operation"] != nil)
        #expect(properties["review_file"] != nil)
        #expect(input["required"] == nil)
        #expect(input["additionalProperties"] as? Bool == false)
    }

    @Test("The review file rule matches the app's")
    func reviewFileNames() {
        for name in ["pr12_review.json", "pr12_review_2.json", "PR12_REVIEW.json", "github_review.json"] {
            #expect(GitHubReviewHostControlOperations.isReviewFileName(name), "\(name)")
        }
        for name in ["pr12_review.txt", "review.json", "a/pr12_review.json", "pr_review.json", "pr12_review_.json"] {
            #expect(!GitHubReviewHostControlOperations.isReviewFileName(name), "\(name)")
        }
    }

    // MARK: - Fixtures

    private var commentArguments: [String: Any] {
        ["operation": "propose_comment", "issue_key": "SS-617", "comment": "Re-run the query.", "visibility": "internal"]
    }

    private func temporaryTaskFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-broker-requests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    private func server(_ taskFolder: String, requester: RecordingRequester?) -> HostControlMCPServer {
        let connectors = """
        {"connectors":[{"id":"jira-1","alias":"jira","envPrefix":"JIRA_JIRA","name":"Jira",\
        "serviceType":"jira","baseURL":"https://jira.requests.test","authMethod":"basic",\
        "env":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},\
        "credentials":{"JIRA_EMAIL":"JIRA_EMAIL_ENV","JIRA_API_TOKEN":"JIRA_TOKEN_ENV"},"config":{}}]}
        """
        return HostControlMCPServer(
            configuration: HostControlToolConfiguration(
                taskFolder: taskFolder,
                runID: "run-1",
                connectorsJSON: connectors,
                environment: [
                    "ASTRA_CONNECTORS": connectors,
                    "JIRA_EMAIL_ENV": "user@example.com",
                    "JIRA_TOKEN_ENV": "super-secret-token"
                ]
            ),
            externalActionRequester: requester
        )
    }

    private func call(
        _ server: HostControlMCPServer, tool: String, arguments: [String: Any]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let line = try #require(String(data: data, encoding: .utf8))
        let response = try #require(server.handleLine(line))
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func resultText(_ object: [String: Any]) throws -> String {
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func isError(_ object: [String: Any]) throws -> Bool {
        try #require((object["result"] as? [String: Any])?["isError"] as? Bool)
    }

    private func value(of key: String, in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)) }
    }
}

private final class RecordingRequester: BrokeredExternalActionRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: BrokeredExternalActionOutcome
    private var connector: [StagedConnectorMutationRequest] = []
    private var review: [GitHubReviewPostRequest] = []

    init(outcome: BrokeredExternalActionOutcome) {
        self.outcome = outcome
    }

    var connectorRequests: [StagedConnectorMutationRequest] { lock.withLock { connector } }
    var reviewRequests: [GitHubReviewPostRequest] { lock.withLock { review } }

    func sendStagedConnectorMutation(_ request: StagedConnectorMutationRequest) -> BrokeredExternalActionOutcome {
        lock.withLock { connector.append(request) }
        return outcome
    }

    func postGitHubReview(_ request: GitHubReviewPostRequest) -> BrokeredExternalActionOutcome {
        lock.withLock { review.append(request) }
        return outcome
    }
}
