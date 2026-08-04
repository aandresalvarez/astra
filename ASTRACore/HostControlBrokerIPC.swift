import Foundation

public enum HostControlBrokerIPC {
    public static let endpointEnvironmentKey = "ASTRA_HOST_CONTROL_BROKER_SOCKET"

    public static func validatedSocketPath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count < 104 else {
            throw HostControlBrokerIPCError.invalidEndpoint
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public enum HostControlBrokerIPCError: LocalizedError {
    case invalidEndpoint

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "ASTRA host-control broker socket is invalid."
        }
    }
}
