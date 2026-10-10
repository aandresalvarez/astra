import CryptoKit
import Foundation
import MCPServerKit

/// The names the GitHub review request answers to, read by the broker, the
/// `astra-host-control` parser, the app's shell policy for CLI-relay runtimes,
/// and the app's own review-file rule, so the four cannot disagree about which
/// file a request may name.
public enum GitHubReviewHostControlOperations {
    public static let postReview = "post_review"
    public static let reviewFileKey = "review_file"
    /// The CLI relay's spelling: `astra-host-control github --post-review NAME`.
    public static let postReviewOption = "--post-review"

    /// A review file's name: `github_review.json`, or `pr<NUMBER>_review.json`
    /// with an optional `_<suffix>` for a later, separate review.
    public static func isReviewFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "github_review.json"
            || lower.range(of: #"^pr[0-9]+_review(?:_[a-z0-9-]+)?\.json$"#, options: .regularExpression) != nil
    }
}

/// Reads the review file a request names and asks ASTRA to post it. Reaches no
/// network: ASTRA posts it, or tells the agent the user will.
///
/// The file is read here so the request carries the digest of the bytes the
/// agent asked about. ASTRA posts the file only while it still holds them, which
/// binds what is eligible to this request's artifact and its content — never to
/// whichever review file a run happened to write or touch.
enum GitHubReviewPostPolicy {
    /// The app refuses a larger review file, so reading past it here would only
    /// move the refusal.
    static let reviewFileByteLimit = 256 * 1024

    /// The `github` tool's schema: the gh command route, plus the typed
    /// request. Either `arguments` or `operation`, never both — `handle`
    /// refuses a mix — so `arguments` is no longer required.
    static func githubSchema(base: [String: Any]) -> [String: Any] {
        var schema = base
        guard var input = schema["inputSchema"] as? [String: Any],
              var properties = input["properties"] as? [String: Any] else { return schema }
        properties["operation"] = [
            "type": "string",
            "enum": [GitHubReviewHostControlOperations.postReview],
            "description": "post_review: ask ASTRA to post the review file named by review_file. Omit for a gh command. "
                + "timeout_seconds is accepted but does not apply: ASTRA bounds the post itself."
        ]
        properties[GitHubReviewHostControlOperations.reviewFileKey] = [
            "type": "string",
            "description": "For post_review: the review file's name in the task folder, for example pr12_review.json. "
                + "A file name, not a path."
        ]
        input["properties"] = properties
        input.removeValue(forKey: "required")
        schema["inputSchema"] = input
        return schema
    }

    static func handle(
        arguments: [String: Any],
        configuration: HostControlToolConfiguration,
        requester: (any BrokeredExternalActionRequesting)?,
        diagnostics: HostControlToolDiagnosticsRecorder?
    ) -> MCPServerReply {
        let fileKey = GitHubReviewHostControlOperations.reviewFileKey
        // `timeout_seconds` is in the tool's schema for its gh commands, and a
        // client that sends it on every call must still be able to ask. It
        // does not apply here: ASTRA bounds the post, and a shorter wait
        // could only turn an answer into "not known yet".
        let unknown = Set(arguments.keys).subtracting(["operation", fileKey, "timeout_seconds"]).sorted()
        guard unknown.isEmpty else {
            return .error(
                code: -32602,
                message: "github post_review takes only operation, \(fileKey) and timeout_seconds; "
                    + "\(unknown.joined(separator: ", ")) belong to a gh command, which is a separate call"
            )
        }
        guard (arguments["operation"] as? String)?.lowercased() == GitHubReviewHostControlOperations.postReview else {
            return .error(
                code: -32602,
                message: "github operation must be \(GitHubReviewHostControlOperations.postReview); "
                    + "for a gh command pass arguments instead"
            )
        }
        guard let name = arguments[fileKey] as? String,
              GitHubReviewHostControlOperations.isReviewFileName(name) else {
            return .error(
                code: -32602,
                message: "github post_review needs \(fileKey): the name of the review file in the task folder, "
                    + "for example pr12_review.json or pr12_review_2.json. It is a file name, not a path."
            )
        }
        guard !configuration.taskFolder.isEmpty else {
            return .error(
                code: -32602,
                message: "No task folder is projected, so \(name) cannot be read where ASTRA would find it"
            )
        }
        let data: Data
        do {
            data = try TaskFolderContainment.readRegularFile(
                named: name,
                beneath: TaskFolderContainment.resolvedRoot(configuration.taskFolder),
                byteLimit: reviewFileByteLimit,
                refusal: "read a review file",
                makeError: { GitHubReviewPostError($0) }
            )
        } catch {
            return .error(code: -32602, message: error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let outcome = requester?.postGitHubReview(
            GitHubReviewPostRequest(fileName: name, contentDigest: digest)
        ) ?? .awaitingReview
        diagnostics?.record(
            toolName: "github",
            summary: "github post_review \(name) \(digest) \(outcome.diagnosticWord)",
            result: nil
        )
        return reply(outcome, fileName: name, digest: digest)
    }

    private static func reply(
        _ outcome: BrokeredExternalActionOutcome,
        fileName: String,
        digest: String
    ) -> MCPServerReply {
        var lines = ["review_file: \(fileName)", "content_digest: \(digest)"]
        let isError: Bool
        switch outcome {
        case .awaitingReview:
            isError = false
            lines.append("posted: false")
            lines.append("""
                note: nothing was posted. ASTRA will show this exact review to the user, who decides \
                whether to post it with Post review. Report it as waiting for their review. Do not ask \
                again and do not post it another way.
                """)
        case .performed(let receipt):
            isError = false
            lines.append("posted: true")
            if let url = receipt.url { lines.append("review_url: \(url)") }
            lines.append("""
                note: ASTRA posted this exact file to GitHub when you asked, because this task's \
                permission level (Auto) does not ask first, and recorded it in the chat. Report the \
                link. Do not ask again: this file is posted, and a new review needs a new file name.
                """)
        case .refused(let message):
            isError = true
            lines.append("posted: false")
            lines.append("error: \(message)")
            lines.append("""
                note: nothing was posted. If the error names something you can fix, write the \
                corrected review to a new file name (for example pr12_review_2.json) and ask again; \
                otherwise report the error. Do not post it another way.
                """)
        case .uncertain(let message):
            isError = true
            lines.append("posted: unknown")
            lines.append("error: \(message)")
            lines.append("""
                note: ASTRA may have posted this review and will not post this file again. Do not ask \
                again: check the pull request's reviews with the github tool and report what you find.
                """)
        }
        return .result([
            "content": [["type": "text", "text": lines.joined(separator: "\n")]],
            "isError": isError
        ])
    }
}

struct GitHubReviewPostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension BrokeredExternalActionOutcome {
    /// One word for the diagnostics line; never a message, which can quote a
    /// provider's reply.
    var diagnosticWord: String {
        switch self {
        case .awaitingReview: "awaiting_review"
        case .performed: "performed"
        case .refused: "refused"
        case .uncertain: "uncertain"
        }
    }
}
