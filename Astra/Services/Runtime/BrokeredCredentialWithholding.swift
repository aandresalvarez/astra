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
        "connector-credentials-\(connectorID.uuidString.lowercased())"
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
        let alreadyOpen = openConnectorCredentialRequestIDs(for: task)
        var recorded: [BrokeredCredentialApprovalRecord] = []
        for approval in drained {
            // A grant recorded after the launch read its labels — the user
            // approved mid-run, or an earlier run's request was approved — means
            // the next launch will unseal this connector on its own. Asking
            // again would be asking for something already given.
            guard !approval.credentialLabels.allSatisfy(granted.contains),
                  !alreadyOpen.contains(approval.requestID) else {
                continue
            }
            recordOpenRequest(
                approval,
                task: task,
                run: run,
                runtime: runtime,
                modelContext: modelContext
            )
            recorded.append(approval)
        }
        guard !recorded.isEmpty else { return [] }
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

    private static func recordOpenRequest(
        _ approval: BrokeredCredentialApprovalRecord,
        task: AgentTask,
        run: TaskRun,
        runtime: AgentRuntimeID,
        modelContext: ModelContext
    ) {
        let request = PermissionRequest.connectorCredentials(
            connectorID: approval.connectorID,
            displayName: approval.connectorName,
            labels: approval.credentialLabels
        )
        let payload = PermissionBroker.approvalPayloadString(
            providerID: runtime,
            request: request,
            reason: "The agent called \(approval.connectorName) during this run, but this turn's wording did not "
                + "mention it, so ASTRA kept its saved credentials sealed. The credentials are configured and "
                + "unchanged — approving here lets ASTRA use them without you re-entering anything.",
            providerDetail: approval.connectorName,
            grants: PermissionBroker.approvalGrants(for: request),
            requestID: approval.requestID
        )
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
            "connector_id": approval.connectorID.uuidString,
            "connector_alias": approval.alias,
            "service_type": approval.serviceType,
            "credential_label_count": String(approval.credentialLabels.count),
            "result": "approval_offered_non_blocking"
        ], level: .warning, fieldMaxLength: 240)
    }

    private static func openConnectorCredentialRequestIDs(for task: AgentTask) -> Set<String> {
        Set(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task).compactMap {
            PermissionApprovalEventPayload.decoded(from: $0)?.requestID
        })
    }
}
