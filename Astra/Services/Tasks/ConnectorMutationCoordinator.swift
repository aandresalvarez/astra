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
    case missingCredential(String)
    case invalidBaseURL(String)
    case requestFailed(statusCode: Int, message: String)

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
        case let .missingCredential(alias):
            "The \(alias) connector has no usable credential in the Keychain, so ASTRA cannot send this."
        case let .invalidBaseURL(url):
            "The connector's base URL (\(url)) is not a valid http(s) URL."
        case let .requestFailed(statusCode, message):
            statusCode > 0
                ? "The connector rejected the request (HTTP \(statusCode)): \(message)"
                : "The request could not be completed: \(message)"
        }
    }

    private func operationDescription(_ value: String) -> String { value }

    /// The provider status, when there was one. Zero means ASTRA never got a
    /// reply — a refusal before the request, or a transport failure.
    var statusCode: Int {
        if case let .requestFailed(statusCode, _) = self { return statusCode }
        return 0
    }
}

/// What ASTRA actually sent, and what came back.
struct ConnectorMutationReceipt: Codable, Sendable, Equatable {
    let version: Int
    let requestDigest: String
    let serviceType: String
    let operation: String
    let target: String
    let statusCode: Int
    /// Provider-assigned identifier, e.g. `STAR-12558`. Absent when the response
    /// did not name one.
    let createdKey: String?
    let createdURL: String?

