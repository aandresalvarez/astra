import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

enum ConnectorMutationCoordinatorError: LocalizedError, Equatable {
    case noTaskFolder
    case staleProposal(String)
    case unreadableStagedPayload(String)
    case unsupportedOperation(serviceType: String, operation: String)
    case routeMismatch(staged: String, expected: String)
    case connectorNotFound(String)
    case connectorServiceMismatch(expected: String, found: String)
    case connectorChangedSinceReview(reviewed: String, now: String)
    case missingCredential(String)
    case invalidBaseURL(String)
    case requestFailed(statusCode: Int, message: String)
    case alreadySent(String)
    case sentButNotRecorded(target: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noTaskFolder:
            "ASTRA could not resolve this task's folder, so the staged payload cannot be read."
        case let .staleProposal(message):
            message
        case let .unreadableStagedPayload(message):
            "The staged payload could not be read: \(message)"
        case let .unsupportedOperation(serviceType, operation):
            "ASTRA does not know how to perform \(serviceType) \(operation), so it will not send it."
        case let .routeMismatch(staged, expected):
            "The staged request targets \(staged), but ASTRA sends \(operationDescription(expected)) "
                + "for this operation. Refusing to send."
        case let .connectorNotFound(id):
            "The connector this proposal was composed against (\(id)) no longer exists."
        case let .connectorServiceMismatch(expected, found):
            "The proposal names a \(expected) connector but that connector is now a \(found) connector."
        case let .connectorChangedSinceReview(reviewed, now):
            "This proposal was reviewed as a request to \(reviewed), but it would now go to \(now). "
                + "Refusing to send; reopen the review to approve the new destination."
        case let .missingCredential(alias):
            "The \(alias) connector has no usable credential in the Keychain, so ASTRA cannot send this."
        case let .invalidBaseURL(url):
            "The connector's base URL (\(url)) is not a valid http(s) URL."
        case let .requestFailed(statusCode, message):
            statusCode > 0
                ? "The connector rejected the request (HTTP \(statusCode)): \(message)"
                : "The request could not be completed: \(message)"
        case let .alreadySent(target):
            "ASTRA already sent this proposal to \(target). It will not be sent a second time."
        case let .sentButNotRecorded(target, reason):
            "ASTRA sent this to \(target) and the connector accepted it, but the receipt could not be "
                + "saved to this task (\(reason)). The change has been made — do not send it again."
        }
    }

    private func operationDescription(_ value: String) -> String { value }

    /// The provider status, when there was one. Zero means ASTRA never got a
    /// reply — a refusal before the request, or a transport failure.
    var statusCode: Int {
        if case let .requestFailed(statusCode, _) = self { return statusCode }
        return 0
    }

    /// Whether the write has already happened, so offering to retry would
    /// duplicate it. The review sheet reads this to decide whether the send
    /// button comes back.
    var isTerminal: Bool {
        switch self {
        case .alreadySent, .sentButNotRecorded: true
        default: false
        }
    }
}

/// What ASTRA actually sent, and what came back.
struct ConnectorMutationReceipt: Codable, Sendable, Equatable {
    let version: Int
    /// Which proposal this resolves. The path, not the digest — see
    /// `TaskStagedConnectorMutation.requestDigest` for why identical content is
    /// not the same proposal.
    let stagedPayloadPath: String
    let requestDigest: String
    let serviceType: String
    let operation: String
    let target: String
    /// Where it actually went, resolved from the connector rather than from the
    /// envelope, so the transcript records the host that received the write.
    let destinationURL: String
    let statusCode: Int
    /// Provider-assigned identifier, e.g. `STAR-12558`. Absent when the response
    /// did not name one.
    let createdKey: String?
    let createdURL: String?

    init(
        stagedPayloadPath: String,
        requestDigest: String,
        serviceType: String,
        operation: String,
        target: String,
        destinationURL: String,
        statusCode: Int,
        createdKey: String?,
        createdURL: String?
    ) {
        version = 2
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
        self.serviceType = serviceType
        self.operation = operation
        self.target = target
        self.destinationURL = destinationURL
        self.statusCode = statusCode
        self.createdKey = createdKey
        self.createdURL = createdURL
    }
}

