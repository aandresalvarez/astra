import Darwin
import Foundation
import Testing
@testable import ASTRA

@Suite("Execution Sandbox Host Control")
struct ExecutionSandboxHostControlTests {
    @Test("Offline profile re-allows only the run-scoped host-control socket")
    func offlineProfileAllowsHostControlSocket() {
        let profile = ExecutionSandbox.makeProfile(
            writableRootCount: 1,
            hostControlBrokerSocketCount: 1,
            allowNetwork: false
        )
        let arguments = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: ["/private/tmp"],
            hostControlBrokerSockets: ["/private/tmp/astra-host-control-test.sock"],
            executablePath: "/usr/bin/true",
            arguments: []
        )

        #expect(profile.contains("(deny network*)"))
        #expect(profile.contains(
            "(allow network-outbound (literal (param \"HOST_CONTROL_BROKER_SOCKET_0\")))"
        ))
        #expect(arguments.contains(
            "HOST_CONTROL_BROKER_SOCKET_0=/private/tmp/astra-host-control-test.sock"
        ))
    }

    @Test("Offline profile permits its exact host-control Unix socket")
    func seatbeltOfflineProfilePermitsHostControlSocket() throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath),
              fileManager.isExecutableFile(atPath: "/usr/bin/nc"),
              let listener = makeUnixListener() else {
            return
        }
        defer {
            close(listener.fd)
            unlink(listener.path)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = accept(listener.fd, nil, nil)
            if connection >= 0 {
                close(connection)
            }
        }
        let canonicalPath = try #require(ExecutionSandbox.canonicalize(listener.path))
        let command = "/usr/bin/nc -U '\(canonicalPath)' </dev/null"

        let blockedProfile = ExecutionSandbox.makeProfile(
            writableRootCount: 1,
            allowNetwork: false
        )
        #expect(runConfined(
            profile: blockedProfile,
            writableRoots: ["/private/tmp"],
            script: command
        ) != 0)

        let brokerProfile = ExecutionSandbox.makeProfile(
            writableRootCount: 1,
            hostControlBrokerSocketCount: 1,
            allowNetwork: false
        )
        #expect(runConfined(
            profile: brokerProfile,
            writableRoots: ["/private/tmp"],
            hostControlBrokerSockets: [canonicalPath],
            script: command
        ) == 0)
    }

    private func runConfined(
        profile: String,
        writableRoots: [String],
        hostControlBrokerSockets: [String] = [],
        script: String
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
        process.arguments = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: writableRoots,
            hostControlBrokerSockets: hostControlBrokerSockets,
            executablePath: "/bin/sh",
            arguments: ["-c", script]
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Issue.record("Failed to launch sandbox-exec: \(error)")
            return -1
        }
    }

    private func makeUnixListener() -> (fd: Int32, path: String)? {
        let path = "/tmp/astra-sandbox-\(UUID().uuidString.lowercased()).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        return (fd, path)
    }
}
