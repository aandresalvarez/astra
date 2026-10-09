import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The chat's record of what ASTRA did outside the machine. Records are read
/// from the receipts the actions already write, so these pin the projection:
/// which receipts become rows, what each row says, and that a legacy text
/// notice for the same receipt is not shown twice.
@Suite("External action records")
struct ExternalActionRecordTests {
    @Test("A Jira receipt becomes a record with its key, link and provenance")
    func jiraReceiptBecomesRecord() throws {
        let task = AgentTask(title: "Jira", goal: "File the bug")
        let receipt = ConnectorMutationReceipt(
            stagedPayloadPath: "/tmp/task/outputs/jira-1.json",
            requestDigest: "abc",
            serviceType: "jira",
            operation: "create_issue",
            target: "STAR / Bug",
            destinationURL: "https://example.atlassian.net/rest/api/2/issue",
            statusCode: 201,
            createdKey: "STAR-12558",
            createdURL: "https://example.atlassian.net/browse/STAR-12558",
            authorization: .autoPolicy
        )
        let event = receiptEvent(task: task, type: ConnectorMutationEventTypes.receipt, payload: receipt, at: 10)

        let record = try #require(records(task: task, events: [event]).first)
        #expect(record.kind == .connectorMutation)
        #expect(record.title == "Created STAR-12558")
        #expect(record.destination == "Jira · STAR / Bug")
        #expect(record.url?.absoluteString == "https://example.atlassian.net/browse/STAR-12558")
        #expect(record.authorization == .autoPolicy)
        #expect(ExternalActionRecordPresentation.provenancePill(for: record.authorization) == "Auto")
    }

    // The created item's link comes from the connector's response: only an
    // http(s) link on the host the request went to is clickable.
    @Test("A receipt link is shown only as a web link on the connector's host")
    func receiptLinksStayOnTheConnector() throws {
        let task = AgentTask(title: "Jira", goal: "File the bug")
        func link(_ created: String) throws -> URL? {
            let receipt = ConnectorMutationReceipt(
                stagedPayloadPath: "/tmp/task/outputs/jira-9.json", requestDigest: "x", serviceType: "jira",
                operation: "create_issue", target: "STAR / Bug",
                destinationURL: "https://example.atlassian.net/rest/api/2/issue", statusCode: 201,
                createdKey: nil, createdURL: created
            )
            let event = receiptEvent(task: task, type: ConnectorMutationEventTypes.receipt, payload: receipt, at: 10)
            return try #require(records(task: task, events: [event]).first).url
        }
        #expect(try link("https://example.atlassian.net/rest/api/2/issue/10001") != nil)
        #expect(try link("file:///etc/passwd") == nil)
        #expect(try link("x-other-app://open") == nil)
        #expect(try link("https://elsewhere.example/phish") == nil)
    }

    @Test("A receipt written before levels were harmonized reads as reviewed by the user")
    func legacyReceiptReadsAsUserReviewed() throws {
        let task = AgentTask(title: "Jira", goal: "Comment on the ticket")
        let receipt = ConnectorMutationReceipt(
            stagedPayloadPath: "/tmp/task/outputs/jira-2.json",
            requestDigest: "def",
            serviceType: "jira",
            operation: "add_comment",
            target: "STAR-7",
            destinationURL: "https://example.atlassian.net/rest/api/2/issue/STAR-7/comment",
            statusCode: 201,
            createdKey: nil,
            createdURL: "https://example.atlassian.net/browse/STAR-7?focusedCommentId=1"
        )
        let encoded = try #require(String(data: TaskEventPayloadCodec.makeEncoder().encode(receipt), encoding: .utf8))
        #expect(!encoded.contains("authorization"), "an unset field must not change the stored receipt")

        let event = receiptEvent(task: task, type: ConnectorMutationEventTypes.receipt, payload: receipt, at: 10)
        let record = try #require(records(task: task, events: [event]).first)
        #expect(record.title == "Commented on STAR-7")
        #expect(record.destination == "Jira")
        #expect(record.authorization == .userReviewed)
        #expect(ExternalActionRecordPresentation.provenancePill(for: record.authorization) == nil)
    }

