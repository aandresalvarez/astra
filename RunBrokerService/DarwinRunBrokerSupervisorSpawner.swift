import Darwin
import Foundation
import RunBrokerKit
import RunSupervisorSupport

/// Launches only the supervisor installed beside the currently running broker.
/// The ASTRA.app bundle is never consulted, so app replacement cannot change a
/// previously installed execution cohort.
public struct DarwinRunBrokerSupervisorSpawner: RunBrokerSupervisorSpawning, Sendable {
    private let runRootURL: URL
    private let expectedUserID: uid_t

    public init(runRootURL: URL, expectedUserID: uid_t = geteuid()) {
        self.runRootURL = runRootURL.standardizedFileURL
        self.expectedUserID = expectedUserID
    }

    public func spawn(
        payload: RunSupervisorBootstrapPayload,
        installedBrokerExecutableURL: URL
    ) throws {
        try RunSupervisorBootstrapValidator.validate(payload)
        let cohort = try RunBrokerCohortResolver.resolve(
            brokerExecutableURL: installedBrokerExecutableURL,
            expectedUserID: expectedUserID
        )
        let openedRootFD = open(runRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard openedRootFD >= 0 else { throw posixError("open run root", errno) }
        let rootFD = try Self.reserveSourceDescriptor(openedRootFD)
        close(openedRootFD)
        defer { close(rootFD) }

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeDescriptors) == 0 else { throw posixError("pipe bootstrap", errno) }
        let bootstrapReadFD: Int32
        do {
            bootstrapReadFD = try Self.reserveSourceDescriptor(pipeDescriptors[0])
        } catch {
            close(pipeDescriptors[0])
            close(pipeDescriptors[1])
            throw error
        }
        close(pipeDescriptors[0])
        pipeDescriptors[0] = bootstrapReadFD
        defer {
            if pipeDescriptors[0] >= 0 { close(pipeDescriptors[0]) }
            if pipeDescriptors[1] >= 0 { close(pipeDescriptors[1]) }
        }

        var actions: posix_spawn_file_actions_t? = nil
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else { throw posixError("spawn actions", actionsResult) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The pipe writer can itself occupy reserved target 3 or 4. Close it
        // before installing either target so a later close cannot erase one.
        try check(
            posix_spawn_file_actions_addclose(&actions, pipeDescriptors[1]),
            operation: "close bootstrap writer"
        )
        try check(
            posix_spawn_file_actions_adddup2(&actions, pipeDescriptors[0], 3),
            operation: "dup bootstrap"
        )
        try check(
            posix_spawn_file_actions_adddup2(&actions, rootFD, 4),
            operation: "dup run root"
        )

        let executable = cohort.supervisorExecutableURL.path
        let argvStrings = [executable, "--bootstrap-fd", "3", "--root-fd", "4"]
        var argv = argvStrings.map { strdup($0) } + [nil]
        // The supervisor receives provider environment only inside its
        // authenticated bootstrap payload. Do not inherit broker/app secrets.
        let environmentStrings = ["LANG=en_US.UTF-8", "PATH=/usr/bin:/bin"]
        var environment = environmentStrings.map { strdup($0) } + [nil]
        defer {
            argv.forEach { if let value = $0 { free(value) } }
            environment.forEach { if let value = $0 { free(value) } }
        }

        var pid: pid_t = 0
        let spawnResult = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        nil,
                        argvBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard spawnResult == 0 else { throw posixError("spawn supervisor", spawnResult) }
        Self.startReaping(pid)
        close(pipeDescriptors[0])
        pipeDescriptors[0] = -1
        do {
            try RunSupervisorFrameIO.writeFrame(
                RunSupervisorWireCoding.encode(payload),
                to: pipeDescriptors[1],
                maximumBytes: RunSupervisorProtocol.maximumBootstrapBytes
            )
        } catch {
            kill(pid, SIGKILL)
            throw error
        }
        close(pipeDescriptors[1])
        pipeDescriptors[1] = -1
    }

    package static func reserveSourceDescriptor(_ descriptor: Int32) throws -> Int32 {
        let reserved = fcntl(descriptor, F_DUPFD_CLOEXEC, 5)
        guard reserved >= 5 else {
            throw NSError(
                domain: "DarwinRunBrokerSupervisorSpawner",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "reserve spawn source descriptor failed"]
            )
        }
        return reserved
    }

    package static func startReaping(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw posixError(operation, result) }
    }

    private func posixError(_ operation: String, _ code: Int32) -> NSError {
        NSError(
            domain: "DarwinRunBrokerSupervisorSpawner",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"]
        )
    }
}
