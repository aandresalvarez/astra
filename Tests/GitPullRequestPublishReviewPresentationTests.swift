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
            latestRunStopReason: .externalOutcomePending,
            hasPendingPublication: true
        ))
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .completed,
            latestRunStopReason: .externalOutcomePending,
            hasPendingPublication: true
        ))
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .pendingUser,
            latestRunStopReason: .externalOutcomePending,
            hasPendingPublication: false
        ))
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: .pendingUser,
            latestRunStopReason: .noUsableResult,
            hasPendingPublication: true
        ))

        // Integration guard: the task view delegates the outcome invariant to
        // the mode-independent policy and must not reintroduce an Auto filter.
        // The property lives with the dock's other event-derived answers in
        // TaskMainViewDecisionOutcomes.swift, cached off the body pass.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Astra/Views/TaskMainViewDecisionOutcomes.swift"),
            encoding: .utf8
        )
        let propertyStart = try #require(source.range(of: "var shouldOfferGitPublishReview: Bool"))
        let nextMember = try #require(source[propertyStart.upperBound...].range(of: "func recomputeDecisionOutcomes()"))
        let implementation = source[propertyStart.lowerBound..<nextMember.lowerBound]
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
