import CryptoKit
import Foundation
import ASTRAModels
import HostControlToolSupport

struct GitHubReviewThreadPayload: Codable {
    struct Action: Codable {
        let threadId: String
        let expectedLastCommentId: String
        let reply: String?
        let resolve: Bool
    }
    let pullRequestUrl: String
    let commitId: String
    let threads: [Action]
}

struct GitHubReviewThreadSnapshot: Codable {
    struct PullRequest: Codable { let url: String; let headRefOid: String; let state: String }
    struct Comment: Codable {
        struct Author: Codable { let login: String }
        let id: String
        let body: String
        let url: String
        let author: Author?
    }
    let id: String
    let path: String
    let line: Int?
    let isResolved: Bool
    let viewerCanResolve: Bool
    let viewerCanReply: Bool
    let pullRequest: PullRequest
    var comments: [Comment]
}

struct GitHubReviewThreadProposal: Identifiable {
    let id: String
    let filePath: String
    let digest: String
    let payload: GitHubReviewThreadPayload
    let snapshots: [GitHubReviewThreadSnapshot]
}

struct GitHubReviewThreadReceipt: Codable {
    struct Action: Codable {
        let threadID: String
        let operation: String
        let commentID: String?
        let url: String?
    }
    let proposalID: String
    let filePath: String
    let pullRequestURL: String
    let actions: [Action]
    var approvedPayload: GitHubReviewThreadPayload? = nil
    /// The operations the approved payload required ("thread:reply", "thread:resolve"). The
    /// recovery mirror compacts old dispatches to this summary in place of the payload.
    var requiredActions: [String]? = nil
}

/// A thread proposal ASTRA found unusable (stale head, resolved or edited thread,
/// foreign target, invalid file). It is not offered again; the agent prepares a
/// corrected proposal under a new versioned filename.
struct GitHubReviewThreadDismissal: Codable {
    let filePath: String
    let reason: String
}

enum GitHubReviewThreadEvents {
    static let dispatched = "github.review-threads.dispatched"
    static let actionReceipt = "github.review-threads.action-receipt"
    static let receipt = "github.review-threads.receipt"
    static let receiptRecovery = "github.review-threads.receipt-recovery"
    static let indeterminate = "github.review-threads.indeterminate"
    static let dismissed = "github.review-threads.dismissed"
}

enum GitHubReviewThreadArtifactPolicy {
    static func isProposalFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.range(
            of: #"^pr[1-9][0-9]*_threads(?:_[a-z0-9-]+)?\.json$"#, options: .regularExpression
        ) != nil
    }

    static func target(_ url: String) -> (repository: String, number: Int)? {
        guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "pull",
              let number = Int(path[4]), number > 0, String(number) == path[4] else { return nil }
        let repository = "\(path[1])/\(path[2])"
        return GitHubReviewThreadReadOperation.isRepository(repository) ? (repository, number) : nil
    }

    /// A proposal's identity within its task folder, so evidence recorded under one
    /// absolute path still matches after the workspace was moved or renamed.
    static func identity(of path: String) -> String {
        guard let range = path.range(of: "/tasks/", options: .backwards) else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let afterTasks = path[range.upperBound...]
        guard let slash = afterTasks.firstIndex(of: "/") else { return String(afterTasks) }
        return String(afterTasks[afterTasks.index(after: slash)...])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
