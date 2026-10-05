import Foundation

/// Fixed GraphQL reads shared by the broker and ASTRA's publication validation.
/// Caller input is confined to variables, never query text or CLI options.
public enum GitHubReviewThreadReadOperation {
    public static let names: Set<String> = ["review-threads", "review-thread"]

    public static let publicationGuidance = """
    To reply to or resolve existing PR review threads, read them with review-threads --repo OWNER/REPO --pr NUMBER and review-thread --id THREAD_ID. Both accept --after CURSOR; follow pageInfo.hasNextPage for threads and comments. Prepare pr<NUMBER>_threads.json (or a versioned pr<NUMBER>_threads_2.json) in the task folder: {"pull_request_url":"https://github.com/OWNER/REPO/pull/NUMBER","commit_id":"40-character headRefOid","threads":[{"thread_id":"thread node id","expected_last_comment_id":"last comment node id after reading all pages","reply":"exact reply text, or omit for resolution only","resolve":true}]}. Include only addressed threads. In Ask obtain normal Write approval for this proposal. The file is a proposal: ASTRA shows the exact changes and sends them after the user presses Send thread changes. Report publication as pending until ASTRA records receipts. Raw api and direct credential workarounds remain unavailable through this capability.
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
        value.range(of: #"^[A-Za-z0-9-]+/[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
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

    private static let comments = """
    comments(first: 20) { totalCount pageInfo { hasNextPage endCursor } nodes { id body url author { login } } }
    """
    private static let listQuery = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        url headRefOid state reviewThreads(first: 20, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id path line isResolved viewerCanResolve \(comments) }
        }
      } }
    }
    """
    private static let threadQuery = """
    query($id: ID!, $after: String) { node(id: $id) { ... on PullRequestReviewThread {
      id path line isResolved viewerCanResolve pullRequest { url headRefOid state }
      comments(first: 20, after: $after) { totalCount pageInfo { hasNextPage endCursor } nodes { id body url author { login } } }
    } } }
    """
}
