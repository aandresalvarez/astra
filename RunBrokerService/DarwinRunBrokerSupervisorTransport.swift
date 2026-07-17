import ASTRACore
import Darwin
import Foundation
import RunSupervisorSupport

public struct DarwinRunBrokerSupervisorTransport: RunBrokerSupervisorTransporting, Sendable {
    private let trustedRoot: RunSupervisorTrustedRoot
    private let fileSystem: any RunSupervisorFileSystem
    private let client: DarwinRunSupervisorControlClient

    public init(
        trustedRoot: RunSupervisorTrustedRoot,
        fileSystem: any RunSupervisorFileSystem = DarwinRunSupervisorFileSystem(),
        client: DarwinRunSupervisorControlClient = .init()
    ) {
        self.trustedRoot = trustedRoot
        self.fileSystem = fileSystem
        self.client = client
    }

    public func replay(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        after sequence: UInt64
    ) throws -> RunBrokerSupervisorReplayBatch {
        let directory = try trustedRoot.openExecutionDirectory(identity.executionID)
        if let discovery = try fileSystem.readDiscovery(in: directory) {
            try validate(discovery: discovery, expected: identity, capability: capability)
            var socketStatus = stat()
            let socketPath = directory.path + "/control.sock"
            let socketMissing = lstat(socketPath, &socketStatus) != 0 && errno == ENOENT
            if !socketMissing {
            let request = try RunSupervisorControlAuthentication.makeRequest(
                executionID: identity.executionID,
                action: .init(kind: .replay, afterSequence: sequence),
                capability: capability
            )
            do {
                let response = try client.send(request, directory: directory)
                guard response.accepted else {
                    throw RunBrokerServiceError.supervisorRejected(
                        response.errorCode ?? "unknown"
                    )
                }
                return .init(
                    identity: identity,
                    source: .liveAuthenticated,
                    events: response.events,
                    lastSequence: response.lastSequence
                )
            } catch RunSupervisorError.systemCall(let operation, let code)
                where operation == "connect unix socket"
                    && (code == ECONNREFUSED || code == ENOENT) {
                // A typed inability to connect may race a clean supervisor
                // exit. Only this condition may downgrade to capability-gated
                // offline spool recovery. Auth/schema/tamper errors propagate.
            }
            }
        }

        do {
            let batch = try RunSupervisorOfflineSpoolRecovery.replay(
                directory: directory,
                capability: capability,
                after: sequence
            )
            return .init(
                identity: identity,
                source: .offlineAuthenticatedSpool,
                events: batch.events,
                lastSequence: batch.lastSequence
            )
        } catch RunSupervisorError.alreadyRunningOrInDoubt {
            throw RunBrokerServiceError.supervisorUnavailable
        }
    }

    public func acknowledge(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        source: RunBrokerSupervisorReplaySource,
        through sequence: UInt64
    ) throws {
        let directory = try trustedRoot.openExecutionDirectory(identity.executionID)
        switch source {
        case .liveAuthenticated:
            let request = try RunSupervisorControlAuthentication.makeRequest(
                executionID: identity.executionID,
                action: .init(kind: .acknowledge, acknowledgeThrough: sequence),
                capability: capability
            )
            let response = try client.send(request, directory: directory)
            guard response.accepted else {
                throw RunBrokerServiceError.supervisorRejected(response.errorCode ?? "unknown")
            }
        case .offlineAuthenticatedSpool:
            try RunSupervisorOfflineSpoolRecovery.acknowledge(
                directory: directory,
                capability: capability,
                through: sequence
            )
        }
    }

    public func requestImmediateTermination(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {
        let directory = try trustedRoot.openExecutionDirectory(identity.executionID)
        guard let discovery = try fileSystem.readDiscovery(in: directory) else {
            throw RunBrokerServiceError.supervisorUnavailable
        }
        try validate(discovery: discovery, expected: identity, capability: capability)
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: identity.executionID,
            action: .init(kind: .cancel, cancellationIntent: .immediate),
            capability: capability
        )
        let response = try client.send(request, directory: directory)
        guard response.accepted else {
            throw RunBrokerServiceError.supervisorRejected(response.errorCode ?? "unknown")
        }
    }

    private func validate(
        discovery: RunSupervisorDiscoveryRecord,
        expected identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {
        guard discovery.identity == identity,
              discovery.capabilitySHA256 == (try RunSupervisorDigests.capability(capability)) else {
            throw RunBrokerServiceError.supervisorIdentityMismatch
        }
    }
}
