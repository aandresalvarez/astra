import Foundation
import SwiftData
import ASTRACore
import ASTRALogging
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

/// What ASTRA held back from a run, and what it would take to release it.
///
/// The offered tier hands a run the *route* to a connector the turn never named
/// and withholds the *secret*, because narration is what the user consented to
/// and reachability is not. That trade is right, and it has one loose end: the
/// run finds a tool it cannot use and no one is ever asked about it. Nothing in
/// here changes the trade — it makes the loose end reachable.
struct BrokeredCredentialApprovalRecord: Sendable, Equatable {
    var connectorID: UUID
    var connectorName: String
    var alias: String
    var serviceType: String
    var credentialLabels: [String]

    /// Stable across runs and across records for the same connector, so
    /// re-recording replaces the open request instead of stacking another copy
    /// of it in the dock.
    var requestID: String {
        Self.offerRequestID(forConnectors: [connectorID])
    }

    static let offerRequestIDPrefix = "connector-credentials-"

    /// The open request's id for an offer covering `connectorIDs`: one
    /// connector keeps the id it always had, and a set gets one id of its own.
    static func offerRequestID(forConnectors connectorIDs: [UUID]) -> String {
        offerRequestIDPrefix + connectorIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: "+")
    }
}

/// Turns the credentials a run was not allowed to unseal into the marker the
/// broker projects alongside the ones it was.
enum BrokeredCredentialWithholdingProjection {
    /// Every credential the connectors *have* that `exposedCredentialLabels`
    /// does not cover.
    ///
    /// Derived by diffing against a full-exposure projection over the same
    /// connector set rather than by inspecting the restricted one, because the
    /// restricted projection is precisely the thing that has already forgotten:
    /// a withheld credential produces no binding at all, so by the time the
    /// environment exists its name is gone. Same connector set means the same
    /// aliases, so the env keys reported here are the ones the manifest would
    /// have carried had the credential been exposed.
    @MainActor
    static func manifest(
        connectors: [Connector],
        secretStore: SecretStore,
        exposedCredentialLabels: Set<String>
    ) -> BrokeredConnectorCredentialWithholdingManifest {
        let bindings = ConnectorRuntimeProjection(
            connectors: connectors,
            secretStore: secretStore,
            credentialExposurePolicy: .allowAllCredentials
        ).environmentBindings().filter { $0.kind == .credential }
        var credentialsByConnector: [UUID: [BrokeredConnectorCredentialWithholding.Credential]] = [:]
        var aliasesByConnector: [UUID: String] = [:]
        for binding in bindings {
            guard let label = binding.credentialLabel,
                  !exposedCredentialLabels.contains(label) else {
                continue
            }
            aliasesByConnector[binding.connectorID] = binding.alias
            credentialsByConnector[binding.connectorID, default: []].append(
                .init(
                    key: binding.originalKey,
                    envKey: binding.envKey,
                    logicalName: binding.logicalName
                )
            )
        }
        let withheld = connectors.compactMap { connector -> BrokeredConnectorCredentialWithholding? in
            guard let credentials = credentialsByConnector[connector.id], !credentials.isEmpty else {
                return nil
            }
            return BrokeredConnectorCredentialWithholding(
                connectorID: connector.id.uuidString,
                alias: aliasesByConnector[connector.id] ?? ConnectorRuntimeProjection.alias(for: connector),
                name: connector.name,
                serviceType: connector.serviceType,
                toolName: HostControlPlaneMCPProjection.connectorToolName(connector.serviceType) ?? "",
                credentials: credentials.sorted { $0.envKey < $1.envKey }
            )
        }
        return BrokeredConnectorCredentialWithholdingManifest(connectors: withheld)
    }
}

/// Where a withheld-credential tool call is parked between the broker thread
/// that saw it and the run boundary that can act on it.
///
/// The broker answers tool calls on a background queue, inside a lock that
/// serializes every other host-control call — so the handler may not touch
/// SwiftData, may not hop to the main actor and wait, and above all may not
/// block. It records a fact and returns. Everything that needs the app's state
/// happens later, on the main actor, from `BrokeredCredentialApprovalDiscovery`.
///
/// Deliberately not cleared when the broker session stops:
/// `AgentRuntimeProcessRunner` stops the session in a `defer` that runs before
/// the worker reaches the run boundary, so a ledger emptied on `stop` would
/// always be empty by the time anyone read it.
final class BrokeredCredentialApprovalLedger: @unchecked Sendable {
    static let shared = BrokeredCredentialApprovalLedger()

