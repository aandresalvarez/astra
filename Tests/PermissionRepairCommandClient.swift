import Darwin
import Foundation

/// Test-only client. The parent script, not Swift Testing's cooperative workers,
/// launches and reaps real chmod/chflags/repair-shell commands.
enum PermissionRepairCommandClient {
    struct Result: Decodable {
        let executorPID: Int?
        let exitCode: Int
        let stdout: String?
        let stderr: String?
    }

    enum Failure: Error {
        case unavailable(String)
        case transport(Int32)
        case invalidResponse
    }

    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result {
        guard let path = environment["ASTRA_PERMISSION_TEST_SOCKET"], !path.isEmpty else {
            throw Failure.unavailable("Run script/swift_test.sh: real permission repair requires its isolated harness.")
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalidResponse }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.transport(errno) }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw Failure.transport(errno)
        }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw Failure.transport(errno)
            }
        }
        let addressLength = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, addressLength) }
        }
        guard connected == 0 else { throw Failure.transport(errno) }
        var request = try JSONSerialization.data(withJSONObject: ["executable": executable, "arguments": arguments])
        request.append(10)
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.transport(errno) }
                offset += count
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(10) {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.transport(errno) }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 65536 else { throw Failure.invalidResponse }
        }
        return try JSONDecoder().decode(Result.self, from: response.prefix(while: { $0 != 10 }))
    }
}
