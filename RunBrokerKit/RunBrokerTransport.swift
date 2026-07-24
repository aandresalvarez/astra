import Foundation

public enum RunBrokerTransportError: Error, Equatable, Sendable {
    case socketPathTooLong
    case unsafeSocketPath
    case socketAlreadyActive
    case peerIdentityUnavailable
    case responseRequestIDMismatch
    case connectionCapacityExhausted
    case systemCall(operation: String, code: Int32)
}

public enum RunBrokerTransportPolicy {
    public static let defaultMaximumConcurrentConnections = 16
    public static let defaultIOTimeout: TimeInterval = 5
}

public protocol RunBrokerConnection: AnyObject, Sendable {
    var peerIdentity: RunBrokerPeerIdentity { get throws }
    func send(frame: Data) throws
    func receiveFrame(using codec: RunBrokerFrameCodec) throws -> Data?
    func close()
}

public protocol RunBrokerConnecting: Sendable {
    func connect() throws -> any RunBrokerConnection
}

public protocol RunBrokerListening: Sendable {
    func accept() throws -> any RunBrokerConnection
}
