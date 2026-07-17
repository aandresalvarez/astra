import ASTRACore
import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor process lifecycle", .serialized)
struct RunSupervisorExecutableIntegrationTests {
    @Test("broker SIGKILL does not interrupt a detached run and the broker can reconnect, replay, and cancel")
    func brokerDeathDoesNotOwnRunLifetime() throws {
        let fixture = try integrationFixture("brokerkill")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let payload = try longRunningPayload(rootURL: fixture.rootURL, identitySeed: 140)
        let broker = try launchBroker(payload: payload, rootURL: fixture.rootURL, holdAfterLaunch: true)
        var providerPID: pid_t = -1
        var descendantPID: pid_t = -1
        defer {
            terminateForCleanup(broker.process)
            terminateForCleanup(pid: broker.supervisorPID)
            terminateForCleanup(pid: providerPID)
            terminateForCleanup(pid: descendantPID)
        }

        #expect(broker.process.isRunning)
        #expect(kill(broker.process.processIdentifier, SIGKILL) == 0)
        broker.process.waitUntilExit()
        #expect(broker.process.terminationReason == .uncaughtSignal)
        #expect(broker.process.terminationStatus == SIGKILL)

        let connected = try waitForAuthenticatedRun(payload: payload, root: fixture.root)
        #expect(RunSupervisorTestSupport.isAlive(broker.supervisorPID))
        let providerPIDURL = fixture.rootURL.appendingPathComponent("provider.pid")
        let descendantPIDURL = fixture.rootURL.appendingPathComponent("descendant.pid")
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 5) {
            providerPID = (try? RunSupervisorTestSupport.readPID(providerPIDURL)) ?? -1
            descendantPID = (try? RunSupervisorTestSupport.readPID(descendantPIDURL)) ?? -1
            return RunSupervisorTestSupport.isAlive(providerPID)
                && RunSupervisorTestSupport.isAlive(descendantPID)
        })

        let status = try send(
            .init(kind: .status),
            payload: payload,
            directory: connected.directory
        )
        #expect(status.accepted)
        var liveEvents: [RunSupervisorEvent] = []
        let outputObserved = RunSupervisorTestSupport.waitUntil(timeout: 5) {
            liveEvents = (try? replayAll(payload: payload, directory: connected.directory)) ?? []
            return liveEvents.filter { $0.kind == .standardOutput }
                .compactMap(\.payload.data)
                .contains { String(decoding: $0, as: UTF8.self).contains("provider-online") }
        }
        #expect(outputObserved, "event kinds: \(liveEvents.map(\.kind))")
        #expect(liveEvents.contains { $0.kind == .supervisorReady })
        #expect(liveEvents.contains { $0.kind == .providerStarted })

        let cancellation = try send(
            .init(kind: .cancel, cancellationIntent: .immediate),
            payload: payload,
            directory: connected.directory
        )
        #expect(cancellation.accepted)
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 8) {
            !RunSupervisorTestSupport.isAlive(providerPID)
                && !RunSupervisorTestSupport.isAlive(descendantPID)
                && !RunSupervisorTestSupport.isAlive(broker.supervisorPID)
        })

        let spool = try RunSupervisorEventSpool(
            directory: connected.directory,
            capability: payload.capability
        )
        let finalEvents = try spool.replay(after: 0)
        #expect(finalEvents.contains { $0.kind == .terminationStarted })
        #expect(finalEvents.contains { $0.kind == .cancellationConfirmed })
        #expect(finalEvents.contains { $0.kind == .providerExited })
    }

    @Test("supervisor SIGKILL closes the lifetime channel and kills a TERM-resistant provider tree")
    func supervisorDeathKillsProviderTree() throws {
        let fixture = try integrationFixture("supkill")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let payload = try longRunningPayload(rootURL: fixture.rootURL, identitySeed: 150)
        let broker = try launchBroker(payload: payload, rootURL: fixture.rootURL, holdAfterLaunch: false)
        var providerPID: pid_t = -1
        var descendantPID: pid_t = -1
        defer {
            terminateForCleanup(broker.process)
            terminateForCleanup(pid: broker.supervisorPID)
            terminateForCleanup(pid: providerPID)
            terminateForCleanup(pid: descendantPID)
        }

        broker.process.waitUntilExit()
        #expect(broker.process.terminationReason == .exit)
        #expect(broker.process.terminationStatus == 0)
        _ = try waitForAuthenticatedRun(payload: payload, root: fixture.root)
        let providerPIDURL = fixture.rootURL.appendingPathComponent("provider.pid")
        let descendantPIDURL = fixture.rootURL.appendingPathComponent("descendant.pid")
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 5) {
            providerPID = (try? RunSupervisorTestSupport.readPID(providerPIDURL)) ?? -1
            descendantPID = (try? RunSupervisorTestSupport.readPID(descendantPIDURL)) ?? -1
            return RunSupervisorTestSupport.isAlive(providerPID)
                && RunSupervisorTestSupport.isAlive(descendantPID)
        })

        #expect(kill(broker.supervisorPID, SIGKILL) == 0)
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 8) {
            !RunSupervisorTestSupport.isAlive(providerPID)
                && !RunSupervisorTestSupport.isAlive(descendantPID)
                && !RunSupervisorTestSupport.isAlive(broker.supervisorPID)
        })
    }

    @Test("terminal truth is capability-gated and recoverable offline after broker and supervisor exit")
    func boundedOfflineTerminalRecoveryAfterBrokerDeath() throws {
        let fixture = try integrationFixture("offlinerecover")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let ready = fixture.rootURL.appendingPathComponent("short-provider.ready")
        let release = fixture.rootURL.appendingPathComponent("short-provider.release")
        let script = """
        root="$1"
        : > "$root/short-provider.ready"
        while [ ! -f "$root/short-provider.release" ]; do /bin/sleep 0.05; done
        printf 'offline-terminal-output\n'
        exit 7
        """
        let payload = try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "provider", fixture.rootURL.path],
            workingDirectory: fixture.rootURL.path,
            identitySeed: 160
        )
        let broker = try launchBroker(payload: payload, rootURL: fixture.rootURL, holdAfterLaunch: true)
        defer {
            terminateForCleanup(broker.process)
            terminateForCleanup(pid: broker.supervisorPID)
        }
        let connected = try waitForAuthenticatedRun(payload: payload, root: fixture.root)
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: ready.path)
        })

        #expect(kill(broker.process.processIdentifier, SIGKILL) == 0)
        broker.process.waitUntilExit()
        #expect(!broker.process.isRunning)
        try Data().write(to: release)
        let socketPath = URL(fileURLWithPath: connected.directory.path)
            .appendingPathComponent("control.sock").path
        #expect(RunSupervisorTestSupport.waitUntil(timeout: 8) {
            var status = stat()
            return !RunSupervisorTestSupport.isAlive(broker.supervisorPID)
                && lstat(socketPath, &status) != 0
                && errno == ENOENT
        })

        let wrongCapability = try RunSupervisorCapability(bytes: Data(repeating: 0xE7, count: 32))
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorOfflineSpoolRecovery.replay(
                directory: connected.directory,
                capability: wrongCapability,
                after: 0,
                limit: 1
            )
        }

        var recovered: [RunSupervisorEvent] = []
        while true {
            let batch = try RunSupervisorOfflineSpoolRecovery.replay(
                directory: connected.directory,
                capability: payload.capability,
                after: 0,
                limit: 1
            )
            guard let event = batch.events.first else { break }
            recovered.append(event)
            try RunSupervisorOfflineSpoolRecovery.acknowledge(
                directory: connected.directory,
                capability: payload.capability,
                through: event.sequence
            )
            #expect(recovered.count <= 16)
        }
        #expect(Set(recovered.map(\.sequence)).count == recovered.count)
        #expect(recovered.contains { event in
            event.kind == .standardOutput
                && event.payload.data.map {
                    String(decoding: $0, as: UTF8.self).contains("offline-terminal-output")
                } == true
        })
        #expect(recovered.contains { event in
            event.kind == .providerExited
                && event.payload.exitCode == 7
                && event.payload.terminationReason == .exited
        })
        #expect(try RunSupervisorOfflineSpoolRecovery.replay(
            directory: connected.directory,
            capability: payload.capability,
            after: 0,
            limit: 1
        ).events.isEmpty)
    }

    private func integrationFixture(_ suffix: String) throws -> (
        rootURL: URL,
        root: RunSupervisorTrustedRoot
    ) {
        let rootURL = try RunSupervisorTestSupport.temporaryDirectory(suffix)
        return (rootURL, try RunSupervisorTrustedRoot(path: rootURL.path))
    }

    private func longRunningPayload(
        rootURL: URL,
        identitySeed: UInt8
    ) throws -> RunSupervisorBootstrapPayload {
        let script = """
        root="$1"
        trap '' TERM HUP INT
        printf '%s\n' "$$" > "$root/provider.pid"
        /bin/sh -c 'trap "" TERM HUP INT; printf "%s\\n" "$$" > "$1"; while :; do /bin/sleep 1; done' descendant "$root/descendant.pid" &
        printf 'provider-online\n'
        while :; do /bin/sleep 1; done
        """
        return try RunSupervisorTestSupport.payload(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "provider", rootURL.path],
            workingDirectory: rootURL.path,
            identitySeed: identitySeed
        )
    }

    private func launchBroker(
        payload: RunSupervisorBootstrapPayload,
        rootURL: URL,
        holdAfterLaunch: Bool
    ) throws -> (process: Process, supervisorPID: pid_t) {
        let brokerURL = try executable(named: "astra-run-supervisor-broker-harness")
        let supervisorURL = try executable(named: "astra-run-supervisor")
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = brokerURL
        process.arguments = [rootURL.path, supervisorURL.path]
            + (holdAfterLaunch ? ["--hold-after-launch"] : [])
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        do {
            let encoded = try RunSupervisorWireCoding.encode(payload)
            try RunSupervisorFrameIO.writeFrame(
                encoded,
                to: standardInput.fileHandleForWriting.fileDescriptor,
                maximumBytes: RunSupervisorProtocol.maximumBootstrapBytes
            )
            standardInput.fileHandleForWriting.closeFile()
            let line = try readLine(
                from: standardOutput.fileHandleForReading.fileDescriptor,
                timeout: 5
            )
            guard let supervisorPID = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  supervisorPID > 0 else {
                throw RunSupervisorError.invalidSchema
            }
            return (process, supervisorPID)
        } catch {
            terminateForCleanup(process)
            throw error
        }
    }

    private func executable(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw RunSupervisorError.systemCall("missing test executable \(name)", ENOENT)
        }
        return url
    }

    private func readLine(from descriptor: Int32, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while Date() < deadline, data.count < 128 {
            var candidate = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let result = poll(&candidate, 1, remaining)
            if result < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("poll broker output", errno)
            }
            guard result > 0 else { break }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("read broker output", errno)
            }
            guard count == 1 else { break }
            data.append(byte)
            if byte == UInt8(ascii: "\n") { return String(decoding: data, as: UTF8.self) }
        }
        throw RunSupervisorError.truncatedFrame
    }

    private func waitForAuthenticatedRun(
        payload: RunSupervisorBootstrapPayload,
        root: RunSupervisorTrustedRoot
    ) throws -> (directory: RunSupervisorRunDirectory, discovery: RunSupervisorDiscoveryRecord) {
        var directory: RunSupervisorRunDirectory?
        var discovery: RunSupervisorDiscoveryRecord?
        let fileSystem = DarwinRunSupervisorFileSystem()
        let ready = RunSupervisorTestSupport.waitUntil(timeout: 5) {
            if directory == nil {
                directory = try? root.openExecutionDirectory(payload.manifest.executionID)
            }
            guard let directory else { return false }
            discovery = try? fileSystem.readDiscovery(in: directory)
            guard let discovery else { return false }
            return DarwinRunSupervisorControlClient().authenticate(
                discovery: discovery,
                directory: directory,
                capability: payload.capability
            )
        }
        guard ready, let directory, let discovery else {
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        return (directory, discovery)
    }

    private func send(
        _ action: RunSupervisorControlAction,
        payload: RunSupervisorBootstrapPayload,
        directory: RunSupervisorRunDirectory
    ) throws -> RunSupervisorControlResponse {
        try DarwinRunSupervisorControlClient().send(
            RunSupervisorControlAuthentication.makeRequest(
                executionID: payload.manifest.executionID,
                action: action,
                capability: payload.capability
            ),
            directory: directory
        )
    }

    private func replayAll(
        payload: RunSupervisorBootstrapPayload,
        directory: RunSupervisorRunDirectory
    ) throws -> [RunSupervisorEvent] {
        var cursor: UInt64 = 0
        var all: [RunSupervisorEvent] = []
        while true {
            let response = try send(
                .init(kind: .replay, afterSequence: cursor),
                payload: payload,
                directory: directory
            )
            all.append(contentsOf: response.events)
            guard let next = response.events.last?.sequence,
                  next > cursor,
                  next < response.lastSequence else {
                return all
            }
            cursor = next
        }
    }

    private func terminateForCleanup(_ process: Process) {
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func terminateForCleanup(pid: pid_t) {
        guard pid > 1, RunSupervisorTestSupport.isAlive(pid) else { return }
        _ = kill(pid, SIGKILL)
    }
}