    @Test("A GitHub review receipt replaces the legacy text notice")
    func githubReviewReceiptReplacesLegacyNotice() throws {
        let task = AgentTask(title: "Review", goal: "Post the review on PR #12")
        let reviewURL = "https://github.com/acme/widgets/pull/12#pullrequestreview-99"
        let receipt = GitHubReviewPublicationRecord(
            proposalID: "p1",
            filePath: "/tmp/task/outputs/pr12_review.json",
            pullRequestURL: "https://github.com/acme/widgets/pull/12",
            reviewURL: reviewURL,
            reviewID: 99
        )
        let events = [
            receiptEvent(task: task, type: GitHubReviewPublicationEventTypes.receipt, payload: receipt, at: 10),
            textEvent(task: task, type: "system.info", payload: "Posted GitHub review: \(reviewURL)", at: 11)
        ]

        let items = TaskThreadSnapshot(goal: task.goal, createdAt: Date(timeIntervalSince1970: 1), events: events, runs: [])
            .conversationItems
        let record = try #require(items.compactMap(Self.record).first)
        #expect(record.title == "Posted a review on pull request #12")
        #expect(record.destination == "acme/widgets")
        #expect(record.url?.absoluteString == reviewURL)
        #expect(!items.contains { item in
            if case .systemInfo(let text, _, _) = item { return text.hasPrefix("Posted GitHub review") }
            return false
        })
    }

    @Test("A pull request receipt records the pull request")
    func pullRequestReceiptBecomesRecord() throws {
        let task = AgentTask(title: "PR", goal: "Create a pull request for the fix")
        let payload = """
        {"pullRequestNumber":34,"pullRequestURL":"https://github.com/acme/widgets/pull/34","isDraft":true}
        """
        let event = textEvent(task: task, type: TaskExternalOutcomeEventTypes.publicationReceipt, payload: payload, at: 10)

        let record = try #require(records(task: task, events: [event]).first)
        #expect(record.kind == .gitPullRequestPublication)
        #expect(record.title == "Opened draft pull request #34")
        #expect(record.destination == "acme/widgets")
        #expect(record.legacyNotices == ["Published draft pull request #34: https://github.com/acme/widgets/pull/34"])
    }

    // The publisher reuses an already-open pull request instead of opening a
    // second; that path pushes and creates nothing, so the row must not claim it.
    @Test("A receipt for an existing pull request does not say ASTRA opened it")
    func existingPullRequestIsNotCalledOpened() throws {
        let task = AgentTask(title: "PR", goal: "Create a pull request for the fix")
        let payload = """
        {"pullRequestNumber":34,"pullRequestURL":"https://github.com/acme/widgets/pull/34","isDraft":true,"source":"existing"}
        """
        let event = textEvent(task: task, type: TaskExternalOutcomeEventTypes.publicationReceipt, payload: payload, at: 10)

        let record = try #require(records(task: task, events: [event]).first)
        #expect(record.title == "Found existing draft pull request #34")
    }

    @Test("Failed, indeterminate and dispatched sends leave no record")
    func unfinishedActionsLeaveNoRecord() {
        let task = AgentTask(title: "Unfinished", goal: "Post")
        let review = GitHubReviewPublicationRecord(
            proposalID: "p1",
            filePath: "/tmp/r.json",
            pullRequestURL: "https://github.com/acme/widgets/pull/12",
            reviewURL: nil,
            reviewID: nil
        )
        let events = [
            receiptEvent(task: task, type: GitHubReviewPublicationEventTypes.dispatched, payload: review, at: 10),
            receiptEvent(task: task, type: GitHubReviewPublicationEventTypes.indeterminate, payload: review, at: 11),
            textEvent(task: task, type: ConnectorMutationEventTypes.failed, payload: "{}", at: 12),
            textEvent(task: task, type: ConnectorMutationEventTypes.indeterminate, payload: "{}", at: 13)
        ]
        #expect(records(task: task, events: events).isEmpty)
    }

    // MARK: - Helpers

    private func records(task: AgentTask, events: [TaskEvent]) -> [ExternalActionRecord] {
        TaskThreadSnapshot(goal: task.goal, createdAt: Date(timeIntervalSince1970: 1), events: events, runs: [])
            .conversationItems
            .compactMap(Self.record)
    }

    private static func record(_ item: TaskConversationItem) -> ExternalActionRecord? {
        if case .externalAction(let record) = item { return record }
        return nil
    }

    private func receiptEvent<T: Encodable>(task: AgentTask, type: String, payload: T, at seconds: TimeInterval) -> TaskEvent {
        let event = TaskEvent.structuredPayloadEvent(task: task, type: type, payload: payload)
        event.timestamp = Date(timeIntervalSince1970: seconds)
        return event
    }

    private func textEvent(task: AgentTask, type: String, payload: String, at seconds: TimeInterval) -> TaskEvent {
        let event = TaskEvent(task: task, type: type, payload: payload)
        event.timestamp = Date(timeIntervalSince1970: seconds)
        return event
    }
}
