import Foundation
import ASTRACore
@_exported import RunBrokerClient

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
