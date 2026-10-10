import Foundation

/// How the broker asks ASTRA to act outside the machine for the run it serves.
///
/// The broker never sends anything itself. It stages a connector write, or reads
/// a review file the agent names, and asks. ASTRA answers from the run's
/// permission level, which the broker never reads: where that level asks first
/// the answer is `awaitingReview` and the user decides later in a sheet; where
/// it does not, ASTRA sends through the same checks the sheet uses and answers
/// with what happened. The agent gets that answer as its tool result, so it can
/// build on a key the write created, and nothing about the send waits for the
/// run to end (spec decision 15).
///
/// Bound by ASTRA to one task and run when the broker session is prepared, like
/// `TaskHistoryReading`: nothing in a request chooses the task, the run, or the
/// level. A broker with no requester — the standalone helper, or a run ASTRA did
/// not bind — answers every request as `awaitingReview`.
public protocol BrokeredExternalActionRequesting: Sendable {
    /// Asks ASTRA to send a connector write the broker has just staged.
    func sendStagedConnectorMutation(_ request: StagedConnectorMutationRequest) -> BrokeredExternalActionOutcome
    /// Asks ASTRA to post a pull-request review file the agent wrote.
    func postGitHubReview(_ request: GitHubReviewPostRequest) -> BrokeredExternalActionOutcome
}

public struct StagedConnectorMutationRequest: Equatable, Sendable {
    /// The envelope the broker wrote for this request, never one the agent named.
    public let stagedPath: String
    /// SHA-256 of the bytes the broker wrote. ASTRA sends only those bytes.
    public let requestDigest: String
    /// The `timeout_seconds` the call carried, already bounded by the broker,
    /// or nil for ASTRA's default. The send happens now, so the timeout the
    /// tool advertises is the one it gets.
    public let timeoutSeconds: TimeInterval?

    public init(stagedPath: String, requestDigest: String, timeoutSeconds: TimeInterval? = nil) {
        self.stagedPath = stagedPath
        self.requestDigest = requestDigest
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct GitHubReviewPostRequest: Equatable, Sendable {
    /// A bare file name directly under the task folder. ASTRA resolves it
    /// against its own record of the task folder, not against a path the broker
    /// or the agent spelled.
    public let fileName: String
    /// SHA-256 of the bytes the broker read when the agent asked. ASTRA posts the
    /// file only while it still holds exactly these bytes, so what is eligible is
    /// this request's artifact, never whatever review file a run touched.
    public let contentDigest: String

    public init(fileName: String, contentDigest: String) {
        self.fileName = fileName
        self.contentDigest = contentDigest
    }
}

/// What ASTRA did with a request.
public enum BrokeredExternalActionOutcome: Equatable, Sendable {
    /// This run's level asks first. Nothing was sent; the user reviews it.
    case awaitingReview
    /// Sent, with what the destination answered.
    case performed(BrokeredExternalActionReceipt)
    /// Not sent, and nothing went out.
    case refused(message: String)
    /// It may have happened. ASTRA will not send it again, and the agent must
    /// not ask again: a second request could be a second write.
    case uncertain(message: String)
}

public struct BrokeredExternalActionReceipt: Equatable, Sendable {
    /// What the destination named the result, e.g. `STAR-12558`.
    public let identifier: String?
    /// Where to see it.
    public let url: String?

    public init(identifier: String?, url: String?) {
        self.identifier = identifier
        self.url = url
    }
}
