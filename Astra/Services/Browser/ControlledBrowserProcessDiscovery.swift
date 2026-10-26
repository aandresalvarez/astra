import Darwin
import Foundation

/// Reconnect only to an exact Chromium argv. `ps` flattens spaces and cannot
/// distinguish a profile from a similarly named sibling or child directory.
enum ControlledBrowserProcessDiscovery {
    static func find(profilePath: String) throws -> ControlledBrowserDebugTarget? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { throw ControlledBrowserProfileLease.Failure.unverified }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < capacity else { throw ControlledBrowserProfileLease.Failure.unverified }
        let allowedExecutables = Set(ControlledBrowserCandidate.defaultCandidates.map(\.executablePath)
            + [ControlledBrowserCandidate.firstAvailable()?.executablePath].compactMap { $0 })
        let matches = pids.prefix(min(Int(count), capacity)).compactMap { pid -> ControlledBrowserDebugTarget? in
            guard let argv = arguments(pid: pid) else { return nil }
            return target(pid: pid, arguments: argv, profilePath: profilePath, allowedExecutables: allowedExecutables)
        }
        return try select(matches)
    }

    static func select(_ matches: [ControlledBrowserDebugTarget]) throws -> ControlledBrowserDebugTarget? {
        // Multiple roots are uncertain; never choose an arbitrary browser.
        guard matches.count <= 1 else { throw ControlledBrowserProfileLease.Failure.unverified }
        return matches.first
    }

    static func target(pid: pid_t, arguments: [String], profilePath: String,
                       allowedExecutables: Set<String> = Set(ControlledBrowserCandidate.defaultCandidates.map(\.executablePath))) -> ControlledBrowserDebugTarget? {
        guard let executable = arguments.first,
              allowedExecutables.contains(executable),
              !arguments.contains(where: { $0.hasPrefix("--type=") }),
              arguments.filter({ $0.hasPrefix("--user-data-dir=") }) == ["--user-data-dir=\(profilePath)"] else { return nil }
        let ports = arguments.filter { $0.hasPrefix("--remote-debugging-port=") }
        guard ports.count == 1, let port = UInt16(ports[0].dropFirst("--remote-debugging-port=".count)), port > 0 else { return nil }
        return ControlledBrowserDebugTarget(processID: pid, debugPort: port)
    }

    private static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size,
              size <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return decodeArguments(Array(bytes.prefix(size)))
    }

    static func decodeArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 32_768 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        // Kernel executable path, then padding, precede argv[0].
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            argv.append(value)
            cursor = end + 1
        }
        return argv // Environment bytes are deliberately never decoded.
    }
}
