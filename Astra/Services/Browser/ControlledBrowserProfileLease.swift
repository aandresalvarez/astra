import Darwin
import Foundation

/// One controller at a time owns the authenticated Chromium profile, across
/// windows and ASTRA processes. The receipt survives ASTRA so an orphaned
/// browser can reconnect only to its original task, never an imported copy.
final class ControlledBrowserProfileLease: @unchecked Sendable {
    struct Receipt: Codable {
        var owner: String
        var process: RuntimeProcessIdentity?
        var unknownProcessID: Int32?
        var launchPending = false
    }
    enum Failure: LocalizedError {
        case busy, unverified
        var errorDescription: String? {
            switch self {
            case .busy:
                return "Controlled Browser is reserved by another session or is still stopping. Close it from its current task, then retry here. Embedded Browser remains available."
            case .unverified:
                return "ASTRA cannot confirm the previous Controlled Browser stopped. Its profile stays reserved. Return to the original task to check or reconnect the existing session; opening another browser stays blocked until its state can be verified."
            }
        }
    }

    private let descriptor: Int32
    private let receiptURL: URL
    private(set) var receipt: Receipt
    private var retirementStarted = false

    private init(descriptor: Int32, receiptURL: URL, receipt: Receipt) {
        self.descriptor = descriptor
        self.receiptURL = receiptURL
        self.receipt = receipt
    }
    deinit { close(descriptor) }

    static func acquire(profilePath: String, owner: String) throws -> ControlledBrowserProfileLease {
        let root = URL(fileURLWithPath: profilePath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".astra-profile.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.unverified }
        var handedOff = false
        defer { if !handedOff { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw Failure.unverified }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        let url = root.appendingPathComponent(".astra-profile-owner.json")
        var previous: Receipt?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Receipt.self, from: data) else {
                throw Failure.unverified
            }
            previous = decoded
        }
        if let previous, previous.owner != owner, !stopped(previous) { throw Failure.busy }
        let receipt = previous?.owner == owner ? previous! : Receipt(owner: owner)
        let lease = ControlledBrowserProfileLease(descriptor: descriptor, receiptURL: url, receipt: receipt)
        handedOff = true
        try lease.save()
        return lease
    }

    var canStartNewProcess: Bool { Self.stopped(receipt) }

    func beginLaunch() throws {
        guard canStartNewProcess else { throw Failure.unverified }
        var next = receipt
        next.process = nil
        next.unknownProcessID = nil
        next.launchPending = true
        try persist(next)
    }

    func recordProcess(_ pid: Int32) throws {
        guard acceptsExistingProcess(pid) else { throw Failure.unverified }
        var next = receipt
        next.process = RuntimeProcessIdentity.read(pid)
        next.unknownProcessID = next.process == nil ? pid : nil
        next.launchPending = false
        try persist(next)
        guard receipt.process != nil else { throw Failure.unverified }
    }

    /// Process.run failed before creating a child. No elapsed timer is used as
    /// evidence; the caller must own that synchronous launch failure.
    func launchFailedWithoutProcess() throws {
        guard receipt.process == nil, receipt.unknownProcessID == nil else { throw Failure.unverified }
        var next = receipt
        next.launchPending = false
        try persist(next)
    }

    func transfer(to owner: String) throws {
        // Only an explicit idle shared-shelf handoff may transfer this held
        // lease. A different controller must acquire the OS lock normally.
        var next = receipt
        next.owner = owner
        try persist(next)
    }

    func terminateOwnedProcess() {
        guard let process = receipt.process, process.presence == .present else { return }
        _ = kill(process.pid, SIGTERM)
    }

    /// Retains the OS lock after SIGTERM, including unknown process state.
    /// The asynchronous work only observes stop proof for this explicit stop.
    /// A timeout never releases the profile.
    func releaseAfterExit() {
        guard !retirementStarted else { return }
        retirementStarted = true
        let snapshot = receipt
        Task.detached { [self] in
            while !Self.stopped(snapshot) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            withExtendedLifetime(self) {}
        }
    }

    static func stopped(_ receipt: Receipt) -> Bool {
        guard !receipt.launchPending else { return false }
        if let process = receipt.process { return process.presence == .absent }
        if let pid = receipt.unknownProcessID { return kill(pid, 0) == -1 && errno == ESRCH }
        return true
    }

    func acceptsExistingProcess(_ pid: Int32) -> Bool {
        if let previous = receipt.process, previous.presence != .absent {
            return RuntimeProcessIdentity.read(pid) == previous
        }
        if let unknown = receipt.unknownProcessID, !(kill(unknown, 0) == -1 && errno == ESRCH) {
            return unknown == pid
        }
        return true
    }

    private func save() throws { try persist(receipt) }

    private func persist(_ next: Receipt) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: receiptURL, options: .atomic)
        receipt = next
    }
}
