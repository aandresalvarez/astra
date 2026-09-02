import Foundation
import ASTRAModels

enum ConnectorMutationEventTypes {
    static let staged = "connector.mutation.staged"
    static let approved = "connector.mutation.approved"
    static let receipt = "connector.mutation.receipt"
    static let failed = "connector.mutation.failed"
    /// ASTRA dispatched the write and never learned whether it took.
    ///
    /// Distinct from `failed` because it is not one: a failure says the write
    /// did not happen, and this says nobody knows. They have to be different
    /// events because they retire the proposal differently — a failure leaves it
    /// sendable, and this must not.
    static let indeterminate = "connector.mutation.indeterminate"
    static let declined = "connector.mutation.declined"
}

/// The durable record that the agent composed a mutation and ASTRA has not yet
/// sent it.
///
/// The staged file is what the user reviews, but a file is not a state machine:
/// it says a payload exists, not whether it has been sent, refused, or already
/// failed. This event is the state. It also survives a relaunch, which matters
/// because the review can outlive the run that produced it.
///
/// It carries a pointer and a scope, never the ticket body. The body stays in
/// the staged file, where it is read once at review time and once more at
/// commit time — and `requestDigest` is what makes those two reads provably the
/// same bytes.
struct TaskStagedConnectorMutation: Codable, Sendable, Equatable, Identifiable {
    let version: Int
    let runID: UUID
    /// Lowercased connector service type, e.g. `jira`.
    let serviceType: String
    /// What ASTRA would do if approved, e.g. `create_issue` — not the
    /// `propose_issue` the agent called.
    let operation: String
    /// The connector's `AgentConnector.id` as a UUID string. Parsed, not
    /// trusted: commit refuses a value that is not a UUID naming a projected
    /// connector.
    let connectorID: String
    let connectorAlias: String
    /// Self-describing destination, e.g. `STAR / Bug`.
    let target: String
    /// One line of content, for the dock row. The reviewable payload is the
    /// staged file.
    let summary: String
    /// Where the envelope lives, and the proposal's identity. The broker gives
    /// every proposal its own file (run + sequence, probed for a free name), so
    /// this is unique per act of proposing.
    let stagedPayloadPath: String
    /// SHA-256 over the staged bytes, lowercase hex.
    ///
    /// Integrity, deliberately *not* identity. Digest-as-identity collapsed two
    /// proposals whose content happened to match: asking twice for the same
    /// ticket produced one reviewable row, and re-proposing a ticket the user
    /// had declined was silently swallowed, because the second proposal looked
    /// like a replay of the first. Content equality is not intent equality.
    let requestDigest: String

    var id: String { stagedPayloadPath }

    init(
        runID: UUID,
        serviceType: String,
        operation: String,
        connectorID: String,
        connectorAlias: String,
        target: String,
        summary: String,
        stagedPayloadPath: String,
        requestDigest: String
    ) {
        version = 1
        self.runID = runID
        self.serviceType = serviceType
        self.operation = operation
        self.connectorID = connectorID
        self.connectorAlias = connectorAlias
        self.target = target
        self.summary = summary
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
    }
}

/// Reads pending connector mutations out of durable task events.
///
/// Deliberately event-driven rather than filesystem-driven. The staging
/// directory is the broker's channel into the app and is read exactly once, at
/// the run boundary; after that the events are the authority. A resolver that
/// re-scanned the directory would run in a SwiftUI view body — and would also
/// resurrect a proposal the user already declined, because declining does not
/// delete the file the user might still want to read.
enum ConnectorMutationRequirementResolver {
    /// Every staged mutation that has not since been sent, declined, or failed
    /// terminally — oldest first, so the user works through them in the order
    /// the agent composed them.
    @MainActor
    static func pendingMutations(task: AgentTask) -> [TaskStagedConnectorMutation] {
        let ordered = task.events.sorted(by: isChronologicallyOrdered)
        let decoder = TaskEventPayloadCodec.makeDecoder()

        var pending: [String: TaskStagedConnectorMutation] = [:]
        var order: [String] = []
        for event in ordered {
            switch event.type {
            case ConnectorMutationEventTypes.staged:
                guard let data = event.payload.data(using: .utf8),
                      let staged = try? decoder.decode(TaskStagedConnectorMutation.self, from: data) else {
                    continue
                }
                if pending.updateValue(staged, forKey: staged.stagedPayloadPath) == nil {
                    order.append(staged.stagedPayloadPath)
                }
            case ConnectorMutationEventTypes.receipt,
                 ConnectorMutationEventTypes.indeterminate,
                 ConnectorMutationEventTypes.declined:
                // Resolution is keyed by the staged file for the same reason
                // approval is: a second proposal in the same task is a different
                // thing even when it says the same words, and sending or
                // declining one must not retire the other.
                guard let path = resolvedStagedPath(in: event.payload) else { continue }
                pending.removeValue(forKey: path)
            default:
                continue
            }
        }
        return order.compactMap { pending[$0] }
    }

    @MainActor
    static func hasPendingMutation(task: AgentTask) -> Bool {
        !pendingMutations(task: task).isEmpty
    }

    /// Every staged file this task has ever recorded, pending or resolved.
    ///
    /// What makes rescanning idempotent, and it deliberately includes resolved
    /// ones: a proposal that was sent or declined must not come back as new
    /// because the file is still sitting in the staging directory.
    ///
    /// Paths rather than digests, so the scan can decide what is new from the
    /// directory listing alone — and so an agent that composes the same ticket
    /// twice gets two reviews rather than one.
    @MainActor
    static func recordedStagedPaths(task: AgentTask) -> Set<String> {
        let decoder = TaskEventPayloadCodec.makeDecoder()
        return Set(
            task.events
                .filter { $0.type == ConnectorMutationEventTypes.staged }
                .compactMap { event -> String? in
                    guard let data = event.payload.data(using: .utf8),
                          let staged = try? decoder.decode(TaskStagedConnectorMutation.self, from: data) else {
                        return nil
                    }
                    return staged.stagedPayloadPath
                }
        )
    }

    /// A failure is not a resolution. A Jira `POST` that came back `400` leaves
    /// the proposal exactly as reviewable as it was, so the row stays and the
    /// user can send it again.
    ///
    /// An *indeterminate* outcome is a resolution, and that is the difference
    /// worth stating. It says ASTRA put the request on the wire and never got a
    /// usable answer — a dropped connection, a timeout, a gateway `503` that may
    /// sit in front of a Jira that already filed the ticket. Leaving that row
    /// pending would offer a second POST for a write that may already exist, and
    /// a duplicate ticket is the one outcome here that cannot be undone. So it
    /// retires, and the receipt the user gets is a sentence telling them to go
    /// look.
    private static func resolvedStagedPath(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["stagedPayloadPath"] as? String ?? object["staged_payload_path"] as? String else {
            return nil
        }
        return path.isEmpty ? nil : path
    }

    private static func isChronologicallyOrdered(_ lhs: TaskEvent, _ rhs: TaskEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
