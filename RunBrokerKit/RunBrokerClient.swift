import ASTRACore
import Foundation

/// Authority-free local IPC client. This target depends only on ASTRACore and
/// cannot import the ledger, broker policy, service, or process authority.
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
        if case .application(let command) = command,
           let result = response.result {
            guard case .application(let applicationResponse) = result else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
            try applicationResponse.validate(for: command)
        }
        return response
    }
}
