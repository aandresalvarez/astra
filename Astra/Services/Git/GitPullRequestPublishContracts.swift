import Foundation

/// Whether publication may proceed immediately or must be bound to an exact,
/// user-approved proposal. Policy resolution happens outside this service; the
/// typed value prevents Ask mode from accidentally using the automatic path.
enum GitPullRequestPublishAuthorizationRequirement: String, Codable, Sendable {
    case automatic
    case explicitApproval
}

/// Exact caller intent for creating one new branch, one commit, and one draft
/// pull request. The expected SHA prevents a stale task from publishing a
/// different repository state than the one it inspected.
struct GitPullRequestPublishRequest: Equatable, Codable, Sendable {
    let repositoryPath: String
    let remote: String
    let baseBranch: String
    let headBranch: String
    let expectedHeadSHA: String
    let selectedPaths: [String]
    let commitMessage: String
    let pullRequestTitle: String
    let pullRequestBody: String
    let authorizationRequirement: GitPullRequestPublishAuthorizationRequirement

    init(
        repositoryPath: String,
        remote: String = "origin",
        baseBranch: String,
        headBranch: String,
        expectedHeadSHA: String,
        selectedPaths: [String],
        commitMessage: String,
        pullRequestTitle: String,
        pullRequestBody: String,
        authorizationRequirement: GitPullRequestPublishAuthorizationRequirement
    ) {
        self.repositoryPath = repositoryPath
        self.remote = remote
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.expectedHeadSHA = expectedHeadSHA
        self.selectedPaths = selectedPaths
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
        self.authorizationRequirement = authorizationRequirement
    }
}

/// Immutable state for one selected path. Diff hashes bind approval to file
/// contents without persisting potentially sensitive source in the proposal.
struct GitPullRequestPublishFileState: Equatable, Codable, Sendable {
    let relativePath: String
    let originalPath: String?
    let status: String
    let isStaged: Bool
    let diffSHA256: String
}

/// Deterministic, reviewable publication plan. `proposalID` is a SHA-256 over
/// every scoped field and file-state hash, so an approval cannot be replayed
/// after the repo, destination, selected content, or authored text changes.
struct GitPullRequestPublishProposal: Equatable, Codable, Sendable {
    let proposalID: String
    let repositoryPath: String
    let remote: String
    let remoteURL: String
    let baseBranch: String
    let baseSHA: String
    let headBranch: String
    let expectedHeadSHA: String
    let selectedPaths: [String]
    let selectedFileStates: [GitPullRequestPublishFileState]
    let commitMessage: String
    let pullRequestTitle: String
    let pullRequestBody: String
    let isDraft: Bool
    let authorizationRequirement: GitPullRequestPublishAuthorizationRequirement
    let existingPullRequest: GitHubPullRequestRef?

    var requiresExplicitApproval: Bool {
        authorizationRequirement == .explicitApproval && existingPullRequest == nil
    }
}

/// Ask-mode consent must carry the exact proposal identifier presented to the
/// user. Approving an older preview fails closed when any scoped input drifts.
struct GitPullRequestPublishApproval: Equatable, Codable, Sendable {
    let proposalID: String

    init(proposalID: String) {
        self.proposalID = proposalID
    }
}

enum GitPullRequestPublishCheckpointState: String, Equatable, Codable, Sendable {
    case committed
    case pushed
}

/// Exact local/remote state recorded after the irreversible commit boundary.
/// A retry may resume only when the proposal and every ref still match this
/// checkpoint, preventing duplicate commits or pushes after a PR API failure.
struct GitPullRequestPublishCheckpoint: Equatable, Codable, Sendable {
    let proposalID: String
    let repositoryPath: String
    let remote: String
    let baseBranch: String
    let headBranch: String
    let commitSHA: String
    let state: GitPullRequestPublishCheckpointState
}

protocol GitPullRequestPublishCheckpointStoring: Sendable {
    func checkpoint(for proposalID: String) async -> GitPullRequestPublishCheckpoint?
    func save(_ checkpoint: GitPullRequestPublishCheckpoint) async
    func removeCheckpoint(for proposalID: String) async
}

