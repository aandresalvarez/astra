import ASTRAGitContracts
import Foundation

/// ASTRA-only subcommands of the existing GitHub tool, shared by its MCP and
/// CLI relay transports. Only ASTRA supplies the GraphQL document and flags.
enum GitHubReviewReadCommand {
    static let usage = "pr review-threads NUMBER --repo OWNER/REPO, or pr thread-comments THREAD_ID. "
        + "Both accept --after END_CURSOR and --limit 1-100 (default 20)."

    struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "Expected \(usage)" }
    }

    static func ghArguments(for arguments: [String]) throws -> [String]? {
        let isThreads = arguments.starts(with: ["pr", "review-threads"])
        guard isThreads || arguments.starts(with: ["pr", "thread-comments"]) else { return nil }
        var remaining = arguments.dropFirst(2)
        guard let target = remaining.popFirst(), validValue(target) else { throw InvalidArguments() }
        var options: [String: String] = [:]
        while let option = remaining.popFirst() {
            guard ["--repo", "--after", "--limit"].contains(option), options[option] == nil,
                  let value = remaining.popFirst(), validValue(value) else { throw InvalidArguments() }
            options[option] = value
        }
        guard let limit = Int(options["--limit"] ?? "20"), (1...100).contains(limit) else {
            throw InvalidArguments()
        }
        if isThreads {
            guard let number = Int32(target), number > 0, let repo = options["--repo"],
                  repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            else { throw InvalidArguments() }
            let parts = repo.split(separator: "/")
            return GitHubReviewThreads.pullRequestArguments(
                owner: String(parts[0]), name: String(parts[1]), number: Int(number),
                pageSize: limit, after: options["--after"], includeConversation: false
            )
        }
        guard options["--repo"] == nil else { throw InvalidArguments() }
        return GitHubReviewThreads.commentArguments(threadID: target, pageSize: limit, after: options["--after"])
    }

    private static func validValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
