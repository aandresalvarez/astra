import Foundation
import Testing
@testable import HostControlToolSupport

/// The fixed review-thread reads the host broker serves. Kept beside
/// `HostControlToolSupportTests`, whose file has a line budget.
@Suite("GitHub review-thread reads")
struct GitHubReviewThreadReadOperationTests {
    @Test("review-thread reads bind fixed queries and reject arbitrary options")
    func githubReviewThreadReadArgumentsAreBounded() throws {
        let args = try GitHubReviewThreadReadOperation.arguments(for: ["review-threads", "--repo", "example/repo", "--pr", "12", "--after", "cursor"])
        #expect(args.contains("number=12")); #expect(args.contains("after=cursor"))
        #expect(!args.joined().contains("mutation"))
        for input in [["review-threads", "--repo", "example/repo", "--pr", "12", "--query", "mutation {}"],
                      ["review-thread", "--id", "T1", "--id", "T2"], ["review-thread", "--id", "T1", "--method", "POST"],
                      ["review-threads", "--repo", "../repo", "--pr", "12"], ["review-thread", "--id", "T1\nmutation"]] {
            #expect(throws: GitHubReviewThreadReadOperation.InvalidArguments.self) { try GitHubReviewThreadReadOperation.arguments(for: input) }
        }
        #expect(GitHubHostControlPolicy.denialReason(for: ["api", "graphql"]) != nil)
    }

    @Test("review-thread lists leave comment bodies out so pages stay under the output cap")
    func githubReviewThreadListsStayUnderTheOutputCap() throws {
        func query(_ input: [String]) throws -> String {
            try #require(GitHubReviewThreadReadOperation.arguments(for: input).first { $0.hasPrefix("query=") })
        }
        let list = try query(["review-threads", "--repo", "owner/repo", "--pr", "12"])
        let thread = try query(["review-thread", "--id", "T1"])
        #expect(!list.contains("body"))
        #expect(list.contains("comments(first: 1)"))
        #expect(thread.contains("body"))
        #expect(thread.contains("comments(first: 1"))
    }

    @Test("repository names such as owner/.github are accepted and dot directories are not")
    func githubReviewThreadRepositoryNames() throws {
        #expect(GitHubReviewThreadReadOperation.isRepository("owner/.github"))
        #expect(GitHubReviewThreadReadOperation.isRepository("owner/repo.name"))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/."))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/.."))
        #expect(!GitHubReviewThreadReadOperation.isRepository("owner/repo/extra"))
        _ = try GitHubReviewThreadReadOperation.arguments(for: ["review-threads", "--repo", "owner/.github", "--pr", "3"])
    }
}