/// Process-lifetime default. Task orchestration can inject a durable store that
/// persists the same Codable checkpoint beside task/run state.
actor InMemoryGitPullRequestPublishCheckpointStore: GitPullRequestPublishCheckpointStoring {
    static let shared = InMemoryGitPullRequestPublishCheckpointStore()

    private var checkpoints: [String: GitPullRequestPublishCheckpoint] = [:]

    func checkpoint(for proposalID: String) -> GitPullRequestPublishCheckpoint? {
        checkpoints[proposalID]
    }

    func save(_ checkpoint: GitPullRequestPublishCheckpoint) {
        checkpoints[checkpoint.proposalID] = checkpoint
    }

    func removeCheckpoint(for proposalID: String) {
        checkpoints.removeValue(forKey: proposalID)
    }
}

enum GitPullRequestPublishReceiptSource: String, Equatable, Codable, Sendable {
    case created
    case existing
}

enum GitPullRequestPublishReceiptVerification: String, Equatable, Codable, Sendable {
    case createResponseURL
    case existingPullRequestLookup
}

/// Durable proof that the requested external outcome exists. Completion code
/// can require this receipt instead of treating a provider exit code as proof.
struct GitPullRequestPublishReceipt: Equatable, Codable, Sendable {
    let proposalID: String
    let repositoryPath: String
    let remote: String
    let remoteURL: String
    let baseBranch: String
    let baseSHA: String
    let headBranch: String
    let commitSHA: String
    let selectedPaths: [String]
    let commitMessage: String
    let pullRequestTitle: String
    let pullRequestBody: String
    let pullRequestNumber: Int
    let pullRequestURL: String
    let isDraft: Bool
    let source: GitPullRequestPublishReceiptSource
    let verification: GitPullRequestPublishReceiptVerification
    let completedAt: Date
}

enum GitPullRequestPublishPhase: String, Equatable, Sendable {
    case preflight
    case createBranch
    case stageFiles
    case commit
    case push
    case createPullRequest
}

enum GitPullRequestPublishError: LocalizedError, Equatable {
    case invalidRequest(String)
    case unableToResolveCommit(String)
    case expectedHeadMismatch(expected: String, actual: String)
    case remoteBaseMismatch(expectedHead: String, remoteBase: String)
    case remoteUnavailable(String)
    case pullRequestLookupUnavailable(String)
    case headBranchAlreadyExists(String)
    case selectedChangesMissing([String])
    case selectedChangesConflicted([String])
    case unrelatedStagedChanges([String])
    case selectedContentUnavailable(String)
    case proposalChanged
    case approvalRequired(String)
    case approvalMismatch(expected: String, actual: String)
    case repositoryBusy
    case invalidPullRequestURL(String)
    case operationFailed(phase: GitPullRequestPublishPhase, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(reason):
            return "The pull request publication request is invalid: \(reason)"
        case let .unableToResolveCommit(ref):
            return "ASTRA could not resolve \(ref) to an exact commit."
        case let .expectedHeadMismatch(expected, actual):
            return "Repository HEAD changed after publication was requested (expected \(expected), found \(actual))."
        case let .remoteBaseMismatch(expectedHead, remoteBase):
            return "The requested starting commit \(expectedHead) is not the remote base commit \(remoteBase). Publishing would include unreviewed commits."
        case let .remoteUnavailable(remote):
            return "Git remote \(remote) is unavailable."
        case let .pullRequestLookupUnavailable(reason):
            return "ASTRA could not safely check for an existing pull request: \(reason)"
        case let .headBranchAlreadyExists(branch):
            return "Branch \(branch) already exists without an open pull request."
        case let .selectedChangesMissing(paths):
            return "Selected changes are no longer present: \(paths.joined(separator: ", "))."
        case let .selectedChangesConflicted(paths):
            return "Conflicted files cannot be published: \(paths.joined(separator: ", "))."
        case let .unrelatedStagedChanges(paths):
            return "Unselected files are already staged and would enter the commit: \(paths.joined(separator: ", "))."
        case let .selectedContentUnavailable(path):
            return "ASTRA could not capture the complete diff for \(path)."
        case .proposalChanged:
            return "The publication proposal no longer matches the approved repository state."
        case let .approvalRequired(proposalID):
            return "Explicit approval is required for publication proposal \(proposalID)."
        case let .approvalMismatch(expected, actual):
            return "Approval \(actual) does not match publication proposal \(expected)."
        case .repositoryBusy:
            return "Another Git operation is already changing this repository."
        case let .invalidPullRequestURL(url):
            return "GitHub returned an invalid pull request URL: \(url)"
        case let .operationFailed(phase, message):
            return "Pull request publication failed during \(phase.rawValue): \(message)"
        }
    }
}
