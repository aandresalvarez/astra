import Foundation
import SwiftData
import ASTRACore
import ASTRALogging
import ASTRAModels
import HostControlToolSupport

/// ASTRA's answer to a broker asking it to act outside the machine, for one run.
///
/// Bound when the run launches, to the task, the run, and the user-facing level
/// the run launched with (`RunPermissionManifest.policyLevel`), so a request can
/// choose none of them and switching the task's level mid-run changes nothing
/// the run already asked. `ExternalActionPolicy` decides: where the level asks,
/// nothing happens here and the user reviews the proposal after the run, as
/// before; where it does not, the write is sent now, through the same services
/// the review sheets use, and its receipt is the agent's tool result.
@MainActor
final class BrokeredExternalActionHandler {
    typealias CoordinatorFactory = @MainActor (ModelContext) -> ConnectorMutationCoordinator
    typealias ReviewServiceFactory = @MainActor (ModelContext) -> GitHubReviewPublicationService

    private let modelContext: ModelContext
    private let taskID: UUID
    private let runID: UUID
    private let policyLevel: AgentPolicyLevel
    private let makeCoordinator: CoordinatorFactory
    private let makeReviewService: ReviewServiceFactory

    init(
        modelContext: ModelContext,
        taskID: UUID,
        runID: UUID,
        policyLevel: AgentPolicyLevel,
        makeCoordinator: @escaping CoordinatorFactory = { ConnectorMutationCoordinator(modelContext: $0) },
        makeReviewService: @escaping ReviewServiceFactory = { GitHubReviewPublicationService(modelContext: $0) }
    ) {
        self.modelContext = modelContext
        self.taskID = taskID
        self.runID = runID
        self.policyLevel = policyLevel
        self.makeCoordinator = makeCoordinator
        self.makeReviewService = makeReviewService
    }

    func sendStagedConnectorMutation(_ request: StagedConnectorMutationRequest) async -> BrokeredExternalActionOutcome {
        guard !ExternalActionPolicy.asksUser(for: .connectorMutation, level: policyLevel) else {
            return .awaitingReview
        }
        // A run ASTRA cannot find has no record to send under; the file stays
        // where the run-boundary scan offers it for review.
        guard let task = task(), let run = task.runs.first(where: { $0.id == runID }) else {
            return .awaitingReview
        }
        do {
            let receipt = try await makeCoordinator(modelContext).sendWhenProposed(
                task: task,
                run: run,
                stagedPath: request.stagedPath,
                requestDigest: request.requestDigest,
                timeoutSeconds: request.timeoutSeconds.map(Self.sendTimeout)
            )
            return .performed(BrokeredExternalActionReceipt(identifier: receipt.createdKey, url: receipt.createdURL))
        } catch let error as ConnectorMutationCoordinatorError {
            audit("connector_mutation_auto_send_refused", error: error, uncertain: error.isTerminal)
            switch error {
            case .proposalNotRecorded:
                // Nothing went out and nothing is recorded, so the staged file
                // is what the run-boundary scan finds and offers for review.
                return .awaitingReview
            default:
                return error.isTerminal
                    ? .uncertain(message: error.localizedDescription)
                    : .refused(message: error.localizedDescription)
            }
        } catch {
            audit("connector_mutation_auto_send_refused", error: error, uncertain: false)
            return .refused(message: error.localizedDescription)
        }
    }

    func postGitHubReview(_ request: GitHubReviewPostRequest) async -> BrokeredExternalActionOutcome {
        guard !ExternalActionPolicy.asksUser(for: .githubReviewPublication, level: policyLevel) else {
            return .awaitingReview
        }
        guard let task = task() else { return .awaitingReview }
        do {
            let record = try await makeReviewService(modelContext).publishWhenRequested(
                task: task,
                fileName: request.fileName,
                contentDigest: request.contentDigest
            )
            return .performed(BrokeredExternalActionReceipt(
                identifier: record.reviewID.map { "review \($0)" },
                url: record.reviewURL
            ))
        } catch let error as GitHubReviewPublicationError {
            let uncertain: Bool = switch error {
            case .alreadyDispatched, .uncertain, .receiptPersistenceFailed: true
            default: false
            }
            audit("github_review_auto_post_refused", error: error, uncertain: uncertain)
            return uncertain ? .uncertain(message: error.localizedDescription) : .refused(message: error.localizedDescription)
        } catch {
            // Before dispatch was recorded — a failed check against GitHub, or
            // a store that would not take the dispatch record — so nothing was
            // posted.
            audit("github_review_auto_post_refused", error: error, uncertain: false)
            return .refused(message: error.localizedDescription)
        }
    }

