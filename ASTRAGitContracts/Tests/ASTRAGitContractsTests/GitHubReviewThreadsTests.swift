import Testing
import ASTRAGitContracts

@Suite("GitHub review query contracts")
struct GitHubReviewThreadsTests {
    @Test("The panel snapshot retains conversations and its 100-item bounds")
    func panelSnapshot() throws {
        let arguments = GitHubReviewThreads.pullRequestArguments(owner: "example", name: "project", number: 7)
        #expect(arguments.starts(with: ["api", "graphql"]))
        #expect(arguments.contains("limit=100"))
        #expect(arguments.contains("conversation=true"))
        let query = try #require(arguments.first { $0.hasPrefix("query=") })
        for field in ["comments(first: 100)", "reviewThreads", "isResolved", "isOutdated", "originalLine",
                      "totalCount", "hasNextPage endCursor", "author { login } body createdAt url"] {
            #expect(query.contains(field))
        }
        #expect(!query.contains("mutation"))
    }

    @Test("Task pagination binds cursors and node IDs as literal fields")
    func literalPagination() throws {
        let arguments = GitHubReviewThreads.commentArguments(threadID: "@opaque-id", pageSize: 1, after: "123")
        for field in ["id=@opaque-id", "after=123"] {
            let index = try #require(arguments.firstIndex(of: field))
            #expect(arguments[index - 1] == "-f")
        }
        #expect(arguments.contains("limit=1"))
        let query = try #require(arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("... on PullRequestReviewThread"))
        #expect(query.contains("comments(first: $limit, after: $after)"))
    }
}
