import Darwin
import Foundation

/// Local cleanup is a fact about this machine, not about what a transcript
/// said: a folder here can only be changed by a process here. Once the
/// provider is reaped and its process group is empty, the kernel's process
/// table says whether anything that launch started is still alive.
///
/// Two public facts tie a process to a launch:
/// - Every launch carries one scope value in its environment. Descendants keep
///   it across `setsid`, `nohup` and reparenting.
/// - The kernel hides the environment of system binaries (`sh`, `perl`,
///   `ssh`). For those, and for anything that cleared its environment: an
///   orphan (its parent is launchd) that started while the provider ran and
///   still has its working directory inside the launch's folder.
///
/// This is an observation, recorded with the proof it informs. Its limits:
/// work handed to another service (launchd, a container runtime, a remote
/// host), and a hidden-environment orphan that left the folder. Remote and
/// container work stay fenced by their own evidence, and the caller does not
/// observe where those are possible.
struct RuntimeLocalSurvivorObservation: Codable, Equatable, Sendable {
    /// What a later observation needs to ask the same question again.
    struct Launch: Codable, Equatable, Sendable {
        let scope: String
        /// Resolved working directory of the provider.
        let root: String
        let provider: RuntimeProcessIdentity
        /// When the provider was first observed gone; closes the start window.
        let ended: Date
    }

    struct Survivor: Codable, Equatable, Sendable {
        let process: RuntimeProcessIdentity
        let name: String
    }

    let launch: Launch
    let observedAt: Date
    /// False when the process table could not be read. Never treated as clean.
    let complete: Bool
    let survivors: [Survivor]

    var clean: Bool { complete && survivors.isEmpty }
}

enum RuntimeExecutionLocalSurvivors {
    /// Avoids KEY/SECRET/TOKEN, which provider shells drop by default.
    static let environmentKey = "ASTRA_EXECUTION_SCOPE"
    static let reportLimit = 8

    static func resolved(_ directory: String) -> String {
        guard let path = realpath(directory, nil) else { return directory }
        defer { free(path) }
        return String(cString: path)
    }

    static func observe(_ launch: RuntimeLocalSurvivorObservation.Launch, now: Date = Date()) -> RuntimeLocalSurvivorObservation {
        let incomplete = RuntimeLocalSurvivorObservation(launch: launch, observedAt: now, complete: false, survivors: [])
        guard UUID(uuidString: launch.scope) != nil, launch.root.hasPrefix("/") else { return incomplete }
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return incomplete }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return incomplete }
        var argumentLimit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitName = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitName, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else { return incomplete }
        let entry = Array("\(environmentKey)=\(launch.scope)".utf8)
        var buffer = [UInt8](repeating: 0, count: Int(argumentLimit))
        let user = getuid()
        var survivors: [RuntimeLocalSurvivorObservation.Survivor] = []
        for pid in pids.prefix(Int(count)) where pid > 1 {
            // Another user's process did not inherit from this launch. A
            // zombie has no arguments or directory left, and cannot write.
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_uid == user else { continue }
            let identity = RuntimeProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
            guard identity != launch.provider else { continue }
            var name = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            let scoped = sysctl(&name, 3, &buffer, &size, nil, 0) == 0 && carries(entry, in: buffer, count: size)
            guard scoped || (info.pbi_ppid == 1 && started(identity, during: launch) && isInside(launch.root, pid)) else { continue }
            survivors.append(.init(process: identity, name: processName(info)))
        }
        return .init(launch: launch, observedAt: now, complete: true,
                     survivors: Array(survivors.sorted { $0.process.pid < $1.process.pid }.prefix(reportLimit)))
    }

    /// A provider's own helpers (MCP servers, a shell winding down) can take a
    /// moment to exit after it does. Counted polls, never a wall-clock budget.
    static func observeSettled(_ launch: RuntimeLocalSurvivorObservation.Launch, polls: Int = 10,
                               pause: useconds_t = 50_000) -> RuntimeLocalSurvivorObservation {
        var observation = observe(launch)
        var remaining = polls
        while remaining > 0, observation.complete, !observation.survivors.isEmpty {
            usleep(pause)
            observation = observe(launch)
            remaining -= 1
        }
        return observation
    }

    private static func started(_ process: RuntimeProcessIdentity, during launch: RuntimeLocalSurvivorObservation.Launch) -> Bool {
        let start = (process.startedSeconds, process.startedMicroseconds)
        guard start >= (launch.provider.startedSeconds, launch.provider.startedMicroseconds) else { return false }
        return Double(process.startedSeconds) + Double(process.startedMicroseconds) / 1_000_000 <= launch.ended.timeIntervalSince1970
    }

    private static func isInside(_ root: String, _ pid: pid_t) -> Bool {
        var paths = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return false }
        let directory = withUnsafePointer(to: &paths.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return directory == root || directory.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Environment entries are NUL-terminated strings after the argument
    /// vector; require the whole entry, not a mention of it inside another.
    private static func carries(_ entry: [UInt8], in buffer: [UInt8], count: Int) -> Bool {
        guard count > entry.count else { return false }
        return buffer.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset + entry.count <= count,
                  let match = memmem(base + offset, count - offset, entry, entry.count) {
                let start = base.distance(to: UnsafeRawPointer(match))
                let end = start + entry.count
                if start > 0 && bytes[start - 1] == 0 && (end == count || bytes[end] == 0) { return true }
                offset = start + 1
            }
            return false
        }
    }

    /// The executable's short name, for a log line, a receipt and the waiting
    /// message. Identifier characters only: a process can set its own name.
    private static func processName(_ info: proc_bsdinfo) -> String {
        var field = info.pbi_name
        let capacity = MemoryLayout.size(ofValue: field)
        let raw = withUnsafePointer(to: &field) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        let name = raw.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
        }
        return name.isEmpty ? "unknown" : String(String.UnicodeScalarView(name.prefix(32)))
    }
}
