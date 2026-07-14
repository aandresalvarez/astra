import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Git pull request publication review")
struct GitPullRequestPublishReviewPresentationTests {
    @Test("Pending typed publication stays visible independently of Auto authority")
    func pendingPublicationStaysVisibleIndependentlyOfAutoAuthority() throws {
        #expect(TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .pendingUser,
            hasPendingPublication: true
        ))
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .completed,
            hasPendingPublication: true
        ))
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .pendingUser,
            hasPendingPublication: false
        ))

        // Integration guard: the task view delegates the outcome invariant to
        // the mode-independent policy and must not reintroduce an Auto filter.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Astra/Views/TaskMainView.swift"),
            encoding: .utf8
        )
        let propertyStart = try #require(source.range(of: "private var shouldOfferGitPublishReview: Bool"))
        let nextProperty = try #require(source[propertyStart.upperBound...].range(of: "private var taskDecisionExtraDetails"))
        let implementation = source[propertyStart.lowerBound..<nextProperty.lowerBound]
        #expect(implementation.contains("TaskGitPullRequestPublishReviewPolicy.shouldOffer"))
        #expect(!implementation.contains("taskSkipPermissions"))
    }

    @Test("Review fields disclose exact remote name and URL")
    func reviewFieldsDiscloseExactRemoteNameAndURL() throws {
        let proposal = GitPullRequestPublishProposal(
            proposalID: String(repeating: "a", count: 64),
            repositoryPath: "/tmp/astra",
            remote: "upstream",
            remoteURL: "git@github.com:aandresalvarez/astra.git",
            baseBranch: "main",
            baseSHA: String(repeating: "b", count: 40),
            headBranch: "alvaro/typed-publish",
            expectedHeadSHA: String(repeating: "c", count: 40),
            selectedPaths: ["Astra/App.swift"],
            selectedFileStates: [],
            commitMessage: "Add typed publication",
            pullRequestTitle: "Add typed publication",
            pullRequestBody: "Body",
            isDraft: true,
            authorizationRequirement: .explicitApproval,
            existingPullRequest: nil
        )

        let fields = GitPullRequestPublishReviewPresentation.fields(for: proposal)
        let remoteName = try #require(fields.first { $0.id == "remote-name" })
        let remoteURL = try #require(fields.first { $0.id == "remote-url" })

        #expect(remoteName.label == "Remote name")
        #expect(remoteName.value == "upstream")
        #expect(remoteName.isMonospaced)
        #expect(remoteURL.label == "Remote URL")
        #expect(remoteURL.value == "git@github.com:aandresalvarez/astra.git")
        #expect(remoteURL.isMonospaced)
    }
}
