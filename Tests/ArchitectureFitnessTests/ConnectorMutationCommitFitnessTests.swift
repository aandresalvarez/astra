import Foundation
import Testing

/// The app half of the propose/commit split, guarded structurally.
///
/// The broker side has its own fitness suite proving it cannot send. These
/// prove the thing that makes the user's approval mean something on the app
/// side: what goes on the wire is what was reviewed, aimed where ASTRA decided
/// to aim it. Both properties are one plausible-looking refactor away from
/// being lost — sending `proposal.requestBody` directly reads like an obvious
/// simplification, and trusting the envelope's own path reads like removing a
/// redundant check.
///
/// This target has no package dependencies, so everything here is a source scan.
/// The behavioural half lives in `Tests/ConnectorMutationCoordinatorTests.swift`.
@Suite("Connector mutation commit fitness")
struct ConnectorMutationCommitFitnessTests {
    private static let coordinatorPath = "Astra/Services/Tasks/ConnectorMutationCoordinator.swift"
    private static let senderPath = "Astra/Services/Tasks/ConnectorMutationSender.swift"

    /// The sheet can sit open for minutes over an agent-writable directory. A
    /// send that trusts its in-memory copy would let the bytes change under a
    /// review that already happened.
    @Test("The send path re-reads and re-verifies the staged payload")
    func sendReVerifiesTheStagedPayload() throws {
        let body = try functionBody(startingWith: "func send(", in: try fileText(Self.coordinatorPath))

        #expect(
            body.contains("readStaged("),
            """
            ConnectorMutationCoordinator.send no longer re-reads the staged file. \
            Approval is bound to a digest; without a re-read at send time the \
            digest only describes what the user saw, not what gets posted.
            """
        )
        #expect(
            !body.contains("proposal.requestBody"),
            """
            send() reaches for the in-memory body instead of the bytes it just \
            re-verified. Those are the same only until the staged file changes, \
            which is exactly the case the re-read exists for.
            """
        )
    }

    /// A trusted `requestPath` would let a rewritten envelope aim an
    /// authenticated POST anywhere on the connector's host.
    ///
    /// Derivation happens in `resolveProposal`, which is what both the review
    /// and the send are built from — so the destination the user reads and the
    /// destination that receives the credential come from the same computation.
    @Test("The outbound route comes from ASTRA's table, not the envelope")
    func routeIsDerivedNotTrusted() throws {
        let source = try fileText(Self.coordinatorPath)
        let resolved = try functionBody(startingWith: "func resolveProposal(", in: source)

        #expect(
            resolved.contains("ConnectorMutationOperations.definition("),
            "resolveProposal no longer resolves the route from ConnectorMutationOperations."
        )
        #expect(
            resolved.contains("routeMismatch"),
            """
            resolveProposal no longer refuses an envelope whose declared route \
            disagrees with ASTRA's. Disagreement is the only signal that the \
            envelope was rewritten.
            """
        )
        // The proposal's own route fields are what the sheet renders and what
        // `buildRequest` sends, so they have to come from the table too — not
        // be copied across from the envelope that declared them.
        for derived in [
            "requestMethod: definition.method",
            "requestPath: definition.path",
            "path: definition.path"
        ] {
            #expect(
                resolved.contains(derived),
                "resolveProposal no longer derives the route from ASTRA's table (\(derived))."
            )
        }

        let built = try functionBody(startingWith: "func buildRequest(", in: source)
        for trusted in ["staged.requestPath", "staged.requestMethod", "staged.path"] {
            #expect(
                !built.contains(trusted),
                "buildRequest builds the request from a declared route (\(trusted)) rather than the resolved URL."
            )
        }
        #expect(
            built.contains("proposal.destinationURL"),
            "buildRequest no longer posts to the destination resolveProposal derived and the user approved."
        )
    }

    /// The connector is resolved for the sheet and resolved again here. A
    /// connector re-pointed, renamed, or swapped while the review sat open
    /// makes this a different request than the one that was read, and the
    /// approval does not carry across.
    @Test("The send path re-resolves the destination and refuses a changed one")
    func sendRevalidatesTheDestination() throws {
        let body = try functionBody(startingWith: "func send(", in: try fileText(Self.coordinatorPath))

        #expect(
            body.contains("resolveProposal("),
            "send() no longer re-resolves the connector and destination before posting."
        )
        #expect(
            body.contains("connectorChangedSinceReview"),
            """
            send() no longer refuses a destination that moved since the review. \
            Binding the approval to the payload alone lets the same bytes go to \
            a different host.
            """
        )
    }

    /// Not a layering preference. `ConnectorMutationHTTPRequest` is the only
    /// type in the app that carries a resolved connector credential, and it is
    /// deliberately unprintable; a second sender would be a second place for one
    /// to end up, without that treatment.
    @Test("Only the sender file performs the connector write")
    func onlyTheSenderPerformsTheWrite() throws {
        let coordinator = try fileText(Self.coordinatorPath)
        // Naming `URLSessionConnectorMutationSender` as the injected default is
        // fine and is the point of the seam; reaching past it to URLSession
        // itself is not.
        for networking in ["URLSession.", "URLSession(", "URLRequest", "dataTask", "data(for:"] {
            #expect(
                !coordinator.contains(networking),
                """
                ConnectorMutationCoordinator references \(networking) directly. \
                The write goes through the ConnectorMutationSending seam so tests \
                can prove what was sent without reaching the network.
                """
            )
        }
    }

    /// The request holds a credential. A synthesised `description`, a `Codable`
    /// conformance, or an `Equatable` one is enough for it to reach a log line
    /// or a transcript by accident.
    @Test("The credential-bearing request stays unprintable")
    func credentialBearingRequestStaysUnprintable() throws {
        let source = try fileText(Self.senderPath)
        guard let declaration = source.range(of: "struct ConnectorMutationHTTPRequest") else {
            throw ConnectorMutationCommitFitnessError.declarationNotFound("ConnectorMutationHTTPRequest")
        }
        let line = String(source[declaration.lowerBound...].prefix(while: { $0 != "\n" }))

        for conformance in ["Codable", "Encodable", "Decodable", "Equatable", "CustomStringConvertible"] {
            #expect(
                !line.contains(conformance),
                """
                ConnectorMutationHTTPRequest conforms to \(conformance): \(line). \
                It carries the Authorization header, so anything that can render \
                it can leak it.
                """
            )
        }
    }

    // MARK: - Helpers

    private func functionBody(startingWith declaration: String, in source: String) throws -> String {
        guard let start = source.range(of: declaration) else {
            throw ConnectorMutationCommitFitnessError.declarationNotFound(declaration)
        }
        let remainder = source[start.upperBound...]
        guard let end = remainder.range(of: "\n    }") else {
            throw ConnectorMutationCommitFitnessError.declarationNotFound("\(declaration) body")
        }
        return String(remainder[..<end.lowerBound])
    }

    private func fileText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw ConnectorMutationCommitFitnessError.repositoryRootNotFound(
                    FileManager.default.currentDirectoryPath
                )
            }
            candidate = parent
        }
    }
}

private enum ConnectorMutationCommitFitnessError: LocalizedError {
    case repositoryRootNotFound(String)
    case declarationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .repositoryRootNotFound(let path):
            return "Could not find the repository root from \(path)"
        case .declarationNotFound(let name):
            return "Could not find \(name) in the source"
        }
    }
}
