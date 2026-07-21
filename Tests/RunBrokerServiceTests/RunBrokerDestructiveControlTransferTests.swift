import ASTRACore
import ASTRARunLedger
import Foundation
import RunSupervisorSupport
import Testing
@_spi(RunBrokerServiceTesting) @testable import RunBrokerService

/// Regression coverage for the residual PR #356 documented: after a journaled
/// `executionAuthorityTransferred`, the destructive/control paths
/// (`authenticateSupervisorProvenance`, `requestImmediateTermination`, and the
/// transport discovery validation they drive) still compared the vault
/// capability and addressed the supervisor child with a CURRENT-authority
/// identity. The supervisor process, its vaulted capability, and its on-disk
/// discovery record are bound forever to the immutable LAUNCH identity, so
/// every legal transfer turned provenance into `supervisorUnavailable` and
/// termination into `missingCapability` forever. The rule under test:
/// authorize on current authority, address the child by launch identity.
@Suite("RunBroker destructive control after authority transfer", .serialized)
struct RunBrokerDestructiveControlTransferTests {
    @discardableResult
    private func transferAuthority(
        _ fixture: BrokerFixture,
        newAuthorityID: UInt8 = 50,
        eventID: UInt8 = 51,
        at offset: TimeInterval = 10
    ) throws -> RunBrokerAuthority {
        let successor = RunBrokerAuthority(
            id: .init(rawValue: brokerUUID(newAuthorityID)),
            epoch: .init(rawValue: 2)
        )
        _ = try fixture.ledger.append(.init(
            eventID: .init(rawValue: brokerUUID(eventID)),
            occurredAt: brokerTestDate.addingTimeInterval(offset),
            event: .executionAuthorityTransferred(
                executionID: fixture.manifest.executionID,
                expectedAuthority: fixture.manifest.authority,
                newAuthority: successor
            )
        ))
        return successor
    }

    private func identity(
        _ fixture: BrokerFixture,
        authority: RunBrokerAuthority
    ) -> RunSupervisorIdentity {
        .init(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: fixture.manifest.executionID,
            authority: authority
        )
    }

    private func startedFixture() throws -> BrokerFixture {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        return fixture
    }

    @Test("provenance authenticates the launch-epoch supervisor after a transfer")
    func provenanceAuthenticatesAfterTransfer() throws {
        let fixture = try startedFixture()
        let successor = try transferAuthority(fixture)
        let launchIdentity = RunSupervisorIdentity(manifest: fixture.manifest)
        // The strict transport mirrors the Darwin discovery validation: the
        // supervisor's on-disk record carries the launch identity forever, so
        // any current-authority addressing is an identity mismatch.
        let transport = LaunchIdentityValidatingTransport(
            expected: launchIdentity,
            wrapping: fixture.transport
        )
        let orchestrator = RunBrokerOrchestrator(
            ledger: fixture.ledger,
            vault: fixture.vault,
            spawner: fixture.spawner,
            transport: transport,
            installedBrokerExecutableURL: fixture.root
                .appendingPathComponent("installed/astra-run-broker"),
            faultInjector: NoOpRunBrokerStartFaultInjector(),
            terminationAuthorizer: DenyRunBrokerImmediateTerminationAuthorizer(),
            logger: fixture.logger
        )

        // The caller presents the CURRENT authority (the fence) and the child
        // is addressed by its immutable launch identity.
        try orchestrator.authenticateSupervisorProvenance(
            identity: identity(fixture, authority: successor),
            expectedManifestSHA256: try RunSupervisorDigests.manifest(fixture.manifest)
        )
        #expect(transport.presenceIdentities == [launchIdentity])
    }