    init(
        requestDigest: String,
        serviceType: String,
        operation: String,
        target: String,
        statusCode: Int,
        createdKey: String?,
        createdURL: String?
    ) {
        version = 1
        self.requestDigest = requestDigest
        self.serviceType = serviceType
        self.operation = operation
        self.target = target
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
    let requestDigest: String
    let statusCode: Int
    let message: String

    init(requestDigest: String, statusCode: Int, message: String) {
        version = 1
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
    let connectorAlias: String
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

    var id: String { requestDigest }

    var fields: [ConnectorMutationReviewField] {
        [
            ConnectorMutationReviewField(id: "connector", label: "Connector", value: "\(connectorAlias) (\(serviceType))", isMonospaced: false),
            ConnectorMutationReviewField(id: "operation", label: "ASTRA will perform", value: operation, isMonospaced: true),
            ConnectorMutationReviewField(id: "target", label: "Destination", value: target, isMonospaced: false),
            ConnectorMutationReviewField(id: "summary", label: "Summary", value: summary, isMonospaced: false),
            ConnectorMutationReviewField(id: "request", label: "Request", value: "\(requestMethod) \(requestPath)", isMonospaced: true),
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

    /// Re-reads the staged payload and refuses if it is not byte-identical to
    /// what was recorded.
    ///
    /// Verified at review time as well as at send time, and for a different
    /// reason. Verifying at send stops a payload swapped after approval;
    /// verifying here stops the user approving bytes that already changed. Both
    /// have to hold, or "the user read it" stops meaning anything.
    func prepare(
        task: AgentTask,
        pending: TaskStagedConnectorMutation
    ) throws -> ConnectorMutationProposal {
        try readStaged(
            task: task,
            path: pending.stagedPayloadPath,
            digest: pending.requestDigest
        )
    }

    private func readStaged(
        task: AgentTask,
        path: String,
        digest: String
    ) throws -> ConnectorMutationProposal {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else {
            throw ConnectorMutationCoordinatorError.noTaskFolder
        }
        let staged: ConnectorMutationStaging.StagedConnectorMutation
        do {
            staged = try ConnectorMutationStaging.read(
                atPath: path,
                containedIn: taskFolder,
                expectedDigest: digest
            )
        } catch let error as ConnectorMutationStagingError {
            throw ConnectorMutationCoordinatorError.staleProposal(error.message)
        } catch {
            throw ConnectorMutationCoordinatorError.unreadableStagedPayload(error.localizedDescription)
        }
        return ConnectorMutationProposal(
            serviceType: staged.serviceType,
            operation: staged.operation,
            connectorID: staged.connectorID,
            connectorAlias: staged.connectorAlias,
            target: staged.target,
            summary: staged.summary,
            requestMethod: staged.requestMethod,
            requestPath: staged.requestPath,
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
        let staged = try readStaged(
            task: task,
            path: proposal.stagedPayloadPath,
            digest: proposal.requestDigest
        )

        do {
            let request = try buildRequest(staged)
            let response = try await sender.send(request)
            guard (200...299).contains(response.statusCode) else {
                throw ConnectorMutationCoordinatorError.requestFailed(
                    statusCode: response.statusCode,
                    message: Self.providerMessage(response.body)
                )
            }
            let receipt = Self.receipt(for: staged, response: response, baseURL: request.url)
            try record(
                receipt,
                type: ConnectorMutationEventTypes.receipt,
                task: task,
                digest: staged.requestDigest,
                operation: "connector_mutation_sent"
            )
            return receipt
        } catch {
            // Recorded, then rethrown. The sheet shows the error and the row
            // stays pending; the event is so the transcript says an attempt was
            // made, which is what stops a retry looking like a first try.
            try? record(
                ConnectorMutationFailure(
                    requestDigest: staged.requestDigest,
                    statusCode: (error as? ConnectorMutationCoordinatorError)?.statusCode ?? 0,
                    message: error.localizedDescription
                ),
                type: ConnectorMutationEventTypes.failed,
                task: task,
                digest: staged.requestDigest,
                operation: "connector_mutation_failed"
            )
            throw error
        }
    }

    private func buildRequest(_ staged: ConnectorMutationProposal) throws -> ConnectorMutationHTTPRequest {
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
        return ConnectorMutationHTTPRequest(
            url: url,
            method: definition.method,
            body: staged.requestBody,
            authorizationHeader: try authorizationHeader(for: connector, alias: staged.connectorAlias)
        )
    }

    /// Resolves the connector by the UUID recorded in the envelope.
    ///
    /// The envelope is agent-writable, so this deliberately re-checks the
    /// service type: without it, a rewritten `connector_id` could point the
    /// approved Jira payload at whichever connector holds the most useful
    /// credential. What the user saw named this connector; what is sent must
    /// use it.
    private func resolveConnector(_ staged: ConnectorMutationProposal) throws -> Connector {
        guard let id = UUID(uuidString: staged.connectorID) else {
            throw ConnectorMutationCoordinatorError.connectorNotFound(staged.connectorID)
        }
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        guard let connector = try? modelContext.fetch(descriptor).first else {
            throw ConnectorMutationCoordinatorError.connectorNotFound(staged.connectorID)
        }
        let found = connector.serviceType.lowercased()
        guard found == staged.serviceType.lowercased() else {
            throw ConnectorMutationCoordinatorError.connectorServiceMismatch(
                expected: staged.serviceType,
                found: found
            )
        }
        return connector
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
        for staged: ConnectorMutationProposal,
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
            requestDigest: staged.requestDigest,
            serviceType: staged.serviceType,
            operation: staged.operation,
            target: staged.target,
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
        digest: String,
        operation: String
    ) throws {
        let previousUpdatedAt = task.updatedAt
        let event = TaskEvent.structuredPayloadEvent(
            task: task,
            type: type,
            payload: payload,
            run: run(for: task, digest: digest)
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
    /// composed, and `recordedDigests` already stops a declined proposal
    /// reappearing on the next scan.
    func decline(task: AgentTask, digest: String) throws {
        try record(
            ConnectorMutationDecision(requestDigest: digest),
            type: ConnectorMutationEventTypes.declined,
            task: task,
            digest: digest,
            operation: "connector_mutation_declined"
        )
    }

    private func run(for task: AgentTask, digest: String) -> TaskRun? {
        guard let runID = ConnectorMutationRequirementResolver
            .pendingMutations(task: task)
            .first(where: { $0.requestDigest == digest })?
            .runID else {
            return nil
        }
        return task.runs.first { $0.id == runID }
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
    let requestDigest: String

    init(requestDigest: String) {
        version = 1
        self.requestDigest = requestDigest
    }
}
