import Foundation
import ASTRACore

public final class RunBrokerServer: @unchecked Sendable {
    private let listener: any RunBrokerListening
    private let endpoint: RunBrokerRequestEndpoint
    private let responseAuthenticator: RunBrokerRequestAuthenticator
    private let wireCodec: RunBrokerWireCodec
    private let now: @Sendable () -> Date
    private let diagnostics: any RunBrokerDiagnosing
    private let connectionSlots: DispatchSemaphore
    private let workerQueue: DispatchQueue

    public init(
        listener: any RunBrokerListening,
        endpoint: RunBrokerRequestEndpoint,
        responseAuthenticator: RunBrokerRequestAuthenticator,
        wireCodec: RunBrokerWireCodec = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics(),
        maximumConcurrentConnections: Int =
            RunBrokerTransportPolicy.defaultMaximumConcurrentConnections,
        workerQueue: DispatchQueue? = nil
    ) {
        precondition(maximumConcurrentConnections > 0)
        self.listener = listener
        self.endpoint = endpoint
        self.responseAuthenticator = responseAuthenticator
        self.wireCodec = wireCodec
        self.now = now
        self.diagnostics = diagnostics
        self.connectionSlots = DispatchSemaphore(value: maximumConcurrentConnections)
        self.workerQueue = workerQueue ?? DispatchQueue(
            label: "com.coral.astra.run-broker.connections",
            qos: .utility,
            attributes: .concurrent
        )
    }

    public func runForever() throws -> Never {
        while true {
            let connection = try listener.accept()
            dispatch(connection)
        }
    }

    public func serveOnce() throws {
        let connection = try listener.accept()
        autoreleasepool { serve(connection) }
    }

    private func dispatch(_ connection: any RunBrokerConnection) {
        guard connectionSlots.wait(timeout: .now()) == .success else {
            diagnostics.record(
                .connectionSaturated,
                error: RunBrokerTransportError.connectionCapacityExhausted
            )
            connection.close()
            return
        }
        workerQueue.async { [self] in
            defer { connectionSlots.signal() }
            autoreleasepool { serve(connection) }
        }
    }

    private func serve(_ connection: any RunBrokerConnection) {
        defer { connection.close() }
        let peer: RunBrokerPeerIdentity
        do {
            peer = try connection.peerIdentity
        } catch {
            diagnostics.record(.peerIdentityReadFailed, error: error)
            return
        }
        let frame: Data
        do {
            guard let received = try connection.receiveFrame(using: wireCodec.frameCodec) else {
                return
            }
            frame = received
        } catch {
            diagnostics.record(.frameReadFailed, error: error)
            return
        }
        let request: RunBrokerRequestEnvelope
        do {
            request = try wireCodec.decodeRequest(frame: frame)
        } catch {
            diagnostics.record(.frameDecodeFailed, error: error)
            return
        }
        let responseBody = endpoint.handle(request, peer: peer, now: now())
        let encoded: Data
        do {
            let response = try responseAuthenticator.authenticatedResponse(
                responseBody,
                for: request
            )
            encoded = try wireCodec.encode(response: response)
        } catch {
            diagnostics.record(.responseEncodeFailed, error: error)
            return
        }
        do {
            try connection.send(frame: encoded)
        } catch {
            diagnostics.record(.responseWriteFailed, error: error)
            return
        }
    }
}

public struct RunBrokerClient: Sendable {
    private let connector: any RunBrokerConnecting
    private let authenticator: RunBrokerRequestAuthenticator
    private let channel: RunBrokerChannel
    private let installationID: RunBrokerInstallationID
    private let wireCodec: RunBrokerWireCodec
    private let now: @Sendable () -> Date

    public init(
        connector: any RunBrokerConnecting,
        authenticator: RunBrokerRequestAuthenticator,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        wireCodec: RunBrokerWireCodec = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connector = connector
        self.authenticator = authenticator
        self.channel = channel
        self.installationID = installationID
        self.wireCodec = wireCodec
        self.now = now
    }

    public func perform(
        _ command: RunBrokerCommand,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID()
    ) throws -> RunBrokerResponseEnvelope {
        let request = try authenticator.authenticatedRequest(
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            channel: channel,
            installationID: installationID,
            command: command,
            now: now()
        )
        let connection = try connector.connect()
        defer { connection.close() }
        try connection.send(frame: wireCodec.encode(request: request))
        guard let responseFrame = try connection.receiveFrame(using: wireCodec.frameCodec) else {
            throw RunBrokerContractError.truncatedFrame
        }
        let authenticatedResponse = try wireCodec.decodeResponse(frame: responseFrame)
        let response = try authenticator.verify(
            authenticatedResponse,
            for: request,
            using: wireCodec
        )
        guard response.requestID == requestID else {
            throw RunBrokerTransportError.responseRequestIDMismatch
        }
        return response
    }
}