    /// The caller's timeout, kept inside the broker's wait: a send that
    /// outlived it would answer "not known yet" for a write that finished.
    static let longestSendSeconds = BrokeredExternalActionBridge.defaultTimeoutSeconds - 30

    nonisolated static func sendTimeout(_ requested: TimeInterval) -> TimeInterval {
        min(max(requested, 5), longestSendSeconds)
    }

    private func task() -> AgentTask? {
        let taskID = taskID
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// The error's type only: its message can quote a provider's reply.
    private func audit(_ operation: String, error: Error, uncertain: Bool) {
        AppLogger.audit(.runtimeMCPPolicy, category: "Worker", taskID: taskID, fields: [
            "operation": operation,
            "run_id": runID.uuidString,
            "outcome": uncertain ? "uncertain" : "refused",
            "error_type": String(describing: type(of: error))
        ], level: uncertain ? .error : .warning)
    }
}

/// Carries a broker request, which arrives on the broker's connection thread,
/// to the handler on the main actor, and waits for the answer.
///
/// The broker's MCP server answers one line at a time and synchronously, so the
/// wait is a semaphore on that thread — a GCD thread, never one from Swift's
/// cooperative pool and never the main thread, which is the one being waited on.
/// The wait is bounded: a send that outlives it keeps going and records its own
/// outcome, and the agent is told the outcome is not known yet, so it does not
/// ask twice.
final class BrokeredExternalActionBridge: BrokeredExternalActionRequesting, @unchecked Sendable {
    /// Under the CLI relay's 305-second receive timeout, so the agent hears this
    /// answer rather than a dropped connection.
    static let defaultTimeoutSeconds: TimeInterval = 240

    private let handler: BrokeredExternalActionHandler
    private let timeoutSeconds: TimeInterval

    init(handler: BrokeredExternalActionHandler, timeoutSeconds: TimeInterval = defaultTimeoutSeconds) {
        self.handler = handler
        self.timeoutSeconds = timeoutSeconds
    }

    func sendStagedConnectorMutation(_ request: StagedConnectorMutationRequest) -> BrokeredExternalActionOutcome {
        wait { await $0.sendStagedConnectorMutation(request) }
    }

    func postGitHubReview(_ request: GitHubReviewPostRequest) -> BrokeredExternalActionOutcome {
        wait { await $0.postGitHubReview(request) }
    }

    private func wait(
        _ work: @escaping @MainActor @Sendable (BrokeredExternalActionHandler) async -> BrokeredExternalActionOutcome
    ) -> BrokeredExternalActionOutcome {
        // Waiting here would wait on itself. The broker never calls from the
        // main thread; if something ever does, nothing is sent and the
        // proposal stays for the user's review.
        guard !Thread.isMainThread else { return .awaitingReview }
        let answer = BrokeredExternalActionAnswer()
        let semaphore = DispatchSemaphore(value: 0)
        let handler = handler
        Task { @MainActor in
            answer.set(await work(handler))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success, let outcome = answer.value else {
            return .uncertain(message: """
                ASTRA did not finish within \(Int(timeoutSeconds)) seconds. It keeps going and records \
                what happened in the chat; it may already have happened.
                """)
        }
        return outcome
    }
}

private final class BrokeredExternalActionAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrokeredExternalActionOutcome?

    var value: BrokeredExternalActionOutcome? {
        lock.withLock { stored }
    }

    func set(_ outcome: BrokeredExternalActionOutcome) {
        lock.withLock { stored = outcome }
    }
}
