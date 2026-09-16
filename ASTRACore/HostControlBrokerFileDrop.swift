import Foundation
import Security

/// The file-drop fallback for the typed `astra-host-control` relay.
///
/// The relay's real transport is the unix socket in `HostControlBrokerIPC`, and
/// it stays the real transport wherever it works: a socket peer has a PID, so
/// the broker can check both that the caller is the helper binary it shipped
/// and that the caller descends from this run's provider process. A file has no
/// peer. Nothing here is an improvement on that, and nothing here replaces it.
///
/// It exists because a provider that launches its own sandbox cannot reach the
/// socket at all. Codex's `workspace-write` seatbelt denies `connect(2)` on an
/// `AF_UNIX` socket with EPERM even when the socket sits inside a writable root
/// — measured, not assumed: under `sandbox: workspace-write [workdir, /tmp,
/// $TMPDIR]` a connect to a socket in `/tmp` fails while `mkdir`, `write`, and
/// `rename` in the same directory all succeed. So a sandboxed run that reaches
/// for `astra-host-control jira` gets "broker is unavailable" and the connector
/// turn fails without a single request leaving ASTRA.
///
/// Ordinary file writes are permitted in exactly the place the socket already
/// lived. So the fallback carries the identical line-delimited JSON-RPC through
/// a request file and a response file in a directory ASTRA creates, owns, and
/// deletes — `/tmp/astra-host-control-<uuid>/`, mode `0700`, the same location
/// and the same permissions the socket had.
///
/// ## What is lost, and what is left
///
/// Lost: `LOCAL_PEERPID`. The kernel no longer tells the broker who is calling.
///
/// Left, in descending order of how much they are worth:
///
/// - **Directory permissions and an unguessable path.** Identical to the
///   socket's. This is the whole of the filesystem trust boundary, and the
///   fallback does not move it.
/// - **A per-run token.** ASTRA generates it, hands it to the helper in the
///   environment, and never writes it to disk; a request without it is dropped.
///   It proves the writer had this run's environment, which is the nearest
///   available statement of the ancestry the socket could prove outright. Its
///   weakness is honest: it is echoed into each request file, so anything that
///   can *read* the drop directory can learn it — but anything that can read
///   the drop directory can already read the responses, which is the thing
///   worth stealing. The token defends against a blind writer, not a reader,
///   and the broker deletes each request the moment it claims it.
/// - **A self-declared PID.** The helper states its own, and the broker runs
///   the same executable and ancestry checks the socket ran. A forger can lie,
///   but only by naming a PID that is at that instant a live helper descending
///   from this run's provider — so the check still costs an attacker the
///   arrangement it was written to demand, and it can only ever reject.
public enum HostControlBrokerFileDrop {
    /// Directory the helper writes requests into. Absent means no fallback was
    /// prepared for this run, which is the ordinary case for every provider
    /// that can reach the socket.
    public static let directoryEnvironmentKey = "ASTRA_HOST_CONTROL_BROKER_DROP"
    public static let tokenEnvironmentKey = "ASTRA_HOST_CONTROL_BROKER_DROP_TOKEN"

    public static let requestSuffix = ".request.json"
    public static let responseSuffix = ".response.json"
    /// Both sides write here first and rename into place. A reader that opens a
    /// half-written request sees malformed JSON and drops a request the helper
    /// is still waiting on, so neither name is ever published unfinished.
    public static let stagingSuffix = ".partial"

    public static let maximumMessageBytes = 1_048_576

    /// Matches the socket client's receive timeout. A brokered call that runs
    /// long (a REDCap export, a slow Jira JQL) must not fail differently just
    /// because it arrived over a different transport.
    public static let requestTimeout: TimeInterval = 305

    public struct Request: Codable, Equatable, Sendable {
        public var token: String
        public var processID: Int32
        public var line: String

        public init(token: String, processID: Int32, line: String) {
            self.token = token
            self.processID = processID
            self.line = line
        }

        private enum CodingKeys: String, CodingKey {
            case token
            case processID = "pid"
            case line
        }
    }

    /// The token travels back as well as out. A socket client cannot be
    /// answered by anyone but the process holding the listening end, and the
    /// drop has no equivalent — a file is a file whoever wrote it. Echoing the
    /// token means spoofing a reply, and so feeding the agent invented connector
    /// data, first requires *reading* the drop directory, which is a strictly
    /// higher bar than writing to it.
    public struct Response: Codable, Equatable, Sendable {
        public var token: String
        public var line: String

