import Foundation
import Testing
import ASTRACore
@testable import ASTRA
@testable import HostControlToolSupport

/// Cross-checks the three tables that together decide whether a connector write
/// can happen: what the broker will stage, what ASTRA will send, and what the
/// permission ledger will accept an approval for.
///
/// Each is edited on its own, in a different file, usually by someone adding a
/// single operation. The failure mode is not that one of them is wrong — it is
/// that two of them disagree, and the disagreement shows up as a proposal the
/// user approves and ASTRA then cannot send, or a send route with nothing
/// upstream to review it.
@Suite("Connector mutation seam")
struct ConnectorMutationSeamTests {
    /// A commit route for an unbrokered service is unreachable by construction:
    /// `isSafeConnectorMutationAuthorization` refuses the approval, because
    /// unbrokered means the credential is projected into the agent and there was
    /// never anything to protect. Better to fail here than to ship a POST route
    /// nobody can ever authorize.
    @Test("Every operation ASTRA can commit belongs to a brokered service")
    func everyCommitRouteIsBrokered() {
        let unbrokered = ConnectorMutationOperations.all
            .filter { !HostControlBrokeredServices.ownsConfiguration(ofServiceType: $0.serviceType) }
            .map(\.serviceType)

        #expect(
            unbrokered.isEmpty,
            """
            ASTRA can commit a mutation for a service the broker does not own: \
            \(unbrokered.sorted()). Register the service in \
            HostControlBrokeredServices, or remove the route.
            """
        )
    }

    /// The direction that hurts. The broker stages `create_issue`; if the send
    /// table ever loses that entry, the agent keeps composing proposals, the
    /// dock keeps raising them, and every approval ends in
    /// `unsupportedOperation` — a review surface that cannot do the one thing it
    /// asks the user to authorize.
    @Test("Everything the broker stages is something ASTRA can send")
    func everyStagedOperationHasACommitRoute() {
        let staged = JiraIssueProposalPolicy.stagedOperation

        #expect(
            ConnectorMutationOperations.definition(serviceType: "jira", operation: staged) != nil,
            """
            The Jira broker stages '\(staged)' but ConnectorMutationOperations has \
            no route for it, so an approved proposal cannot be sent.
            """
        )
    }

    /// Not a style rule. Every entry here is a URL the app will POST to with a
    /// Keychain credential attached, chosen by the app rather than by the staged
    /// envelope — which is the only reason a rewritten envelope cannot redirect
    /// the credential. An entry that took its path from elsewhere, or reached a
    /// different host, would give that back.
    @Test("Commit routes are absolute paths on the connector's own host")
    func commitRoutesAreWellFormed() {
        for definition in ConnectorMutationOperations.all {
            #expect(definition.path.hasPrefix("/"), "\(definition.operation): path is not absolute")
            #expect(!definition.path.contains(".."), "\(definition.operation): path contains traversal")
            #expect(!definition.path.contains("://"), "\(definition.operation): path names a host")
            #expect(
                definition.serviceType == definition.serviceType.lowercased(),
                "\(definition.serviceType): lookups lowercase the service type, so the table must too"
            )
            #expect(
                definition.operation == definition.operation.lowercased(),
                "\(definition.operation): lookups lowercase the operation, so the table must too"
            )
        }
    }

    /// The prompt tells the agent to propose only where ASTRA can actually
    /// commit. If this drifts, the guidance either goes silent on a service that
    /// works or advertises one that does not.
    @Test("Mutation support is reported from the commit table")
    func mutationSupportTracksTheCommitTable() {
        #expect(ConnectorMutationOperations.supportsMutation(serviceType: "jira"))
        #expect(ConnectorMutationOperations.supportsMutation(serviceType: " JIRA "))
        #expect(!ConnectorMutationOperations.supportsMutation(serviceType: "github"))
        #expect(!ConnectorMutationOperations.supportsMutation(serviceType: ""))
    }

    /// The ceiling has to bind on what is allocated, not on what is kept.
    /// `URLSession.data(for:)` returns only once the whole body is in memory, so
    /// trimming afterwards left a connector answering a write with a gigabyte —
    /// a misconfigured proxy, an error page from something that is not the
    /// service — free to pull all of it in first.
    @Test("A response larger than the ceiling stops at the ceiling")
    func oversizedResponsesStopAtTheCeiling() async throws {
        let limit = 4 * 1024
        let source = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-oversized-\(UUID().uuidString).json")
        try Data(repeating: UInt8(ascii: "x"), count: limit * 8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (stream, _) = try await session.bytes(from: source)
        let body = try await URLSessionConnectorMutationSender.read(stream, limit: limit)

        #expect(body.count == limit)
    }

    /// The ordinary case, and the one the cap must not damage: a receipt is an
    /// issue key and a URL, and it has to come back whole.
    @Test("A response under the ceiling is returned intact")
    func ordinaryResponsesAreReturnedWhole() async throws {
        let receipt = #"{"id":"10042","key":"STAR-1","self":"https://jira.test/rest/api/2/issue/10042"}"#
        let source = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-receipt-\(UUID().uuidString).json")
        try Data(receipt.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (stream, _) = try await session.bytes(from: source)
        let body = try await URLSessionConnectorMutationSender.read(
            stream, limit: URLSessionConnectorMutationSender.responseByteLimit)

        #expect(String(data: body, encoding: .utf8) == receipt)
    }
}