    @Test("stale-authority provenance callers are still rejected after a transfer")
    func staleProvenanceCallerStaysRejected() throws {
        let fixture = try startedFixture()
        _ = try transferAuthority(fixture)
        let orchestrator = fixture.orchestrator()
        let digest = try RunSupervisorDigests.manifest(fixture.manifest)

        // The launch epoch is no longer the execution's authority; a caller
        // still holding it must not be able to observe or control.
        #expect(throws: RunBrokerServiceError.supervisorUnavailable) {
            try orchestrator.authenticateSupervisorProvenance(
                identity: identity(fixture, authority: fixture.manifest.authority),
                expectedManifestSHA256: digest
            )
        }
        // A forged future epoch is equally stale.
        #expect(throws: RunBrokerServiceError.supervisorUnavailable) {
            try orchestrator.authenticateSupervisorProvenance(
                identity: identity(fixture, authority: .init(
                    id: .init(rawValue: brokerUUID(52)),
                    epoch: .init(rawValue: 3)
                )),
                expectedManifestSHA256: digest
            )
        }
    }

    @Test("immediate termination reaches the launch-epoch supervisor after a transfer")
    func immediateTerminationReachesSupervisorAfterTransfer() throws {
        let fixture = try startedFixture()
        let successor = try transferAuthority(fixture)
        let launchIdentity = RunSupervisorIdentity(manifest: fixture.manifest)
        let transport = LaunchIdentityValidatingTransport(
            expected: launchIdentity,
            wrapping: fixture.transport
        )
        let authorizer = RecordingTerminationAuthorizer()
        let orchestrator = RunBrokerOrchestrator(
            ledger: fixture.ledger,
            vault: fixture.vault,
            spawner: fixture.spawner,
            transport: transport,
            installedBrokerExecutableURL: fixture.root
                .appendingPathComponent("installed/astra-run-broker"),
            faultInjector: NoOpRunBrokerStartFaultInjector(),
            terminationAuthorizer: authorizer,
            logger: fixture.logger
        )

        try orchestrator.requestImmediateTermination(
            .init(executionID: fixture.manifest.executionID, intent: .immediate),
            requestedAt: brokerTestDate.addingTimeInterval(11),
            auditID: brokerUUID(60)
        )

        // The destructive effect reached the transport, addressed by the
        // immutable launch identity.
        #expect(fixture.transport.immediateTerminationCount == 1)
        #expect(transport.terminationIdentities == [launchIdentity])
        // Authorization stays fenced on the CURRENT authority.
        #expect(authorizer.expectedIdentities == [identity(fixture, authority: successor)])
        // The durable audit fact carries the current authority, which the
        // ledger's fencing primitive requires.
        let audited = try fixture.ledger.events(limit: 100)
            .compactMap { stored -> RunBrokerAuthority? in
                guard case .executionControlTransitioned(
                    _, let authority, .requestCancellation(.immediate), _
                ) = stored.envelope.event else { return nil }
                return authority
            }
        #expect(audited == [successor])
    }

    @Test("Darwin discovery validation accepts the launch-epoch record after a transfer")
    func darwinDiscoveryValidationAcceptsLaunchEpochRecord() throws {
        let fixture = try BrokerFixture()
        let harness = try DarwinSupervisorHarness(fixture: fixture)
        try fixture.admitOnly()
        try fixture.vault.persistAndSynchronize(.init(
            identity: harness.launchIdentity,
            manifestSHA256: harness.manifestDigest,
            capability: harness.capability
        ))
        let orchestrator = RunBrokerOrchestrator(
            ledger: fixture.ledger,
            vault: fixture.vault,
            spawner: fixture.spawner,
            transport: harness.transport,
            installedBrokerExecutableURL: fixture.root
                .appendingPathComponent("installed/astra-run-broker"),
            faultInjector: NoOpRunBrokerStartFaultInjector(),
            terminationAuthorizer: AllowExactRunBrokerImmediateTerminationAuthorizer(),
            logger: fixture.logger
        )
        #expect(try orchestrator.reconcile(
            executionID: fixture.manifest.executionID
        ).state == .running)
        let successor = try transferAuthority(fixture)

        // Provenance authenticates against the real launch-epoch discovery
        // record and offline spool even though the caller holds the successor
        // authority.
        try orchestrator.authenticateSupervisorProvenance(
            identity: identity(fixture, authority: successor),
            expectedManifestSHA256: harness.manifestDigest
        )

        // Termination clears vault and discovery validation addressed by the
        // launch identity; the only remaining failure is the absent live
        // control socket of this fabricated supervisor (the client's lstat
        // guard), proving the request was accepted by the discovery layer,
        // not rejected as an identity mismatch or a missing capability.
        do {
            try orchestrator.requestImmediateTermination(
                .init(executionID: fixture.manifest.executionID, intent: .immediate),
                requestedAt: brokerTestDate.addingTimeInterval(11),
                auditID: brokerUUID(61)
            )
            Issue.record("Expected a control-socket failure at the absent socket")
        } catch RunSupervisorError.unsafeFilesystemEntry(let entry) {
            #expect(entry == "control.sock")
        }
    }

    @Test("Darwin discovery validation rejects current-authority addressing")
    func darwinDiscoveryValidationRejectsCurrentAuthorityAddressing() throws {
        let fixture = try BrokerFixture()
        let harness = try DarwinSupervisorHarness(fixture: fixture)
        let successorIdentity = identity(fixture, authority: .init(
            id: .init(rawValue: brokerUUID(50)),
            epoch: .init(rawValue: 2)
        ))

        // The launch-epoch identity is exactly what the discovery record
        // proves; a successor-epoch identity is the current-vs-launch mismatch
        // the orchestrator used to produce before the split.
        #expect(try harness.transport.presence(
            identity: harness.launchIdentity,
            capability: harness.capability
        ) == .authenticated)
        #expect(throws: RunBrokerServiceError.supervisorIdentityMismatch) {
            _ = try harness.transport.presence(
                identity: successorIdentity,
                capability: harness.capability
            )
        }
        #expect(throws: RunBrokerServiceError.supervisorIdentityMismatch) {
            try harness.transport.requestImmediateTermination(
                identity: successorIdentity,
                capability: harness.capability
            )
        }
    }
}