    /// Connectors tracked for one run. A brokered manifest is bounded by the
    /// user's enabled connectors, not by anything the agent controls, so this
    /// only has to be larger than a plausible workspace.
    static let maximumConnectorsPerRun = 16

    /// Runs kept before the oldest is evicted. A drain removes a run's entry,
    /// so this only accumulates for runs that ended without one — a crash, or a
    /// launch path that never reaches the worker's boundary.
    static let maximumTrackedRuns = 64

    private struct Key: Hashable {
        let taskID: UUID
        let runID: String
    }

    private let lock = NSLock()
    private var records: [Key: [UUID: BrokeredCredentialApprovalRecord]] = [:]
    private var insertionOrder: [Key] = []

    private init() {}

    func record(_ record: BrokeredCredentialApprovalRecord, taskID: UUID, runID: UUID?) {
        let key = Key(taskID: taskID, runID: runID?.uuidString ?? "run")
        lock.lock()
        defer { lock.unlock() }
        if records[key] == nil {
            records[key] = [:]
            insertionOrder.append(key)
            while insertionOrder.count > Self.maximumTrackedRuns {
                records.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        guard records[key]?[record.connectorID] != nil
            || (records[key]?.count ?? 0) < Self.maximumConnectorsPerRun else {
            return
        }
        records[key]?[record.connectorID] = record
    }

    /// Reads and clears in one step: the run boundary is the only consumer, and
    /// a record left behind would be re-offered by the next run of the same task.
    func drain(taskID: UUID, runID: UUID?) -> [BrokeredCredentialApprovalRecord] {
        let key = Key(taskID: taskID, runID: runID?.uuidString ?? "run")
        lock.lock()
        let drained = records.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
        lock.unlock()
        return (drained?.values).map { Array($0).sorted { $0.alias < $1.alias } } ?? []
    }
}

/// The broker-side end of the seam: one run's identity, bound to the ledger.
///
/// Holds identifiers and nothing else. The observer is called from the broker's
/// connection queue, and a SwiftData model captured here would be a model
/// touched off the main actor the moment anything read it.
final class BrokeredCredentialWithholdingRecorder: BrokeredCredentialWithholdingObserving {
    private let taskID: UUID
    private let runID: UUID?
    private let ledger: BrokeredCredentialApprovalLedger

    init(taskID: UUID, runID: UUID?, ledger: BrokeredCredentialApprovalLedger = .shared) {
        self.taskID = taskID
        self.runID = runID
        self.ledger = ledger
    }

    func brokeredConnectorInvokedWithWithheldCredentials(
        _ withholding: BrokeredConnectorCredentialWithholding
    ) {
        guard let connectorID = UUID(uuidString: withholding.connectorID) else { return }
        let labels = withholding.credentials.map {
            ConnectorRuntimeProjection.credentialLabel(connectorID: connectorID, key: $0.key)
        }
        guard !labels.isEmpty else { return }
        ledger.record(
            BrokeredCredentialApprovalRecord(
                connectorID: connectorID,
                connectorName: withholding.name,
                alias: withholding.alias,
                serviceType: withholding.serviceType,
                credentialLabels: labels.sorted()
            ),
            taskID: taskID,
            runID: runID
        )
    }
}

/// Turns "the agent reached for a connector it could not unseal" into something
/// the user can approve.
///
/// Raised here, at the run boundary, and never at launch. Preflight cannot ask
/// about a connector the turn did not name — a run about cake must not stop to
/// ask about Jira, and the offered tier is not allowed to fail, reroute or block
/// a launch. But the agent invoking the tool is a different event with a
/// different meaning: the run itself asked for the connector, which is the
/// narration preflight was waiting for and did not have. The request recorded
/// here changes no status, pauses nothing, and fails nothing; it is an offer
/// sitting in the dock next to the run that explains why it is there.
@MainActor
enum BrokeredCredentialApprovalDiscovery {
    @discardableResult
    static func recordWithheldCredentialRequests(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        policyLevel: AgentPolicyLevel = .review,
        ledger: BrokeredCredentialApprovalLedger = .shared
    ) -> [BrokeredCredentialApprovalRecord] {
        let drained = ledger.drain(taskID: task.id, runID: run.id)
        guard !drained.isEmpty else { return [] }
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: run.runtimeID,
            fallback: AgentRuntimeAdapterRegistry.registeredRuntime(
                rawValue: task.runtimeID,
                fallback: TaskExecutionDefaults.runtime
            )
        )
        let granted = Set(TaskRuntimePermissionGrants.approvedCredentialLabels(
            for: task,
            runtime: runtime
        ))
        let openOffers = openCredentialOffers(for: task)
        var recorded: [BrokeredCredentialApprovalRecord] = []
        for approval in drained {
            // A grant recorded after the launch read its labels — the user
            // approved mid-run, or an earlier run's request was approved — means
            // the next launch will unseal this connector on its own. Asking
            // again would be asking for something already given.
            guard !approval.credentialLabels.allSatisfy(granted.contains) else {
                continue
            }
            recorded.append(approval)
        }
        guard !recorded.isEmpty else { return [] }
        // Auto asks nothing: the run's own request is the consent, so the
        // connectors are allowed for the task and the chat says so. Offers an
        // earlier Ask run left open are that run's question and stay open.
        if !ExternalActionPolicy.asksUser(for: .connectorCredentialUse, level: policyLevel),
           grantForAuto(recorded, task: task, run: run, runtime: runtime, modelContext: modelContext) {
            return recorded
        }
        // One offer, never one per connector. The dock shows only the latest
        // open request and "Allow similar" grants exactly that one before
        // closing the rest, so a second offer in the store is a connector the
        // user approves without ever being shown — and it stays sealed. Anything
        // an earlier run left open therefore travels in this offer too.
        let currentConnectorIDs = Set(recorded.map(\.connectorID))
        let stillWaiting = records(stillWaitingIn: openOffers, excluding: granted, modelContext: modelContext)
            .filter { !currentConnectorIDs.contains($0.connectorID) }
        recordOpenRequest(
            covering: stillWaiting + recorded,
            includesEarlierRuns: !stillWaiting.isEmpty,
            replacing: openOffers.map(\.requestID),
            task: task,
            run: run,
            runtime: runtime,
            modelContext: modelContext
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: [
                "operation": "brokered_credential_approval_discovery",
                "count": String(recorded.count)
            ]
        )
        return recorded
    }

    private static func grantForAuto(
        _ approvals: [BrokeredCredentialApprovalRecord],
        task: AgentTask,
        run: TaskRun,
        runtime: AgentRuntimeID,
        modelContext: ModelContext
    ) -> Bool {
        let labels = approvals.flatMap(\.credentialLabels)
        let granted = TaskRuntimePermissionGrants.record(
            grants: labels.map { PermissionGrant.credential(label: $0) },
            providerID: runtime,
            task: task,
            modelContext: modelContext,
            source: "auto_policy"
        )
        AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: [
            "source": "brokered_credential_withheld",
            "runtime": runtime.rawValue,
            "connector_count": String(approvals.count),
            "credential_label_count": String(labels.count),
            "result": granted.isEmpty ? "auto_policy_grant_refused" : "auto_policy_granted"
        ], level: granted.isEmpty ? .warning : .info, fieldMaxLength: 240)
        guard !granted.isEmpty else { return false }
        let names = ConnectorRuntimeProjection.joinedNames(approvals.map(\.connectorName))
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: "Auto allowed \(names) to use \(approvals.count > 1 ? "their" : "its") saved credentials "
                + "for this task. The agent can use \(approvals.count > 1 ? "them" : "it") from the next message.",
            run: run
        ))
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "brokered_credential_auto_grant", "count": String(approvals.count)]
        )
        return true
    }

    /// Records one offer for every connector in `approvals` and retires the
    /// open offers it now stands for.
    private static func recordOpenRequest(
        covering approvals: [BrokeredCredentialApprovalRecord],
        includesEarlierRuns: Bool,
        replacing replacedRequestIDs: [String],
        task: AgentTask,
        run: TaskRun,
        runtime: AgentRuntimeID,
        modelContext: ModelContext
    ) {
        guard let offer = ConnectorRuntimeProjection.CredentialApprovalRequest.merged(approvals.map {
            .init(
                connectorID: $0.connectorID,
                connectorName: $0.connectorName,
                serviceType: $0.serviceType,
                labels: $0.credentialLabels
            )
        }) else { return }
        let connectorIDs = approvals.map(\.connectorID)
        let request = PermissionRequest.connectorCredentials(
            connectorID: offer.connectorID,
            displayName: offer.connectorName,
            labels: offer.labels
        )
        let payload = TaskPermissionContinuation.attach(PermissionBroker.approvalPayloadString(
            providerID: runtime,
            request: request,
            reason: offerReason(
                connectorNames: offer.connectorName,
                connectorCount: approvals.count,
                includesEarlierRuns: includesEarlierRuns
            ),
            providerDetail: offer.connectorName,
            grants: PermissionBroker.approvalGrants(for: request),
            requestID: BrokeredCredentialApprovalRecord.offerRequestID(forConnectors: connectorIDs),
            behavior: .futureUse
        ), continuation: TaskPermissionContinuation.capture(task: task, run: run, modelContext: modelContext), behavior: .futureUse)
        for requestID in replacedRequestIDs {
            TaskRuntimePermissionOpenRequestStore.resolveOpenRequest(requestID: requestID, task: task)
            if requestID != PermissionApprovalEventPayload.decoded(from: payload)?.requestID {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionRequestResolved,
                    payload: PermissionRequestResolution(requestID: requestID, approved: false,
                        toolName: "Replaced connector offer").payloadString, run: run))
            }
        }
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: payload,
            run: run
        ))
        AppLogger.audit(.connectorTested, category: "Worker", taskID: task.id, fields: [
            "source": "brokered_credential_withheld",
            "runtime": runtime.rawValue,
            "connector_id": offer.connectorID.uuidString,
            "connector_ids": connectorIDs.map(\.uuidString).joined(separator: ","),
            "connector_count": String(connectorIDs.count),
            "connector_alias": approvals.map(\.alias).joined(separator: ","),
            "service_type": Set(approvals.map(\.serviceType)).sorted().joined(separator: ","),
            "credential_label_count": String(offer.labels.count),
            "replaced_offer_count": String(replacedRequestIDs.count),
            "result": "approval_offered_non_blocking"
        ], level: .warning, fieldMaxLength: 240)
    }

    private static func offerReason(
        connectorNames: String,
        connectorCount: Int,
        includesEarlierRuns: Bool
    ) -> String {
        let unchanged = "The credentials are configured and unchanged — approving here lets ASTRA use them "
            + "without you re-entering anything."
        guard connectorCount > 1 else {
            return "The agent called \(connectorNames) during this run, but this turn's wording did not "
                + "mention it, so ASTRA kept its saved credentials sealed. " + unchanged
        }
        let when = includesEarlierRuns
            ? "in this task's recent runs, but those turns' wording did not"
            : "during this run, but this turn's wording did not"
        return "The agent called \(connectorNames) \(when) mention them, so ASTRA kept their saved "
            + "credentials sealed. " + unchanged
    }

    private struct OpenOffer {
        let requestID: String
        let labels: [String]
    }

    private static func openCredentialOffers(for task: AgentTask) -> [OpenOffer] {
        TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).compactMap { payload in
            guard let decoded = PermissionApprovalEventPayload.decoded(from: payload),
                  let requestID = decoded.requestID,
                  requestID.hasPrefix(BrokeredCredentialApprovalRecord.offerRequestIDPrefix),
                  case .connectorCredentials(_, _, let labels) = decoded.request else {
                return nil
            }
            return OpenOffer(requestID: requestID, labels: labels)
        }
    }

    /// The connectors earlier offers are still waiting on, rebuilt from their
    /// own rows so they can travel in the next offer. One granted since, or
    /// deleted, is left out: there is nothing left to ask about it.
    private static func records(
        stillWaitingIn offers: [OpenOffer],
        excluding granted: Set<String>,
        modelContext: ModelContext
    ) -> [BrokeredCredentialApprovalRecord] {
        let labelsByConnector = Dictionary(grouping: offers.flatMap(\.labels)) {
            ConnectorRuntimeProjection.connectorID(fromCredentialLabel: $0)
        }
        return labelsByConnector.compactMap { connectorID, labels in
            guard let connectorID,
                  !labels.allSatisfy(granted.contains),
                  let connector = connector(id: connectorID, modelContext: modelContext) else {
                return nil
            }
            return BrokeredCredentialApprovalRecord(
                connectorID: connectorID,
                connectorName: connector.name,
                alias: ConnectorRuntimeProjection.alias(for: connector),
                serviceType: connector.serviceType,
                credentialLabels: Array(Set(labels)).sorted()
            )
        }
    }

    private static func connector(id: UUID, modelContext: ModelContext) -> Connector? {
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