        public init(token: String, line: String) {
            self.token = token
            self.line = line
        }
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // A token nobody can predict is the point, so a failed draw must not
            // fall back to something weaker. The caller treats an empty token as
            // "no fallback available" and the run keeps the socket-only routes.
            return ""
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func newRequestID() -> String {
        UUID().uuidString.lowercased()
    }

    public static func validatedDirectory(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.split(separator: "/").contains("..") else {
            throw HostControlBrokerFileDropError.invalidDirectory
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func requestURL(directory: String, id: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(id + requestSuffix)
    }

    public static func responseURL(directory: String, id: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(id + responseSuffix)
    }

    /// The request ID a published file belongs to, or `nil` for anything else in
    /// the directory — staging files, responses, and whatever a stray writer
    /// leaves behind.
    public static func requestID(fromFileName name: String) -> String? {
        guard name.hasSuffix(requestSuffix) else { return nil }
        let id = String(name.dropLast(requestSuffix.count))
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return id
    }

    /// Writes through a staging name in the same directory, so a reader only
    /// ever opens a complete file. `0600` because the request carries the run's
    /// token and the response carries connector data.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + stagingSuffix)
        try data.write(to: staging, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: staging.path
        )
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: staging, to: url)
    }

    /// Constant-time so a token cannot be recovered a byte at a time by timing
    /// rejected requests. The drop directory is not reachable at that volume,
    /// but the comparison costs nothing and the alternative has to be argued.
    public static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard !left.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

/// The file-drop client: write one request, wait for the matching response.
///
/// The poll starts tight and backs off, because the common case is a local
/// answer in single-digit milliseconds and the uncommon one is a Jira query
/// that takes a minute. The timeout matches the socket's receive timeout so a
/// slow brokered call does not fail differently for having taken this route.
public enum HostControlBrokerFileDropClient {
    private static let initialPollMicroseconds: UInt32 = 2_000
    private static let maximumPollMicroseconds: UInt32 = 100_000

    public static func exchange(
        _ line: String,
        directory: String,
        token: String,
        timeout: TimeInterval = HostControlBrokerFileDrop.requestTimeout
    ) throws -> String {
        let root = try HostControlBrokerFileDrop.validatedDirectory(directory)
        let id = HostControlBrokerFileDrop.newRequestID()
        let requestURL = HostControlBrokerFileDrop.requestURL(directory: root, id: id)
        let responseURL = HostControlBrokerFileDrop.responseURL(directory: root, id: id)

        let payload = HostControlBrokerFileDrop.Request(
            token: token,
            processID: getpid(),
            line: line
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw HostControlBrokerFileDropError.unavailable
        }
        guard data.count <= HostControlBrokerFileDrop.maximumMessageBytes else {
            throw HostControlBrokerFileDropError.replyTooLarge
        }
        do {
            try HostControlBrokerFileDrop.writeAtomically(data, to: requestURL)
        } catch {
            throw HostControlBrokerFileDropError.unavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        var interval = initialPollMicroseconds
        while Date() < deadline {
            if let response = readResponse(at: responseURL, token: token) {
                try? FileManager.default.removeItem(at: responseURL)
                return response
            }
            usleep(interval)
            interval = min(interval &* 2, maximumPollMicroseconds)
        }
        // Nothing is coming. Leaving the request behind would let a broker that
        // is merely slow answer into a directory nobody is reading any more.
        try? FileManager.default.removeItem(at: requestURL)
        throw HostControlBrokerFileDropError.timedOut
    }

    private static func readResponse(at url: URL, token: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              data.count <= HostControlBrokerFileDrop.maximumMessageBytes,
              let response = try? JSONDecoder().decode(
                  HostControlBrokerFileDrop.Response.self,
                  from: data
              ),
              HostControlBrokerFileDrop.tokensMatch(response.token, token) else {
            return nil
        }
        return response.line
    }
}

public enum HostControlBrokerFileDropError: LocalizedError, Equatable, Sendable {
    case invalidDirectory
    case unavailable
    case timedOut
    case replyTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "ASTRA host-control broker drop directory is invalid."
        case .unavailable:
            "ASTRA host-control broker is unavailable."
        case .timedOut:
            "ASTRA host-control broker timed out."
        case .replyTooLarge:
            "ASTRA host-control broker reply exceeded its size limit."
        }
    }
}