/// Records that a send was attempted and did not succeed.
///
/// Not a resolution — `ConnectorMutationRequirementResolver` deliberately
/// ignores this type when deciding what is still pending, so a transient 503
/// leaves the proposal reviewable and re-sendable instead of silently
/// disappearing.
struct ConnectorMutationFailure: Codable, Sendable, Equatable {
    let version: Int
    let stagedPayloadPath: String
    let requestDigest: String
    let statusCode: Int
    let message: String

    init(stagedPayloadPath: String, requestDigest: String, statusCode: Int, message: String) {
        version = 2
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
        self.statusCode = statusCode
        self.message = message
    }
}

struct ConnectorMutationReviewField: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let isMonospaced: Bool
}

/// A staged mutation, read back and rendered for review.
///
/// Carries the pretty-printed request body verbatim as well as a field list.
/// The field list is the readable version and the body is the authority — an
/// approval that only ever showed a summary would be an approval of the
/// summary, and the summary is not what gets sent.
struct ConnectorMutationProposal: Equatable, Identifiable {
    let serviceType: String
    let operation: String
    let connectorID: String
    /// The resolved connector's own name, read from the `Connector` row that
    /// `connectorID` names — never the envelope's `connector_alias`.
    ///
    /// The envelope is agent-writable and only its `connector_id` decides where
    /// the credential goes. An alias copied straight out of it could therefore
    /// name a sandbox while the write went to production, and the user would
    /// have approved a sentence that was never true.
    let connectorAlias: String
    /// What the envelope claimed to be proposing against, kept so a discrepancy
    /// can be shown rather than silently corrected.
    let proposedConnectorAlias: String
    /// The absolute URL ASTRA would POST to, resolved from the connector's base
    /// URL. The one field that says which host receives the credential.
    let destinationURL: String
    let target: String
    let summary: String
    let requestMethod: String
    let requestPath: String
    let stagedPayloadPath: String
    let requestDigest: String
    let byteCount: Int
    /// Canonical bytes, exactly as staged. What gets sent.
    let requestBody: Data
    /// The same bytes, re-indented. What gets shown.
    let requestBodyText: String

    var id: String { stagedPayloadPath }

    /// Non-empty when what the agent said and what ASTRA resolved disagree.
    /// Surfaced, not suppressed: the disagreement is the interesting part.
    var warnings: [String] {
        guard proposedConnectorAlias.caseInsensitiveCompare(connectorAlias) != .orderedSame else {
            return []
        }
        return [
            "The agent labelled this proposal “\(proposedConnectorAlias)”, but the connector it names "
                + "is “\(connectorAlias)”. ASTRA will use “\(connectorAlias)” and send to the address below."
        ]
    }

    var fields: [ConnectorMutationReviewField] {
        [
            ConnectorMutationReviewField(id: "connector", label: "Connector", value: "\(connectorAlias) (\(serviceType))", isMonospaced: false),
            ConnectorMutationReviewField(id: "operation", label: "ASTRA will perform", value: operation, isMonospaced: true),
            ConnectorMutationReviewField(id: "endpoint", label: "ASTRA will send to", value: "\(requestMethod) \(destinationURL)", isMonospaced: true),
            ConnectorMutationReviewField(id: "target", label: "Destination", value: target, isMonospaced: false),
            ConnectorMutationReviewField(id: "summary", label: "Summary", value: summary, isMonospaced: false),
            ConnectorMutationReviewField(id: "staged-path", label: "Staged file", value: stagedPayloadPath, isMonospaced: true),
            ConnectorMutationReviewField(id: "digest", label: "Payload digest", value: requestDigest, isMonospaced: true)
        ]
    }
}

/// Owns the app's side of a staged connector mutation: reading it back for
/// review, and recording the user's decision.
///
/// The agent proposed; this is where the user disposes. Sending itself is the
/// next piece of work — until it lands, approving is deliberately not offered,
/// because a button that claims to send and does not is worse than no button.
@MainActor
final class ConnectorMutationCoordinator {
    typealias DurableEventSave = @MainActor (
        _ workspace: Workspace?,
        _ modelContext: ModelContext,
        _ taskID: UUID,
        _ auditFields: [String: String]
    ) throws -> Void

