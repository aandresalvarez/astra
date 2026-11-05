/// The Git panel and task broker use the same host gh query. The panel takes
/// its usual bounded snapshot; a task can request subsequent pages on demand.
public enum GitHubReviewThreads {
    private static let commentFields = """
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { author { login } body createdAt url }
        """

    public static func pullRequestArguments(
        owner: String, name: String, number: Int, pageSize: Int = 100,
        after: String? = nil, includeConversation: Bool = true
    ) -> [String] {
        let query = """
            query($owner: String!, $name: String!, $number: Int!, $limit: Int!, $after: String, $conversation: Boolean!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  comments(first: 100) @include(if: $conversation) { \(commentFields) }
                  reviewThreads(first: $limit, after: $after) {
                    totalCount
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      id isResolved isOutdated path line originalLine
                      comments(first: $limit) { \(commentFields) }
                    }
                  }
                }
              }
            }
            """
        return arguments(query: query, pageSize: pageSize, after: after) + [
            "-f", "owner=\(owner)", "-f", "name=\(name)", "-F", "number=\(number)",
            "-F", "conversation=\(includeConversation)"
        ]
    }

    public static func commentArguments(threadID: String, pageSize: Int, after: String?) -> [String] {
        let query = """
            query($id: ID!, $limit: Int!, $after: String) {
              node(id: $id) {
                ... on PullRequestReviewThread {
                  id isResolved isOutdated path line originalLine
                  comments(first: $limit, after: $after) { \(commentFields) }
                }
              }
            }
            """
        return arguments(query: query, pageSize: pageSize, after: after) + ["-f", "id=\(threadID)"]
    }

    private static func arguments(query: String, pageSize: Int, after: String?) -> [String] {
        var arguments = ["api", "graphql", "-f", "query=\(query)", "-F", "limit=\(pageSize)"]
        // gh's typed -F interprets @file and coerces numeric strings. All
        // caller-supplied strings are literal fields, including opaque cursors.
        if let after { arguments += ["-f", "after=\(after)"] }
        return arguments
    }
}
