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
        let rootFD = open(runRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError("open run root", errno) }
        defer { close(rootFD) }

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeDescriptors) == 0 else { throw posixError("pipe bootstrap", errno) }
        defer {
            if pipeDescriptors[0] >= 0 { close(pipeDescriptors[0]) }
            if pipeDescriptors[1] >= 0 { close(pipeDescriptors[1]) }
        }

        var actions: posix_spawn_file_actions_t? = nil
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else { throw posixError("spawn actions", actionsResult) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(
            posix_spawn_file_actions_adddup2(&actions, pipeDescriptors[0], 3),
            operation: "dup bootstrap"
        )
        try check(
            posix_spawn_file_actions_adddup2(&actions, rootFD, 4),
            operation: "dup run root"
        )
        try check(
            posix_spawn_file_actions_addclose(&actions, pipeDescriptors[1]),
            operation: "close bootstrap writer"
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
