import Darwin
import Foundation
import ASTRACore

/// Serves the file-drop fallback for a single broker session.
///
/// The socket listener next door is the primary transport and stays the
/// preferred one; this exists for providers whose own sandbox denies
/// `connect(2)`. See `HostControlBrokerFileDrop` for what the swap costs and
/// what is left holding the boundary.
///
/// The directory is watched rather than polled, but polled too: a vnode source
/// coalesces events, so two requests landing inside one wakeup can leave the
/// second unnoticed until the next write. The timer is the backstop that turns
/// that from a hang into a delay, and the scan is idempotent — a request is
/// claimed once, by whichever pass reaches it first.
final class HostControlBrokerDropListener: @unchecked Sendable {
    private let token: String
    private let authorize: (Int32) -> Bool
    private let handle: (String) -> String
    private let watchQueue = DispatchQueue(label: "com.coral.astra.host-control-broker.drop-watch")
    private let workQueue = DispatchQueue(
        label: "com.coral.astra.host-control-broker.drop-work",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var directoryDescriptor: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var claimed: Set<String> = []
    private var invalidated = false

    private(set) var directory: String?

    /// Long enough that it is a backstop rather than the mechanism, short
    /// enough that a coalesced event never reads as a hung broker.
    private static let pollInterval: DispatchTimeInterval = .milliseconds(250)

    init(
        token: String,
        authorize: @escaping (Int32) -> Bool,
        handle: @escaping (String) -> String
    ) {
        self.token = token
        self.authorize = authorize
        self.handle = handle
    }

    /// Creates the drop directory and starts watching it. Returns the path, or
    /// `nil` if the fallback could not be prepared — in which case the session
    /// keeps its socket and simply has no fallback, which is what every
    /// provider that can reach the socket already runs with.
    func start(candidateDirectory: String) -> String? {
        guard !token.isEmpty,
              let directory = try? HostControlBrokerFileDrop.validatedDirectory(candidateDirectory)
        else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            return nil
        }

        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            return nil
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: watchQueue
        )
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)

        lock.lock()
        self.directory = directory
        directoryDescriptor = descriptor
        watchSource = source
        pollTimer = timer
        lock.unlock()

        source.setEventHandler { [weak self] in self?.scan() }
        timer.setEventHandler { [weak self] in self?.scan() }
        source.resume()
        timer.resume()
        return directory
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        let source = watchSource
        let timer = pollTimer
        let descriptor = directoryDescriptor
        let directory = self.directory
        watchSource = nil
        pollTimer = nil
        directoryDescriptor = -1
        lock.unlock()

        timer?.cancel()
        source?.cancel()
        if source != nil || timer != nil {
            watchQueue.sync {}
        }
        // The vnode source closes the descriptor through its cancel handler
        // only when one is installed; there is none here, so the close is ours.
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private func scan() {
        lock.lock()
        let directory = self.directory
        let isInvalidated = invalidated
        lock.unlock()
        guard let directory, !isInvalidated else { return }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names {
            guard let id = HostControlBrokerFileDrop.requestID(fromFileName: name) else { continue }
            lock.lock()
            let alreadyClaimed = invalidated || claimed.contains(id)
            if !alreadyClaimed {
                claimed.insert(id)
            }
            lock.unlock()
            guard !alreadyClaimed else { continue }
            workQueue.async { [weak self] in
                self?.serve(id: id, directory: directory)
            }
        }
    }

    private func serve(id: String, directory: String) {
        let requestURL = HostControlBrokerFileDrop.requestURL(directory: directory, id: id)
        let payload = readRequest(at: requestURL)
        // Claimed means consumed. Removing before the work starts keeps the
        // token's life on disk as short as it can be, and means a crash mid-call
        // cannot leave a request to be served twice.
        try? FileManager.default.removeItem(at: requestURL)
        guard let payload,
              HostControlBrokerFileDrop.tokensMatch(payload.token, token) else {
            // No reply. A writer that does not hold this run's token learns
            // nothing from us, not even that the file was read.
            return
        }
        guard authorize(payload.processID) else {
            // The token was right and the caller was not. That is worth saying:
            // it is a real helper on a real run, and the alternative is a
            // five-minute wait for a timeout that explains nothing.
            respond(
                id: id,
                directory: directory,
                line: Self.errorLine(
                    requestLine: payload.line,
                    message: "ASTRA host-control broker rejected a request from an unrecognized process."
                )
            )
            return
        }
        respond(id: id, directory: directory, line: handle(payload.line))
    }

    private func readRequest(at url: URL) -> HostControlBrokerFileDrop.Request? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= HostControlBrokerFileDrop.maximumMessageBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HostControlBrokerFileDrop.Request.self, from: data)
    }

    private func respond(id: String, directory: String, line: String) {
        guard !line.isEmpty,
              let data = try? JSONEncoder().encode(
                  HostControlBrokerFileDrop.Response(token: token, line: line)
              )
        else {
            return
        }
        try? HostControlBrokerFileDrop.writeAtomically(
            data,
            to: HostControlBrokerFileDrop.responseURL(directory: directory, id: id)
        )
    }

    private static func errorLine(requestLine: String, message: String) -> String {
        let requestID: Any = {
            guard let data = requestLine.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return NSNull()
            }
            return request["id"] ?? NSNull()
        }()
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "error": ["code": -32000, "message": message]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"ASTRA host-control broker rejected the request."}}"#
        }
        return line
    }
}
