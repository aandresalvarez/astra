import Foundation
import Darwin

/// A reference to the existing ASTRA launch authority, never another owner.
/// Read again for each start; status and cancellation do not create executions.
public struct RemoteWorkspaceJobOwnerBinding: Codable, Equatable, Sendable {
    public let receiptPath: String
    public let taskID: String
    public let runID: String
    public let ownerID: String
    public let executionID: String

    public init(receiptPath: String, taskID: String, runID: String, ownerID: String, executionID: String) {
        self.receiptPath = receiptPath; self.taskID = taskID; self.runID = runID
        self.ownerID = ownerID; self.executionID = executionID
    }

    public func validateLaunch() throws { _ = try receipt(requireActive: true) }

    public func authorizesHelper(_ pid: Int32, executable: String) -> Bool {
        guard let saved = try? receipt(requireActive: false), let provider = saved.providerProcess, provider.isPresent else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path else { return false }
        var current = pid
        for _ in 0..<32 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return false }
            current = Int32(info.pbi_ppid)
            if current == provider.pid { return true }
        }
        return false
    }

    private func receipt(requireActive: Bool) throws -> Receipt {
        let fd = open(receiptPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteWorkspaceJobError.invalidArgument("The execution owner is unavailable. No remote job was started.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 32768 else { throw blocked }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              let saved = try? JSONDecoder().decode(Receipt.self, from: Data(bytes)),
              saved.taskID.uuidString == UUID(uuidString: taskID)?.uuidString,
              saved.runID?.uuidString == UUID(uuidString: runID)?.uuidString,
              saved.ownerID.uuidString == UUID(uuidString: ownerID)?.uuidString,
              saved.executionID.uuidString == UUID(uuidString: executionID)?.uuidString,
              saved.appProcess.isPresent else { throw blocked }
        if requireActive {
            guard ["working", "waitingForInput"].contains(saved.state),
                  saved.cancellationRequested != true, saved.resourcesReleased != true,
                  saved.providerProcess?.isPresent == true else { throw blocked }
        }
        return saved
    }

    private var blocked: RemoteWorkspaceJobError {
        .invalidArgument("The original execution is no longer admitted or cancellation was requested. Inspect the existing remote job; no new job was started.")
    }

    private struct Receipt: Decodable {
        let taskID: UUID, ownerID: UUID, executionID: UUID
        let runID: UUID?
        let state: String
        let cancellationRequested: Bool?, resourcesReleased: Bool?
        let appProcess: Identity
        let providerProcess: Identity?
    }

    private struct Identity: Decodable {
        let pid: Int32
        let startedSeconds: UInt64, startedMicroseconds: UInt64
        var isPresent: Bool {
            guard pid > 1 else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                && info.pbi_start_tvsec == startedSeconds && info.pbi_start_tvusec == startedMicroseconds
        }
    }
}
