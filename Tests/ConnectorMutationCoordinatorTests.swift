import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Covers the half of a connector write the agent is *not* allowed to do: the
/// commit. Everything here is about the app refusing to send something other
/// than what the user read, and about the credential reaching exactly one place.
@Suite("Connector mutation commit")
@MainActor
struct ConnectorMutationCoordinatorTests {
    /// The plan's central claim. A payload rewritten after staging must not be
    /// reviewable, let alone sendable.
    @Test("A payload rewritten after staging is refused at review time")
    func rewrittenPayloadIsRefusedAtReview() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()

        try Data("{\"tampered\":true}".utf8).write(to: URL(fileURLWithPath: pending.stagedPayloadPath))

        #expect(throws: ConnectorMutationCoordinatorError.self) {
            try fixture.coordinator().prepare(task: fixture.task, pending: pending)
        }
    }

    /// Refused at `prepare`, not at `send`. The sheet is built from the
    /// resolved operation — the route, the connector, the destination it will
    /// actually POST to — so a proposal ASTRA would never send cannot be
    /// rendered as one awaiting a click.
    @Test("A staged operation ASTRA does not recognise is never sent")
    func unknownOperationIsNeverSent() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(operation: "delete_project")
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)

        #expect(
            throws: ConnectorMutationCoordinatorError
                .unsupportedOperation(serviceType: "jira", operation: "delete_project")
        ) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.isEmpty)
    }

    /// The envelope is agent-writable, so a trusted `path` would aim an
    /// authenticated POST anywhere on the connector's host.
    @Test("A staged path that disagrees with ASTRA's route is never sent")
    func rewrittenRouteIsNeverSent() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(requestPath: "/rest/api/2/user")
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)

        #expect(
            throws: ConnectorMutationCoordinatorError.routeMismatch(
                staged: "POST /rest/api/2/user",
                expected: "POST /rest/api/2/issue"
            )
        ) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.isEmpty)
    }

    /// The envelope's own `connector_alias` is a label the agent wrote; only its
    /// `connector_id` decides where the credential goes. A sheet that repeated
    /// the label would let "sandbox" sit above a production address.
    @Test("The review names the connector ASTRA resolved, not the one the envelope claims")
    func reviewNamesTheResolvedConnector() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(connectorAlias: "jira-sandbox")

        let proposal = try fixture.coordinator().prepare(task: fixture.task, pending: pending)

        #expect(proposal.connectorAlias == "Jira")
        #expect(proposal.proposedConnectorAlias == "jira-sandbox")
        #expect(proposal.destinationURL == "https://jira.commit.test/rest/api/2/issue")
        #expect(
            proposal.fields.contains {
                $0.id == "endpoint" && $0.value == "POST https://jira.commit.test/rest/api/2/issue"
            }
        )
        // Shown, not silently corrected: the disagreement is the interesting part.
        let warning = try #require(proposal.warnings.first)
        #expect(proposal.warnings.count == 1)
        #expect(warning.contains("jira-sandbox"))
        #expect(warning.contains("Jira"))
    }

    /// An alias that only differs in case is the same connector, and warning
    /// about it would teach the user to click through the warnings that matter.
    @Test("An alias that matches the resolved connector raises no warning")
    func matchingAliasRaisesNoWarning() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(connectorAlias: "jira")

        let proposal = try fixture.coordinator().prepare(task: fixture.task, pending: pending)

        #expect(proposal.connectorAlias == "Jira")
        #expect(proposal.warnings.isEmpty)
    }

    /// The sheet can sit open for minutes. Re-pointing the connector in
    /// Configure › Connectors in that window would send the approved bytes to a
    /// host nobody approved.
    @Test("A connector re-pointed while the review was open is refused at send")
    func rePointedConnectorIsRefusedAtSend() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        fixture.connector.baseURL = "https://jira.elsewhere.test"

        await #expect(
            throws: ConnectorMutationCoordinatorError.connectorChangedSinceReview(
                reviewed: "Jira (https://jira.commit.test/rest/api/2/issue)",
                now: "Jira (https://jira.elsewhere.test/rest/api/2/issue)"
            )
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.isEmpty)
    }

    /// Every other path that hands out a connector credential — install,
    /// import, share, workspace config — runs `credentialTransportViolation`
    /// first. The write path had grown up without it, so an `https://`
    /// connector re-pointed at plain `http://` still had its Basic header built
    /// and sent to whatever host the new URL named.
    @Test("A connector on unprotected HTTP is refused before its credential is used")
    func insecureTransportIsRefusedAtSend() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        fixture.connector.baseURL = "http://jira.commit.test"

        await #expect(
            throws: ConnectorMutationCoordinatorError.insecureTransport(
                alias: "Jira", url: "http://jira.commit.test"
            )
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.isEmpty, "The credential must not reach the wire at all")
    }

    /// And refused before the user is ever asked, so the sheet cannot show an
    /// approval button for a request ASTRA would not make.
    @Test("A connector on unprotected HTTP is refused at review")
    func insecureTransportIsRefusedAtReview() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let coordinator = fixture.coordinator(sender: RecordingSender())
        fixture.connector.baseURL = "http://jira.commit.test"

        #expect(throws: ConnectorMutationCoordinatorError.insecureTransport(
            alias: "Jira", url: "http://jira.commit.test"
        )) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
    }

    /// A connector pointed at loopback is a local test instance and the
    /// credential never leaves the machine. Refusing it here would diverge from
    /// every other caller of the same policy.
    @Test("Loopback HTTP is still allowed to commit")
    func loopbackTransportStillCommits() async throws {
        let fixture = try Fixture(baseURL: "http://127.0.0.1:8080")
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-1"}"#)
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)
        _ = try await coordinator.send(task: fixture.task, proposal: proposal)

        #expect(sender.requests.count == 1)
    }

    @Test("A connector that is no longer the staged service is never used")
    func connectorServiceMismatchIsNeverSent() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        fixture.connector.serviceType = "github"

        await #expect(
            throws: ConnectorMutationCoordinatorError
                .connectorServiceMismatch(expected: "jira", found: "github")
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.isEmpty)
    }

    @Test("An approved proposal is sent verbatim and retires on its receipt")
    func approvedProposalIsSentAndRetired() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 201,
                body: #"{"id":"10001","key":"STAR-12558","self":"https://jira.commit.test/rest/api/2/issue/10001"}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let receipt = try await coordinator.send(task: fixture.task, proposal: proposal)

        #expect(receipt.createdKey == "STAR-12558")
        #expect(receipt.createdURL == "https://jira.commit.test/browse/STAR-12558")
        #expect(receipt.statusCode == 201)

        let request = try #require(sender.requests.first)
        #expect(request.url.absoluteString == "https://jira.commit.test/rest/api/2/issue")
        #expect(request.method == "POST")
        // Byte-for-byte what the digest covered, not a re-encoding of it.
        #expect(request.body == proposal.requestBody)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    /// A `4xx` is the one non-success the provider is willing to put its name
    /// to: it acted on the request by refusing it, and nothing was written. Only
    /// that shape gives the claim back.
    @Test("A rejected send is recorded but leaves the proposal reviewable")
    func rejectedSendLeavesTheProposalPending() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 400,
                body: #"{"errorMessages":["issuetype is required"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error == .requestFailed(statusCode: 400, message: "issuetype is required"))
        #expect(error?.isTerminal == false)
        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.failed })
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
        // The claim taken before dispatch is handed back, or the row would be
        // pending and unsendable at the same time.
        #expect(!FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))
        #expect(!ConnectorMutationCoordinator.hasBeenSent(stagedPath: pending.stagedPayloadPath))
    }

    /// Jira may well have filed the ticket before the socket died. Retrying
    /// would file it twice, and a duplicate ticket is the one outcome here that
    /// nobody can undo.
    @Test("A transport failure after dispatch is quarantined, not retried")
    func transportFailureAfterDispatchIsQuarantined() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(failure: FixtureTransportFailure())
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error == .dispatchedWithoutConfirmation(
            target: "STAR / Bug",
            reason: FixtureTransportFailure.message
        ))
        // The sheet reads this to decide the send button does not come back.
        #expect(error?.isTerminal == true)
        #expect(sender.requests.count == 1)
        // Not a failure. A failure event says the tracker is unchanged, and
        // that is precisely what ASTRA does not know.
        #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.failed })
        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.indeterminate })
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)

        // And it survives the relaunch that used to be where the duplicate came
        // from: the claim is on disk, written before the request went out.
        #expect(FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))
        ConnectorMutationCoordinator.resetSentStagedPathsForTesting()
        #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.count == 1)
    }

    /// A `503` is usually the gateway in front of Jira, and a gateway can time
    /// out on a request Jira has already committed.
    @Test("A gateway failure is quarantined rather than offered for retry")
    func gatewayFailureIsQuarantined() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 503,
                body: #"{"errorMessages":["Jira is temporarily unavailable"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error == .dispatchedWithoutConfirmation(
            target: "STAR / Bug",
            reason: "Jira is temporarily unavailable"
        ))
        #expect(error?.isTerminal == true)
        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.indeterminate })
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    /// The claim used to be written after the response, wrapped in `try?`, so
    /// the one situation it existed for — an unwritable task folder — was the
    /// situation in which it silently failed to appear.
    @Test("Nothing is dispatched when the send cannot be claimed durably")
    func sendIsRefusedWhenTheClaimCannotBeWritten() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let directory = (pending.stagedPayloadPath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        guard case .sendNotReserved = error else {
            Issue.record("Expected a reservation failure, got \(String(describing: error))")
            return
        }
        // Nothing went out, so the proposal is exactly as reviewable as it was.
        #expect(error?.isTerminal == false)
        #expect(sender.requests.isEmpty)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
    }

    /// The write happened; only the bookkeeping failed. Reporting that as a
    /// failure is what used to turn one approved ticket into two real ones,
    /// because the row stayed pending and the send button came back.
    @Test("A receipt that could not be saved is still a send, and terminal")
    func unrecordedReceiptIsStillASend() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-9"}"#)
        )
        let coordinator = fixture.coordinator(
            sender: sender,
            durableEventSave: { _, _, _, _ in throw FixtureSaveFailure() }
        )
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error == .sentButNotRecorded(target: "STAR-9", reason: FixtureSaveFailure.message))
        // The sheet reads this to decide the send button does not come back.
        #expect(error?.isTerminal == true)
        #expect(sender.requests.count == 1)
        // Not recorded as a failure either — a `failed` event is what a retry
        // would be built on.
        #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.failed })

        // And it cannot be offered for review again, which is where the second
        // click would have come from.
        #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.count == 1)
    }

    /// The in-memory guard dies with the process, and the case it exists for —
    /// a receipt that never reached the store — is exactly the case with no
    /// durable record to fall back on. The on-disk marker is what covers it.
    @Test("A sent proposal is still refused after the in-memory guard is lost")
    func sentMarkerSurvivesTheInMemoryGuard() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-7"}"#)
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)
        _ = try await coordinator.send(task: fixture.task, proposal: proposal)

        #expect(FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))

        // Stands in for a relaunch: the process forgets, the marker does not.
        ConnectorMutationCoordinator.resetSentStagedPathsForTesting()

        #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: pending)
        }
        await #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try await fixture.coordinator(sender: sender).send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.count == 1)
    }

    /// The design fails if committing reintroduces the credential anywhere the
    /// agent or the transcript can see it.
    @Test("The credential reaches the Authorization header and nothing else")
    func credentialStaysOutOfEverythingButTheHeader() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-1"}"#)
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)
        _ = try await coordinator.send(task: fixture.task, proposal: proposal)

        let request = try #require(sender.requests.first)
        #expect(request.authorizationHeader.hasPrefix("Basic "))
        #expect(!request.authorizationHeader.contains(Fixture.apiToken))

        let transcript = fixture.task.events.map(\.payload).joined(separator: "\n")
        #expect(!transcript.contains(Fixture.apiToken))
        #expect(!transcript.contains(request.authorizationHeader))
        let stagedBytes = try String(contentsOf: URL(fileURLWithPath: pending.stagedPayloadPath), encoding: .utf8)
        #expect(!stagedBytes.contains(Fixture.apiToken))
    }

    // MARK: - Ambiguous refusals

    /// A `408` is reported by whatever gave up waiting, not by the service that
    /// would have done the work. The gateway may well have forwarded the POST
    /// and Jira may well have filed the ticket, so re-arming Send here creates
    /// exactly the duplicate the indeterminate path exists to prevent.
    @Test("A request-timeout status is quarantined even though it is a 4xx")
    func requestTimeoutIsQuarantined() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 408,
                body: #"{"errorMessages":["Request timed out at the gateway"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error?.isTerminal == true)
        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.indeterminate })
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
        // The claim stays, so a relaunch cannot re-send what may already exist.
        #expect(FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))
    }

    /// The boundary the fix turns on: `400` still means the provider is on the
    /// record that it did not act, so it must stay retryable. Asserted next to
    /// the `408` case so a future simplification back to `(400...499)` breaks
    /// one of the two.
    @Test("A definite client refusal is still retryable")
    func clientRefusalStaysRetryable() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 400,
                body: #"{"errorMessages":["Issue type is required"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error?.isTerminal == false)
        #expect(!ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))
    }

    @Test("Status classification names only the timeout-shaped 4xx as ambiguous")
    func definiteRefusalClassification() {
        for code in [400, 401, 403, 404, 409, 422, 429] {
            #expect(ConnectorMutationCoordinator.isDefiniteRefusal(code), "\(code) should be definite")
        }
        for code in [408, 425, 500, 502, 503, 504, 307, 308, 200] {
            #expect(!ConnectorMutationCoordinator.isDefiniteRefusal(code), "\(code) should be ambiguous")
        }
    }

    // MARK: - Reflected credentials

    /// A brokered credential is deliberately never a run secret — that is what
    /// the broker is for — so nothing downstream of here can recognise it. When
    /// a provider or a proxy in front of it quotes the submitted `Authorization`
    /// value back in an error body, this message is the one string that carries
    /// the credential out of containment and into the store.
    @Test("A provider that echoes the credential does not get it persisted")
    func reflectedCredentialIsNotPersisted() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let header = "Basic " + Data("user@example.com:\(Fixture.apiToken)".utf8).base64EncodedString()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 401,
                body: #"{"errorMessages":["Rejected credential \#(header) for user@example.com"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        let transcript = fixture.task.events.map(\.payload).joined(separator: "\n")
        #expect(!transcript.contains(Fixture.apiToken))
        #expect(!transcript.contains(header))
        // Scrubbed, not discarded: the failure event exists so the user can see
        // why the send did not work, and "401" with no words is not that.
        #expect(transcript.contains("Rejected credential"))
    }

    /// Same route, different persistence: the indeterminate path writes the
    /// message to the audit log as well as to a task event, so it needs the same
    /// scrub and used to have neither.
    @Test("An echoed credential is scrubbed on the quarantine path too")
    func reflectedCredentialIsNotPersistedWhenQuarantined() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let header = "Basic " + Data("user@example.com:\(Fixture.apiToken)".utf8).base64EncodedString()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 502,
                body: #"{"errorMessages":["upstream rejected \#(header)"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        let transcript = fixture.task.events.map(\.payload).joined(separator: "\n")
        #expect(!transcript.contains(Fixture.apiToken))
        #expect(!transcript.contains(header))
        #expect(error?.localizedDescription.contains(Fixture.apiToken) != true)
    }

    // MARK: - Unreadable proposals

    /// `prepare` used to fail here and record nothing, so the pending event
    /// survived and the dock offered the same broken review forever — sitting
    /// above the correction and advisory rows the user could still act on.
    @Test("A proposal that cannot be opened can be retired")
    func unreadableProposalCanBeQuarantined() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        try fixture.recordStagedEvent(pending)
        try FileManager.default.removeItem(atPath: pending.stagedPayloadPath)

        let coordinator = fixture.coordinator()
        #expect(throws: (any Error).self) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
        #expect(!ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)

        try coordinator.quarantine(
            task: fixture.task,
            pending: pending,
            reason: "Staged mutation could not be read"
        )

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.quarantined })
        // Distinct from a decline on purpose: one says the user read it and said
        // no, the other says ASTRA lost it, and only the second is a bug report.
        #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.declined })
    }

    /// Retiring one broken proposal must not retire a healthy sibling — the
    /// resolution is keyed by staged path for the same reason approval is.
    @Test("Quarantining one proposal leaves the others pending")
    func quarantineIsScopedToItsProposal() throws {
        let fixture = try Fixture()
        let first = try fixture.stageProposal()
        let second = try fixture.stageProposal()
        try fixture.recordStagedEvent(first)
        try fixture.recordStagedEvent(second)

        try fixture.coordinator().quarantine(task: fixture.task, pending: first, reason: "gone")

        let stillPending = ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task)
        #expect(stillPending.map(\.stagedPayloadPath) == [second.stagedPayloadPath])
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        static let apiToken = "super-secret-token-value"

        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        let connector: Connector
        let workspaceRoot: URL

        init(baseURL: String = "https://jira.commit.test") throws {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [configuration]
            )
            context = container.mainContext
            workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-connector-commit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

            let workspace = Workspace(name: "Commit", primaryPath: workspaceRoot.path)
            task = AgentTask(title: "File a ticket", goal: "File a Jira ticket")
            run = TaskRun(task: task)
            connector = Connector(
                name: "Jira",
                serviceType: "jira",
                baseURL: baseURL,
                authMethod: "basic"
            )
            connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            task.workspace = workspace
            context.insert(workspace)
            context.insert(task)
            context.insert(run)
            context.insert(connector)
            try context.save()
        }

        deinit { try? FileManager.default.removeItem(at: workspaceRoot) }

        var taskFolder: String { TaskWorkspaceAccess(task: task).taskFolder }

        func coordinator(
            sender: any ConnectorMutationSending = RecordingSender(),
            durableEventSave: @escaping ConnectorMutationCoordinator.DurableEventSave = { _, _, _, _ in }
        ) -> ConnectorMutationCoordinator {
            ConnectorMutationCoordinator(
                modelContext: context,
                sender: sender,
                secretStore: FixtureSecretStore(values: [
                    "JIRA_EMAIL": "user@example.com",
                    "JIRA_API_TOKEN": Self.apiToken
                ]),
                durableEventSave: durableEventSave
            )
        }

        /// Stages through the same writer the broker uses, so the envelope under
        /// test is the envelope production produces.
        func stageProposal(
            operation: String = "create_issue",
            requestPath: String = "/rest/api/2/issue",
            connectorAlias: String = "jira"
        ) throws -> TaskStagedConnectorMutation {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: taskFolder, isDirectory: true),
                withIntermediateDirectories: true
            )
            let hostConnector = HostControlConnector(
                id: connector.id.uuidString,
                alias: connectorAlias,
                envPrefix: "JIRA_JIRA",
                name: "Jira",
                serviceType: "jira",
                baseURL: "https://jira.commit.test",
                authMethod: "basic",
                env: [:],
                credentials: [:],
                config: [:]
            )
            let staged = try ConnectorMutationStaging.stage(
                serviceType: "jira",
                operation: operation,
                connector: hostConnector,
                target: "STAR / Bug",
                summary: "Age filter missing on three domains",
                requestMethod: "POST",
                requestPath: requestPath,
                body: ["fields": [
                    "project": ["key": "STAR"],
                    "issuetype": ["name": "Bug"],
                    "summary": "Age filter missing on three domains"
                ]],
                configuration: HostControlToolConfiguration(
                    taskFolder: taskFolder,
                    runID: "run-1",
                    connectorsJSON: "{\"connectors\":[]}",
                    environment: [:]
                )
            )
            return TaskStagedConnectorMutation(
                runID: run.id,
                serviceType: staged.serviceType,
                operation: staged.operation,
                connectorID: staged.connectorID,
                connectorAlias: staged.connectorAlias,
                target: staged.target,
                summary: staged.summary,
                stagedPayloadPath: staged.path,
                requestDigest: staged.digest
            )
        }

        func recordStagedEvent(_ pending: TaskStagedConnectorMutation) throws {
            context.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: ConnectorMutationEventTypes.staged,
                payload: pending,
                run: run
            ))
            try context.save()
        }
    }
}

/// Stands in for the store being unwritable at the moment the receipt is saved.
private struct FixtureTransportFailure: LocalizedError {
    static let message = "The network connection was lost."
    var errorDescription: String? { Self.message }
}

private struct FixtureSaveFailure: LocalizedError {
    static let message = "the task store could not be written"
    var errorDescription: String? { Self.message }
}

private final class RecordingSender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConnectorMutationHTTPRequest] = []
    let response: ConnectorMutationHTTPResponse
    /// Thrown *after* the request is recorded, so a test can model the case that
    /// matters: the bytes went out and the answer never came back.
    let failure: (any Error)?

    init(
        response: ConnectorMutationHTTPResponse = ConnectorMutationHTTPResponse(statusCode: 201, body: "{}"),
        failure: (any Error)? = nil
    ) {
        self.response = response
        self.failure = failure
    }

    var requests: [ConnectorMutationHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        if let failure { throw failure }
        return response
    }
}

private struct FixtureSecretStore: SecretStore {
    let values: [String: String]

    func load(key: String, entityID _: String) -> String? { values[key] }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID _: String) -> Bool { values[key] != nil }
}
