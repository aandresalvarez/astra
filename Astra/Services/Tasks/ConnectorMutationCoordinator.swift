import Darwin
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
    case insecureTransport(alias: String, url: String)
    case requestFailed(statusCode: Int, message: String)
    case alreadySent(String)
    case sendNotReserved(reason: String)
    case dispatchedWithoutConfirmation(target: String, reason: String)
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
        case let .insecureTransport(alias, url):
            "The \(alias) connector points at \(url), which would send its credential over "
                + "unprotected HTTP. Refusing to send; set an HTTPS base URL in Connectors."
        case let .requestFailed(statusCode, message):
            statusCode > 0
                ? "The connector rejected the request (HTTP \(statusCode)): \(message)"
                : "The request could not be completed: \(message)"
        case let .alreadySent(target):
            "ASTRA already sent this proposal to \(target). It will not be sent a second time."
        case let .sendNotReserved(reason):
            "ASTRA could not durably record that it was about to send this, so it did not send it "
                + "(\(reason)). Nothing has been sent. Free some disk space or fix permissions on the "
                + "task folder, then try again."
        case let .dispatchedWithoutConfirmation(target, reason):
            "ASTRA sent this to \(target) but never got an answer it could trust (\(reason)). The "
                + "change may or may not have been made — check \(target) before proposing it again. "
                + "ASTRA will not send it a second time."
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

    /// Whether the write may already have happened, so offering to retry could
    /// duplicate it. The review sheet reads this to decide whether the send
    /// button comes back.
    ///
    /// "May" is doing the work. `dispatchedWithoutConfirmation` is terminal even
    /// though ASTRA does not know that anything was written: a dropped
    /// connection after a `POST` is indistinguishable from a slow success, and
    /// between showing a second Send button and not showing one, only one of
    /// those two mistakes files a duplicate ticket in someone's tracker. The
    /// user is told to go and look, which is the only honest instruction
    /// available.
    var isTerminal: Bool {
        switch self {
        case .alreadySent, .dispatchedWithoutConfirmation, .sentButNotRecorded: true
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

/// The record that ASTRA dispatched a write and never learned the outcome.
///
/// Deliberately not a `ConnectorMutationFailure` with a different event type.
/// The two say opposite things to whoever reads the transcript next — a failure
/// means the tracker is unchanged, this means it might not be — and the
/// resolver retires them differently. Sharing a payload would have made that
/// difference a string comparison on the event type, which is exactly how the
/// distinction gets lost.
struct ConnectorMutationIndeterminateOutcome: Codable, Sendable, Equatable {
    let version: Int
    let stagedPayloadPath: String
    let requestDigest: String
    let serviceType: String
    let operation: String
    let target: String
    /// The host that received the dispatch, so the person checking knows where
    /// to look.
    let destinationURL: String
    /// The provider status, when one arrived. Zero means the reply never did.
    let statusCode: Int
    let message: String

    init(
        stagedPayloadPath: String,
        requestDigest: String,
        serviceType: String,
        operation: String,
        target: String,
        destinationURL: String,
        statusCode: Int,
        message: String
    ) {
        version = 1
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
        self.serviceType = serviceType
        self.operation = operation
        self.target = target
        self.destinationURL = destinationURL
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
        try Self.requireProtectedTransport(connector)
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

        // Three phases, and the boundaries between them are the whole design.
        //
        //   1. Refuse, freely. Nothing is reserved and nothing has been sent, so
        //      any error here leaves the proposal exactly as reviewable as it
        //      was.
        //   2. Reserve, durably. After this line ASTRA has promised not to send
        //      this proposal twice, and that promise survives a crash.
        //   3. Dispatch. After this line the provider may have committed the
        //      write, so no outcome may re-enable the send button.
        //
        // The reservation used to sit *after* the response, best-effort. That
        // ordering could only ever lose: the case the marker exists for is the
        // one where the durable record failed, and a `try?` write in the same
        // unwritable folder fails the same way. Reserving first means the worst
        // case is a proposal that was never sent, instead of a write that
        // happened and left no trace.
        let request: ConnectorMutationHTTPRequest
        let current: ConnectorMutationProposal
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
            try Self.reserveSend(stagedPath: staged.path, target: proposal.target)
        } catch {
            // Recorded, then rethrown. The sheet shows the error and the row
            // stays pending; the event is so the transcript says an attempt was
            // made, which is what stops a retry looking like a first try.
            //
            // Only reachable before anything was dispatched. Everything past
            // this block may already have changed the provider's state, and
            // calling that a failure is what would invite the duplicate.
            recordFailure(task: task, staged: staged, error: error)
            throw error
        }

        let response: ConnectorMutationHTTPResponse
        do {
            response = try await sender.send(request)
        } catch {
            // The request went out. Whether Jira filed the ticket before the
            // socket died is not knowable from here, and a timeout is the same
            // ambiguity wearing a different error. Quarantine rather than
            // retry: this used to fall into the catch above and re-arm Send.
            throw indeterminate(
                task: task,
                staged: staged,
                proposal: current,
                url: request.url,
                statusCode: 0,
                message: ConnectorMutationSecretRedaction.redacted(
                    error.localizedDescription,
                    authorizationHeader: request.authorizationHeader
                )
            )
        }

        if !(200...299).contains(response.statusCode) {
            // Scrubbed before it is looked at, never after. Everything below
            // either persists this string in a task event or writes it to the
            // audit log, and the connector credential is broker-held —
            // deliberately outside the run redaction scope — so the persistence
            // funnel cannot catch it on the way past. A provider or proxy that
            // reflects the submitted `Authorization` value would otherwise put
            // the credential in the store in cleartext.
            let message = ConnectorMutationSecretRedaction.redacted(
                Self.providerMessage(response.body),
                authorizationHeader: request.authorizationHeader
            )
            guard Self.isDefiniteRefusal(response.statusCode) else {
                // Anything that is neither success nor a definite client
                // refusal is ambiguous by nature. A `503` is usually the gateway
                // in front of Jira, and a gateway can time out on a request Jira
                // has already committed; a `3xx` ASTRA refused to follow says
                // even less.
                throw indeterminate(
                    task: task,
                    staged: staged,
                    proposal: current,
                    url: request.url,
                    statusCode: response.statusCode,
                    message: message
                )
            }
            // A definite refusal, so the reservation is given back and the
            // proposal stays sendable — the user can fix the field the provider
            // objected to and approve it again.
            Self.releaseSendReservation(stagedPath: staged.path)
            let error = ConnectorMutationCoordinatorError.requestFailed(
                statusCode: response.statusCode,
                message: message
            )
            recordFailure(task: task, staged: staged, error: error)
            throw error
        }

        // The write has happened. From here the only question is how well ASTRA
        // can describe it — never whether to try again.
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
        // Checked again here, immediately before the credential is turned into
        // a header, because this is the line that decides whether it goes on
        // the wire. `resolveProposal` has already refused an unprotected
        // connector at review and at re-resolution, so reaching this is not
        // expected — which is exactly why it is worth stating: the gate must
        // hold even if a future caller builds a request by another route.
        try Self.requireProtectedTransport(connector)
        return ConnectorMutationHTTPRequest(
            url: url,
            method: proposal.requestMethod,
            body: proposal.requestBody,
            authorizationHeader: try authorizationHeader(for: connector, alias: proposal.connectorAlias)
        )
    }

    /// Refuses to put a credential on unprotected transport.
    ///
    /// Every other path that hands a connector credential to something —
    /// install, import, share, workspace config — runs
    /// `credentialTransportViolation` first, and the write path had grown up
    /// without it. A base URL is user-editable after the connector is created,
    /// so an `https://` connector that the agent composed a proposal against
    /// can be `http://` by the time it is approved, and the request built from
    /// it still carried `Authorization: Basic …` in the clear to whatever host
    /// the new URL named. The route check upstream constrains the *path*; only
    /// this constrains the scheme and the host.
    ///
    /// Loopback HTTP stays allowed, matching every other caller: a connector
    /// pointed at `127.0.0.1` is a local test instance, and the credential
    /// never leaves the machine.
    private static func requireProtectedTransport(_ connector: Connector) throws {
        guard ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: connector.credentialKeys
        ) != nil else { return }
        throw ConnectorMutationCoordinatorError.insecureTransport(
            alias: connector.name,
            url: connector.baseURL
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
    /// Whether this status is the provider stating, on the record, that it did
    /// not act — the only thing that may re-arm Send.
    ///
    /// Nearly all of `4xx` qualifies: a `400` is a malformed field, a `403` is
    /// permission, a `404` is a project that does not exist, and none of them
    /// leave a ticket behind. The timeout-shaped ones do not qualify, because
    /// they are reported by whatever gave up waiting rather than by the service
    /// that would have done the work:
    ///
    /// - `408` is a gateway saying the exchange took too long. It may have
    ///   forwarded the `POST` to Jira first, and Jira may have completed it.
    /// - `425` says the request may have been replayed, which is the same
    ///   ambiguity stated from the other side.
    ///
    /// Retrying either is how the duplicate the indeterminate path exists to
    /// prevent gets created anyway.
    static func isDefiniteRefusal(_ statusCode: Int) -> Bool {
        guard (400...499).contains(statusCode) else { return false }
        return statusCode != 408 && statusCode != 425
    }

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

    /// Records an attempt that did not change anything, so the transcript shows
    /// a retry is a retry.
    ///
    /// `try?` on purpose: the caller is already throwing something the user
    /// needs to see, and losing the audit line is a worse outcome to swap it
    /// for. Nothing was sent, so nothing is at stake if it does not save.
    private func recordFailure(
        task: AgentTask,
        staged: ConnectorMutationStaging.StagedConnectorMutation,
        error: Error
    ) {
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
    }

    /// Quarantines a dispatch whose outcome ASTRA cannot determine, and returns
    /// the error to throw.
    ///
    /// Returns rather than throws so its call sites read `throw
    /// indeterminate(...)` — one statement, with no way to record the quarantine
    /// and then keep going into the success path.
    ///
    /// The reservation is deliberately *not* released. It is the only thing
    /// standing between an ambiguous outcome and a duplicate write after a
    /// relaunch, and it costs nothing but a file the user can delete.
    private func indeterminate(
        task: AgentTask,
        staged: ConnectorMutationStaging.StagedConnectorMutation,
        proposal: ConnectorMutationProposal,
        url: URL,
        statusCode: Int,
        message: String
    ) -> ConnectorMutationCoordinatorError {
        try? record(
            ConnectorMutationIndeterminateOutcome(
                stagedPayloadPath: staged.path,
                requestDigest: staged.digest,
                serviceType: proposal.serviceType,
                operation: proposal.operation,
                target: proposal.target,
                destinationURL: proposal.destinationURL,
                statusCode: statusCode,
                message: message
            ),
            type: ConnectorMutationEventTypes.indeterminate,
            task: task,
            stagedPath: staged.path,
            operation: "connector_mutation_indeterminate"
        )
        // Logged as well as recorded. The task event retires the row; this is
        // what someone reading the audit log after a support report sees, and
        // "may have been written" is the sentence they need.
        AuditLoggingSeam.required.audit(
            .dataStoreRecovered,
            category: "Tasks",
            fields: [
                "operation": "connector_mutation_indeterminate",
                "service_type": proposal.serviceType,
                "connector_operation": proposal.operation,
                "destination_url": url.absoluteString,
                "status_code": String(statusCode),
                "error": message
            ],
            level: .error
        )
        return .dispatchedWithoutConfirmation(target: proposal.target, reason: message)
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

    /// Retires a proposal that could not be opened for review.
    ///
    /// Without this the dock had a state it could not leave. `prepare` fails on
    /// a staged file that is missing, edited, or already claimed by a send whose
    /// outcome was never recorded, and it recorded nothing — so the pending
    /// event survived, the dock offered the same broken review again on the next
    /// pass, and because a connector-mutation row outranks corrections and
    /// advisories it sat on top of the rows the user could still act on. An
    /// alert with only "OK" is not an exit.
    ///
    /// Takes the pending record rather than a `ConnectorMutationProposal`,
    /// because the reason this is being called is that no proposal could be
    /// built. The digest recorded is the one the proposal was staged with, which
    /// is what makes the event line up with the `staged` event it retires — not
    /// a digest of whatever is on disk now, which may be exactly the thing that
    /// went wrong.
    ///
    /// The staged file is left alone, like `decline`. ASTRA could not read it,
    /// so deleting it would destroy the evidence for a report that ASTRA lost a
    /// proposal.
    func quarantine(
        task: AgentTask,
        pending: TaskStagedConnectorMutation,
        reason: String
    ) throws {
        try record(
            ConnectorMutationQuarantine(
                stagedPayloadPath: pending.stagedPayloadPath,
                requestDigest: pending.requestDigest,
                serviceType: pending.serviceType,
                operation: pending.operation,
                target: pending.target,
                reason: reason
            ),
            type: ConnectorMutationEventTypes.quarantined,
            task: task,
            stagedPath: pending.stagedPayloadPath,
            operation: "connector_mutation_quarantined"
        )
        AuditLoggingSeam.required.audit(
            .dataStoreRecovered,
            category: "Tasks",
            fields: [
                "operation": "connector_mutation_quarantined",
                "service_type": pending.serviceType,
                "connector_operation": pending.operation,
                "target": pending.target,
                "reason": reason
            ],
            level: .warning
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

    /// Extension marking a staged proposal as claimed for sending.
    ///
    /// The in-memory set does not survive a relaunch, and the cases it exists
    /// for — a receipt that could not be saved, a dispatch with no answer — are
    /// exactly the cases where the durable record is missing, so a restart would
    /// otherwise offer the write again. This marker is written to the same
    /// directory the envelope came from, which is agent-writable: an agent could
    /// delete it, but deleting it only re-exposes its *own* proposal for a
    /// second review by the user, so it buys an agent nothing it could not get
    /// by staging a second proposal.
    private static let sentMarkerExtension = "sent"

    private static func sentMarkerPath(stagedPath: String) -> String {
        stagedPath + "." + sentMarkerExtension
    }

    static func hasBeenSent(stagedPath: String, fileManager: FileManager = .default) -> Bool {
        sentStagedPaths.contains(stagedPath)
            || fileManager.fileExists(atPath: sentMarkerPath(stagedPath: stagedPath))
    }

    /// Claims the send on disk, before it happens, and refuses to proceed if the
    /// claim cannot be made durable.
    ///
    /// The order is the fix. The marker used to be written after the provider
    /// accepted, wrapped in `try?`, which meant the one situation it was built
    /// for — an unwritable task folder losing the receipt — was also the
    /// situation in which the marker silently failed to appear. Restart, and the
    /// still-pending event offered the same proposal for a second POST.
    ///
    /// Claiming first inverts which way the uncertainty falls. If the claim
    /// fails, nothing is dispatched and the proposal is untouched; the user sees
    /// a plain "not sent, fix the disk" and can try again. If it succeeds,
    /// ASTRA's promise not to send twice is on disk before there is anything to
    /// be wrong about.
    ///
    /// `O_CREAT | O_EXCL` rather than exists-then-write, so two coordinators
    /// racing the same proposal are settled in the kernel: one creates the
    /// marker, the other gets `EEXIST` and is told the proposal is already
    /// claimed. `fsync` before returning, because a claim still sitting in the
    /// page cache is not a claim that survives the crash it exists for.
    private static func reserveSend(stagedPath: String, target: String) throws {
        let markerPath = sentMarkerPath(stagedPath: stagedPath)
        let descriptor = markerPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST {
                sentStagedPaths.insert(stagedPath)
                throw ConnectorMutationCoordinatorError.alreadySent(target)
            }
            throw ConnectorMutationCoordinatorError.sendNotReserved(reason: Self.describe(errno: code))
        }
        do {
            try writeAll(descriptor: descriptor, bytes: Array("sent\n".utf8))
            guard fsync(descriptor) == 0 else { throw Self.posixError() }
        } catch {
            close(descriptor)
            // The claim is not durable, so it must not be left behind either: a
            // marker this call did not commit would block a send that never
            // happened.
            unlink(markerPath)
            throw ConnectorMutationCoordinatorError.sendNotReserved(reason: error.localizedDescription)
        }
        close(descriptor)
        // The file's contents are durable; this is what makes its *name* so.
        // Unchecked, unlike the two above: on APFS the directory entry lands
        // with the file, and there is no useful recovery from failing here
        // other than the in-memory set that already covers this launch.
        let directoryPath = (markerPath as NSString).deletingLastPathComponent
        let directoryDescriptor = directoryPath.withCString { open($0, O_RDONLY) }
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
        sentStagedPaths.insert(stagedPath)
    }

    /// Gives a claim back, for the one outcome that is not ambiguous: the
    /// provider answered, on the record, that it did not act.
    private static func releaseSendReservation(stagedPath: String) {
        sentStagedPaths.remove(stagedPath)
        try? FileManager.default.removeItem(atPath: sentMarkerPath(stagedPath: stagedPath))
    }

    /// A full write, or a thrown error. `write(2)` is allowed to be partial and
    /// is allowed to be interrupted, and a marker holding half of "sent" is a
    /// marker that was never really written.
    private static func writeAll(descriptor: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            offset += written
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: describe(errno: errno)
        ])
    }

    private static func describe(errno code: Int32) -> String {
        String(cString: strerror(code))
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

/// The record that a proposal was retired without ever being readable.
///
/// Carries the scope fields as well as the pointer, because unlike a decline
/// there is no readable payload behind this event: if the transcript is going to
/// say anything at all about what was lost, it has to say it here.
struct ConnectorMutationQuarantine: Codable, Sendable, Equatable {
    let version: Int
    let stagedPayloadPath: String
    let requestDigest: String
    let serviceType: String
    let operation: String
    let target: String
    /// Why `prepare` refused, in the words the user was shown.
    let reason: String

    init(
        stagedPayloadPath: String,
        requestDigest: String,
        serviceType: String,
        operation: String,
        target: String,
        reason: String
    ) {
        version = 1
        self.stagedPayloadPath = stagedPayloadPath
        self.requestDigest = requestDigest
        self.serviceType = serviceType
        self.operation = operation
        self.target = target
        self.reason = reason
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