    private let modelContext: ModelContext
    private let sender: any ConnectorMutationSending
    private let secretStore: SecretStore
    private let durableEventSave: DurableEventSave

    init(
        modelContext: ModelContext,
        sender: any ConnectorMutationSending = URLSessionConnectorMutationSender(),
        secretStore: SecretStore = SecretStoreSeam.required,
        durableEventSave: @escaping DurableEventSave = { workspace, modelContext, taskID, auditFields in
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace,
                modelContext: modelContext,
                taskID: taskID,
                auditFields: auditFields
            )
        }
    ) {
        self.modelContext = modelContext
        self.sender = sender
        self.secretStore = secretStore
        self.durableEventSave = durableEventSave
    }

    /// Re-reads the staged payload, refuses if it is not byte-identical to what
    /// was recorded, and resolves the connector it names.
    ///
    /// Verified at review time as well as at send time, and for a different
    /// reason. Verifying at send stops a payload swapped after approval;
    /// verifying here stops the user approving bytes that already changed. Both
    /// have to hold, or "the user read it" stops meaning anything.
    func prepare(
        task: AgentTask,
        pending: TaskStagedConnectorMutation
    ) throws -> ConnectorMutationProposal {
        let staged = try readStaged(
            task: task,
            path: pending.stagedPayloadPath,
            digest: pending.requestDigest
        )
        // Refused before it is ever shown. A proposal whose write already went
        // out has nothing left to approve, and re-rendering it as pending is
        // how a second identical POST gets a plausible-looking click.
        guard !Self.hasBeenSent(stagedPath: staged.path) else {
            throw ConnectorMutationCoordinatorError.alreadySent(staged.target)
        }
        return try resolveProposal(staged)
    }

    private func readStaged(
        task: AgentTask,
        path: String,
        digest: String
    ) throws -> ConnectorMutationStaging.StagedConnectorMutation {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else {
            throw ConnectorMutationCoordinatorError.noTaskFolder
        }
        do {
            return try ConnectorMutationStaging.read(
                atPath: path,
                containedIn: taskFolder,
                expectedDigest: digest
            )
        } catch let error as ConnectorMutationStagingError {
            throw ConnectorMutationCoordinatorError.staleProposal(error.message)
        } catch {
            throw ConnectorMutationCoordinatorError.unreadableStagedPayload(error.localizedDescription)
        }
    }

    /// Turns a staged envelope into the thing the user is asked to approve, by
    /// resolving every claim in it that ASTRA does not have to take on trust.
    ///
    /// The route, the connector, and the destination URL are all derived here
    /// rather than at send time, so the sheet shows what will actually happen
    /// and a proposal ASTRA would refuse is refused before it is displayed —
    /// not after the user has approved it.
    private func resolveProposal(
        _ staged: ConnectorMutationStaging.StagedConnectorMutation
    ) throws -> ConnectorMutationProposal {
        guard let definition = ConnectorMutationOperations.definition(
            serviceType: staged.serviceType,
            operation: staged.operation
        ) else {
            throw ConnectorMutationCoordinatorError.unsupportedOperation(
                serviceType: staged.serviceType,
                operation: staged.operation
            )
        }
        // The envelope declared a route; this is where it has to agree with the
        // one ASTRA derived. A rewritten path cannot redirect the credential.
        let stagedRoute = "\(staged.requestMethod.uppercased()) \(staged.requestPath)"
        let expectedRoute = "\(definition.method) \(definition.path)"
        guard stagedRoute == expectedRoute else {
            throw ConnectorMutationCoordinatorError.routeMismatch(staged: stagedRoute, expected: expectedRoute)
        }

        let connector = try resolveConnector(staged)
        guard let url = Self.url(baseURL: connector.baseURL, path: definition.path) else {
            throw ConnectorMutationCoordinatorError.invalidBaseURL(connector.baseURL)
        }
        return ConnectorMutationProposal(
            serviceType: staged.serviceType,
            operation: staged.operation,
            connectorID: staged.connectorID,
            connectorAlias: connector.name,
            proposedConnectorAlias: staged.connectorAlias,
            destinationURL: url.absoluteString,
            target: staged.target,
            summary: staged.summary,
            requestMethod: definition.method,
            requestPath: definition.path,
            stagedPayloadPath: staged.path,
            requestDigest: staged.digest,
            byteCount: staged.byteCount,
            requestBody: staged.requestBody,
            requestBodyText: Self.readableJSON(staged.requestBody)
        )
    }

    /// Performs the mutation the user approved, using the connector credential
    /// the agent never held.
    ///
    /// Re-reads and re-verifies rather than sending `proposal`'s in-memory copy.
    /// The sheet may have been open for minutes and the staging directory is
    /// agent-writable, so the bytes that go out have to be proven to be the
    /// bytes that were read — anything else makes the review advisory.
    @discardableResult
    func send(task: AgentTask, proposal: ConnectorMutationProposal) async throws -> ConnectorMutationReceipt {
        guard !Self.hasBeenSent(stagedPath: proposal.stagedPayloadPath) else {
            throw ConnectorMutationCoordinatorError.alreadySent(proposal.target)
        }
        let staged = try readStaged(
            task: task,
            path: proposal.stagedPayloadPath,
            digest: proposal.requestDigest
        )

        let request: ConnectorMutationHTTPRequest
        let current: ConnectorMutationProposal
        let response: ConnectorMutationHTTPResponse
        do {
            current = try resolveProposal(staged)
            // The connector is resolved twice — once for the sheet, once here —
            // so the approval covers a destination and not just a payload. A
            // connector edited, re-pointed, or swapped while the sheet was open
            // makes this a different request than the one that was read.
            guard current.destinationURL == proposal.destinationURL,
                  current.connectorID == proposal.connectorID else {
                throw ConnectorMutationCoordinatorError.connectorChangedSinceReview(
                    reviewed: "\(proposal.connectorAlias) (\(proposal.destinationURL))",
                    now: "\(current.connectorAlias) (\(current.destinationURL))"
                )
            }
            request = try buildRequest(current)
            response = try await sender.send(request)
            guard (200...299).contains(response.statusCode) else {
                throw ConnectorMutationCoordinatorError.requestFailed(
                    statusCode: response.statusCode,
                    message: Self.providerMessage(response.body)
                )
            }
        } catch {
            // Recorded, then rethrown. The sheet shows the error and the row
            // stays pending; the event is so the transcript says an attempt was
            // made, which is what stops a retry looking like a first try.
            //
            // Only reachable before the request was accepted. Everything past
            // this block has already changed the provider's state, and calling
            // that a failure is what would invite the duplicate.
            try? record(
                ConnectorMutationFailure(
                    stagedPayloadPath: staged.path,
                    requestDigest: staged.digest,
                    statusCode: (error as? ConnectorMutationCoordinatorError)?.statusCode ?? 0,
                    message: error.localizedDescription
                ),
                type: ConnectorMutationEventTypes.failed,
                task: task,
                stagedPath: staged.path,
                operation: "connector_mutation_failed"
            )
            throw error
        }

        // The write has happened. From here the only question is how well ASTRA
        // can describe it — never whether to try again.
        Self.markSent(stagedPath: staged.path)
        let receipt = Self.receipt(for: current, response: response, baseURL: request.url)
        do {
            try record(
                receipt,
                type: ConnectorMutationEventTypes.receipt,
                task: task,
                stagedPath: staged.path,
                operation: "connector_mutation_sent"
            )
        } catch {
            // A save failure here used to fall into the catch above, record a
            // *failure*, leave the proposal pending, and re-enable the send
            // button — so an unwritable store turned one approved ticket into
            // two real ones. The receipt is lost, which is bad; a duplicate
            // write is worse and is the one that cannot be undone.
            AuditLoggingSeam.required.audit(
                .dataStoreRecovered,
                category: "Tasks",
                fields: [
                    "operation": "connector_mutation_sent_unrecorded",
                    "service_type": receipt.serviceType,
                    "connector_operation": receipt.operation,
                    "status_code": String(receipt.statusCode),
                    "created_key": receipt.createdKey ?? "",
                    "error": error.localizedDescription
                ],
                level: .error
            )
            throw ConnectorMutationCoordinatorError.sentButNotRecorded(
                target: receipt.createdKey ?? receipt.target,
                reason: error.localizedDescription
            )
        }
        return receipt
    }

    private func buildRequest(_ proposal: ConnectorMutationProposal) throws -> ConnectorMutationHTTPRequest {
        let connector = try resolveConnector(proposal)
        guard let url = URL(string: proposal.destinationURL) else {
            throw ConnectorMutationCoordinatorError.invalidBaseURL(connector.baseURL)
        }
        return ConnectorMutationHTTPRequest(
            url: url,
            method: proposal.requestMethod,
            body: proposal.requestBody,
            authorizationHeader: try authorizationHeader(for: connector, alias: proposal.connectorAlias)
        )
    }

    /// Resolves the connector by the UUID recorded in the envelope.
    ///
    /// The envelope is agent-writable, so this deliberately re-checks the
    /// service type: without it, a rewritten `connector_id` could point the
    /// approved Jira payload at whichever connector holds the most useful
    /// credential. What the user saw named this connector; what is sent must
    /// use it.
    private func resolveConnector(connectorID: String, serviceType: String) throws -> Connector {
        guard let id = UUID(uuidString: connectorID) else {
            throw ConnectorMutationCoordinatorError.connectorNotFound(connectorID)
        }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        guard let connector = try? modelContext.fetch(descriptor).first else {
            throw ConnectorMutationCoordinatorError.connectorNotFound(connectorID)
        }
        let found = connector.serviceType.lowercased()
        guard found == serviceType.lowercased() else {
            throw ConnectorMutationCoordinatorError.connectorServiceMismatch(
                expected: serviceType,
                found: found
            )
        }
        return connector
    }

    private func resolveConnector(
        _ staged: ConnectorMutationStaging.StagedConnectorMutation
    ) throws -> Connector {
        try resolveConnector(connectorID: staged.connectorID, serviceType: staged.serviceType)
    }

    private func resolveConnector(_ proposal: ConnectorMutationProposal) throws -> Connector {
        try resolveConnector(connectorID: proposal.connectorID, serviceType: proposal.serviceType)
    }

    /// Reads the credential out of the Keychain and turns it into a header.
    ///
    /// Service-typed rather than generic: an auth scheme guessed from
    /// `authMethod` would be a scheme no one reviewed. A service without an
    /// entry here cannot be committed, which is the same default-deny the read
    /// gates use.
    private func authorizationHeader(for connector: Connector, alias: String) throws -> String {
        let credentials = connector.credentials(store: secretStore)
        func value(_ names: [String]) -> String? {
            for name in names {
                let match = credentials.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
                if let match, !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return match
                }
            }
            return nil
        }
        switch connector.serviceType.lowercased() {
        case "jira":
            guard let email = value(["JIRA_EMAIL", "EMAIL"]),
                  let token = value(["JIRA_API_TOKEN", "API_TOKEN", "TOKEN"]) else {
                throw ConnectorMutationCoordinatorError.missingCredential(alias)
            }
            return "Basic \(Data("\(email):\(token)".utf8).base64EncodedString())"
        default:
            throw ConnectorMutationCoordinatorError.unsupportedOperation(
                serviceType: connector.serviceType,
                operation: "authentication"
            )
        }
    }

    private static func url(baseURL: String, path: String) -> URL? {
        guard var url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    private static func receipt(
        for proposal: ConnectorMutationProposal,
        response: ConnectorMutationHTTPResponse,
        baseURL: URL
    ) -> ConnectorMutationReceipt {
        let object = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any]
        let key = (object?["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let browseURL = key.flatMap { key -> String? in
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/browse/\(key)"
            components?.query = nil
            return components?.url?.absoluteString
        }
        return ConnectorMutationReceipt(
            stagedPayloadPath: proposal.stagedPayloadPath,
            requestDigest: proposal.requestDigest,
            serviceType: proposal.serviceType,
            operation: proposal.operation,
            target: proposal.target,
            destinationURL: proposal.destinationURL,
            statusCode: response.statusCode,
            createdKey: key,
            createdURL: browseURL ?? (object?["self"] as? String)
        )
    }

    /// Trims a provider error body to something a person can read in a sheet.
    private static func providerMessage(_ body: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            if let messages = object["errorMessages"] as? [String], !messages.isEmpty {
                return messages.joined(separator: " ")
            }
            if let errors = object["errors"] as? [String: Any], !errors.isEmpty {
                return errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " ")
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no response body" : String(trimmed.prefix(500))
    }

    private func record<T: Encodable>(
        _ payload: T,
        type: String,
        task: AgentTask,
        stagedPath: String,
        operation: String
    ) throws {
        let previousUpdatedAt = task.updatedAt
        let event = TaskEvent.structuredPayloadEvent(
            task: task,
            type: type,
            payload: payload,
            run: run(for: task, stagedPath: stagedPath)
        )
        modelContext.insert(event)
        do {
            try durableEventSave(task.workspace, modelContext, task.id, ["operation": operation])
        } catch {
            task.events.removeAll { $0.id == event.id }
            modelContext.delete(event)
            task.updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// Retires a proposal without sending it.
    ///
    /// The staged file is left on disk on purpose. Declining says "not this",
    /// not "destroy the evidence" — the user may want to read what the agent
    /// composed, and `recordedStagedPaths` already stops a declined proposal
    /// reappearing on the next scan. Re-proposing the same ticket afterwards is
    /// a new file and therefore a new review, which is the point: the user said
    /// no to that request, not to the sentence it contained.
    func decline(task: AgentTask, proposal: ConnectorMutationProposal) throws {
        try record(
            ConnectorMutationDecision(
                stagedPayloadPath: proposal.stagedPayloadPath,
                requestDigest: proposal.requestDigest
            ),
            type: ConnectorMutationEventTypes.declined,
            task: task,
            stagedPath: proposal.stagedPayloadPath,
            operation: "connector_mutation_declined"
        )
    }

    private func run(for task: AgentTask, stagedPath: String) -> TaskRun? {
        guard let runID = ConnectorMutationRequirementResolver
            .pendingMutations(task: task)
            .first(where: { $0.stagedPayloadPath == stagedPath })?
            .runID else {
            return nil
        }
        return task.runs.first { $0.id == runID }
    }

    // MARK: - Send-once

    /// Staged files whose write this process has already performed.
    ///
    /// A coordinator is constructed per action, so the guard has to outlive the
    /// instance. It is checked before the sheet opens and again before the
    /// request goes out.
    private static var sentStagedPaths: Set<String> = []

    /// Extension marking a staged proposal as already sent.
    ///
    /// The in-memory set does not survive a relaunch, and the case it exists for
    /// — a receipt that could not be saved — is exactly the case where the
    /// durable record is missing, so a restart would otherwise offer the write
    /// again. This marker is written to the same directory the envelope came
    /// from, which is agent-writable: an agent could delete it, but deleting it
    /// only re-exposes its *own* proposal for a second review by the user, so it
    /// buys an agent nothing it could not get by staging a second proposal.
    private static let sentMarkerExtension = "sent"

    private static func sentMarkerPath(stagedPath: String) -> String {
        stagedPath + "." + sentMarkerExtension
    }

    static func hasBeenSent(stagedPath: String, fileManager: FileManager = .default) -> Bool {
        sentStagedPaths.contains(stagedPath)
            || fileManager.fileExists(atPath: sentMarkerPath(stagedPath: stagedPath))
    }

    private static func markSent(stagedPath: String) {
        sentStagedPaths.insert(stagedPath)
        // Best effort by construction: if the disk is unwritable the in-memory
        // set still covers this launch, and there is nothing better available.
        try? Data("sent\n".utf8).write(
            to: URL(fileURLWithPath: sentMarkerPath(stagedPath: stagedPath)),
            options: .atomic
        )
    }

    /// Test seam. Production never forgets a send.
    static func resetSentStagedPathsForTesting() {
        sentStagedPaths.removeAll()
    }

    /// Re-indented for reading. Falls back to the exact bytes rather than an
    /// apology: an unreadable body still has to be visible, because it is still
    /// what would be sent.
    private static func readableJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "<unreadable payload>"
        }
        return text
    }
}

struct ConnectorMutationDecision: Codable, Sendable, Equatable {
    let version: Int
    let stagedPayloadPath: String
    let requestDigest: String

    init(stagedPayloadPath: String, requestDigest: String) {
        version = 2
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
    }
}