/// A real `DarwinRunBrokerSupervisorTransport` over a fabricated supervisor
/// execution directory: a launch-identity discovery record plus a
/// capability-authenticated offline spool holding ready/started evidence.
private struct DarwinSupervisorHarness {
    let rootURL: URL
    let transport: DarwinRunBrokerSupervisorTransport
    let launchIdentity: RunSupervisorIdentity
    let capability: RunSupervisorCapability
    let manifestDigest: ExecutionLaunchArgumentsSHA256

    init(fixture: BrokerFixture) throws {
        // Short root: the execution directory's control-socket path must stay
        // under the 103-byte `sun_path` limit of the Darwin control client.
        rootURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "astra-rbds-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let trustedRoot = try RunSupervisorTrustedRoot(path: rootURL.path)
        launchIdentity = RunSupervisorIdentity(manifest: fixture.manifest)
        capability = try RunSupervisorCapability.random()
        manifestDigest = try RunSupervisorDigests.manifest(fixture.manifest)
        let directory = try trustedRoot
            .acquireExecutionDirectory(fixture.manifest.executionID).directory
        let spool = try RunSupervisorEventSpool(
            directory: directory,
            capability: capability
        )
        try spool.appendCritical(.supervisorReady)
        try spool.appendCritical(.providerStarted)
        spool.releaseOwnership()
        try DarwinRunSupervisorFileSystem().writeDiscovery(
            .init(
                identity: launchIdentity,
                manifestSHA256: manifestDigest,
                launchAuthenticator: String(repeating: "0", count: 64),
                capabilitySHA256: try RunSupervisorDigests.capability(capability),
                createdAt: brokerTestDate
            ),
            in: directory
        )
        transport = DarwinRunBrokerSupervisorTransport(trustedRoot: trustedRoot)
    }
}

/// Mirrors the Darwin transport's discovery validation at the seam level: the
/// supervisor's durable record carries the immutable launch identity, so every
/// transport call must be addressed by it or it is an identity mismatch.
private final class LaunchIdentityValidatingTransport: RunBrokerSupervisorTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: RunSupervisorIdentity
    private let wrapped: any RunBrokerSupervisorTransporting
    private(set) var presenceIdentities: [RunSupervisorIdentity] = []
    private(set) var terminationIdentities: [RunSupervisorIdentity] = []

    init(expected: RunSupervisorIdentity, wrapping: any RunBrokerSupervisorTransporting) {
        self.expected = expected
        self.wrapped = wrapping
    }

    private func validate(_ identity: RunSupervisorIdentity) throws {
        guard identity == expected else {
            throw RunBrokerServiceError.supervisorIdentityMismatch
        }
    }

    func presence(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws -> RunBrokerSupervisorPresence {
        lock.lock()
        presenceIdentities.append(identity)
        lock.unlock()
        try validate(identity)
        return try wrapped.presence(identity: identity, capability: capability)
    }

    func replay(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        after sequence: UInt64
    ) throws -> RunBrokerSupervisorReplayBatch {
        try validate(identity)
        return try wrapped.replay(identity: identity, capability: capability, after: sequence)
    }

    func acknowledge(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        source: RunBrokerSupervisorReplaySource,
        through sequence: UInt64
    ) throws {
        try validate(identity)
        try wrapped.acknowledge(
            identity: identity,
            capability: capability,
            source: source,
            through: sequence
        )
    }

    func requestImmediateTermination(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {
        lock.lock()
        terminationIdentities.append(identity)
        lock.unlock()
        try validate(identity)
        try wrapped.requestImmediateTermination(identity: identity, capability: capability)
    }
}

/// Delegates to the exact production authorizer while recording the identity
/// the orchestrator fences authorization on.
private final class RecordingTerminationAuthorizer: RunBrokerImmediateTerminationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let wrapped = AllowExactRunBrokerImmediateTerminationAuthorizer()
    private(set) var expectedIdentities: [RunSupervisorIdentity] = []

    var allowsImmediateTermination: Bool { wrapped.allowsImmediateTermination }

    func authorize(
        request: RunBrokerImmediateTerminationRequest,
        expectedIdentity: RunSupervisorIdentity
    ) throws -> RunBrokerImmediateTerminationAuthorization {
        lock.lock()
        expectedIdentities.append(expectedIdentity)
        lock.unlock()
        return try wrapped.authorize(request: request, expectedIdentity: expectedIdentity)
    }
}
