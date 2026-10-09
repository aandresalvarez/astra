import Foundation

/// Fixed GraphQL reads of a pull request's review threads for the host broker.
/// Caller input is confined to variables, never query text or CLI options.
public enum GitHubReviewThreadReadOperation {
    public static let names: Set<String> = ["review-threads", "review-thread"]

    public static let guidance = """
    Read PR review threads with review-threads --repo OWNER/REPO --pr NUMBER and review-thread --id THREAD_ID. review-threads lists threads with only each thread's first comment (identity, no body) and review-thread returns the bodies; both accept --after CURSOR, so follow pageInfo.hasNextPage for threads and, for a thread, for its comments. ASTRA cannot reply to or resolve review threads yet: when asked, summarize each thread, make the requested fixes, and give the user the reply you would post for each thread. Raw api and other write paths remain unavailable through this capability.
    """

    public static func arguments(for input: [String]) throws -> [String] {
        guard let operation = input.first, names.contains(operation), input.count % 2 == 1 else {
            throw InvalidArguments()
        }
        var fields: [String: String] = [:]
        for index in stride(from: 1, to: input.count, by: 2) {
            guard fields.updateValue(input[index + 1], forKey: input[index]) == nil else { throw InvalidArguments() }
        }
        let allowed: Set<String> = operation == "review-threads" ? ["--repo", "--pr", "--after"] : ["--id", "--after"]
        guard Set(fields.keys).isSubset(of: allowed),
              fields.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains(where: \.isNewline) }) else {
            throw InvalidArguments()
        }
        var arguments = ["api", "graphql", "--hostname", "github.com"]
        if operation == "review-threads" {
            guard let repository = fields["--repo"], isRepository(repository),
                  let rawNumber = fields["--pr"], let number = Int(rawNumber), number > 0,
                  String(number) == rawNumber else { throw InvalidArguments() }
            let parts = repository.split(separator: "/")
            arguments += ["-f", "query=\(listQuery.replacingOccurrences(of: "\n", with: " "))", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)"]
        } else {
            guard let id = fields["--id"], isNodeID(id) else { throw InvalidArguments() }
            arguments += ["-f", "query=\(threadQuery.replacingOccurrences(of: "\n", with: " "))", "-f", "id=\(id)"]
        }
        if let cursor = fields["--after"] { arguments += ["-f", "after=\(cursor)"] }
        return arguments
    }

    public static func isRepository(_ value: String) -> Bool {
        // GitHub allows dot-leading names such as owner/.github; only "." and ".." are not names.
        value.range(of: #"^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && !value.hasSuffix("/.") && !value.hasSuffix("/..")
            && value.utf8.count <= 200
    }

    public static func isNodeID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_=-]{1,200}$"#, options: .regularExpression) != nil
    }

    public struct InvalidArguments: LocalizedError {
        public var errorDescription: String? {
            "Use review-threads --repo OWNER/REPO --pr NUMBER [--after CURSOR], or review-thread --id THREAD_ID [--after CURSOR]. No other options are supported."
        }
    }

    /// The thread list carries only who opened each thread, never comment bodies: twenty
    /// threads of twenty long comments would pass the broker's 256 KiB output cap and
    /// return truncated, unparseable JSON. The bodies come from `review-thread`.
    private static let comments = """
    comments(first: 1) { totalCount nodes { id url author { login } } }
    """
    private static let listQuery = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        url headRefOid state reviewThreads(first: 20, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id path line isResolved viewerCanResolve viewerCanReply \(comments) }
        }
      } }
    }
    """
    private static let threadQuery = """
    query($id: ID!, $after: String) { node(id: $id) { ... on PullRequestReviewThread {
      id path line isResolved viewerCanResolve viewerCanReply pullRequest { url headRefOid state }
      comments(first: 1, after: $after) { totalCount pageInfo { hasNextPage endCursor } nodes { id body url author { login } } }
    } } }
    """
}
