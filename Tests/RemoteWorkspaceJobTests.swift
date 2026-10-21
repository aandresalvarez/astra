import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import WorkspaceToolSupport

/// The SSH remote job helper end to end: a fake `ssh` drops the destination
/// and runs ASTRA's script locally with `/bin/sh` and a scratch `$HOME`, so
/// real detached jobs start, finish, fail, and are killed.
@Suite("Remote workspace jobs", .serialized)
struct RemoteWorkspaceJobTests {
    @Test("A started job runs detached; status reads its exit code and tail reads both logs")
    func startStatusTailRoundTrip() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()

        let started = try #require(record(manager.start(
            connectionTarget: nil,
            command: "printf 'hello\\n'; printf 'oops\\n' >&2; exit 3",
            label: "scan"
        )))
        #expect(started.connectionTarget == "pcornet-backup")
        #expect(started.label == "scan")
        #expect(started.launch != nil)

        let finished = try await settled(manager, started.jobID)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == 3)
        #expect(finished.completedAt != nil)
        #expect(finished.lastObservation?.outcome == .reachable)

        #expect(manager.tail(jobID: started.jobID, stream: "stdout", lines: 10)
            == .text(jobID: started.jobID, stream: "stdout", text: "hello"))
        #expect(manager.tail(jobID: started.jobID, stream: "stderr", lines: 10)
            == .text(jobID: started.jobID, stream: "stderr", text: "oops"))

        let jobDirectory = host.home.appendingPathComponent(".astra/jobs/\(started.jobID)")
        #expect(try String(contentsOf: jobDirectory.appendingPathComponent("command.sh"), encoding: .utf8)
            .contains("printf 'hello\\n'"))
        let recordURL = try manager.store.recordURL(jobID: started.jobID)
        let mode = try FileManager.default.attributesOfItem(atPath: recordURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // Every call went through `ssh <destination> sh -s`, never prompting.
        let invocations = try host.invocations()
        #expect(invocations.allSatisfy { $0.contains("-o BatchMode=yes") && $0.hasSuffix("pcornet-backup sh -s") })
    }

    @Test("A job that outlives start is running with launch evidence, then succeeded")
    func runningThenSucceeded() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()

        let started = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "sleep 1; echo done")))
        #expect(started.status == .running)
        let launch = try #require(started.launch)
        #expect(launch.pid > 1)
        #expect(!launch.bootID.isEmpty)
        #expect(["setsid", "nohup"].contains(launch.isolation))
        #expect(launch.shell == "/bin/sh")

        let finished = try await settled(manager, started.jobID)
        #expect(finished.status == .succeeded)
        #expect(finished.exitCode == 0)
        #expect(finished.stdoutBytes == 5)
        // Terminal records are final and answered without reaching the host.
        let probes = try host.invocations().count
        #expect(record(manager.status(jobID: started.jobID))?.status == .succeeded)
        #expect(try host.invocations().count == probes)
    }

    @Test("An unreachable host keeps the last verified status; a killed job and supervisor become lost")
    func unreachableThenLost() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: nil, command: "sleep 30")))
        let launch = try #require(started.launch)
        defer { host.kill(launch) }
        #expect(started.status == .running)

        try host.setUnreachable(true)
        let unreachable = manager.status(jobID: started.jobID)
        let unverified = try #require(record(unreachable))
        #expect(unverified.status == .running)
        #expect(unverified.lastObservation?.outcome == .unreachable)
        #expect(unverified.lastObservation?.error?.contains("Connection refused") == true)
        #expect(unverified.lastVerifiedAt == started.lastVerifiedAt)
        let output = RemoteWorkspaceJobCLI.output(unreachable, store: manager.store)
        #expect(output.stdout.contains("observation: unreachable"))
        #expect(output.stdout.contains("Do not start the job again"))

        try host.setUnreachable(false)
        host.kill(launch)
        let lost = try await settled(manager, started.jobID)
        #expect(lost.status == .lost)
        #expect(lost.exitCode == nil)
        #expect(lost.message?.contains("no exit code was recorded") == true)
    }

    @Test("Boot id drift and a vanished job directory are lost, never running")
    func rebootAndMissingDirectoryAreLost() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()

        let rebooted = try #require(record(manager.start(connectionTarget: nil, command: "sleep 30")))
        let rebootedLaunch = try #require(rebooted.launch)
        defer { host.kill(rebootedLaunch) }
        // The evidence came from an earlier boot of this host.
        try manager.store.update(jobID: rebooted.jobID) { $0.launch?.bootID = "an-earlier-boot" }
        let afterReboot = try #require(record(manager.status(jobID: rebooted.jobID)))
        #expect(afterReboot.status == .lost)
        #expect(afterReboot.message?.contains("rebooted") == true)

        let vanished = try #require(record(manager.start(connectionTarget: nil, command: "sleep 30")))
        let vanishedLaunch = try #require(vanished.launch)
        defer { host.kill(vanishedLaunch) }
        try FileManager.default.removeItem(at: host.home.appendingPathComponent(".astra/jobs/\(vanished.jobID)"))
        let afterRemoval = try #require(record(manager.status(jobID: vanished.jobID)))
        #expect(afterRemoval.status == .lost)
        #expect(afterRemoval.message?.contains("not on the host") == true)
    }

    @Test("An existing job directory refuses the launch and runs nothing")
    func existingDirectoryRefusesLaunch() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let jobID = UUID().uuidString.lowercased()
        let directory = host.home.appendingPathComponent(".astra/jobs/\(jobID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = host.manager(makeJobID: { jobID })

        let outcome = manager.start(connectionTarget: nil, command: "touch should-not-exist")
        guard case .failure(let message, let failed) = outcome else {
            Issue.record("expected a refused launch, got \(outcome)")
            return
        }
        #expect(message.contains("already exists"))
        #expect(failed?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.sh").path))
        #expect(!FileManager.default.fileExists(atPath: host.home.appendingPathComponent("should-not-exist").path))
    }

    @Test("A launch ASTRA cannot confirm keeps its id and says so")
    func unconfirmedLaunchKeepsItsID() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        try host.setUnreachable(true)
        let outcome = host.manager().start(connectionTarget: nil, command: "true")
        guard case .failure(let message, let pending) = outcome, let pending else {
            Issue.record("expected an unconfirmed launch with a record, got \(outcome)")
            return
        }
        #expect(pending.status == .starting)
        #expect(message.contains("may or may not have started"))
        #expect(message.contains("astra-workspace-job status \(pending.jobID)"))

        // Back online: a start that never made its directory is still
        // `starting` inside the grace window, and `lost` once it has passed.
        try host.setUnreachable(false)
        var clock = Date()
        let manager = host.manager(now: { clock })
        #expect(record(manager.status(jobID: pending.jobID))?.status == .starting)
        clock = clock.addingTimeInterval(RemoteWorkspaceJobStatusDerivation.launchGraceSeconds + 1)
        let lost = try #require(record(manager.status(jobID: pending.jobID)))
        #expect(lost.status == .lost)
        #expect(lost.message?.contains("never reached the host") == true)
    }

    @Test("Tail is capped at 500 lines however many are asked for")
    func tailIsBounded() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: nil, command: "i=0; while [ $i -lt 1200 ]; do echo line-$i; i=$((i+1)); done")))
        _ = try await settled(manager, started.jobID)

        guard case .text(_, _, let text) = manager.tail(jobID: started.jobID, stream: "stdout", lines: 5_000) else {
            Issue.record("expected log text")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.count == RemoteWorkspaceJobScripts.maximumTailLines)
        #expect(lines.last == "line-1199")
    }

    @Test("Connections are matched by their exact ssh target, and an ambiguous start names them")
    func connectionSelection() throws {
        let host = try FakeSSHHost(targets: ["pcornet-backup", "-p 2222 agent@vm.example.test"])
        defer { host.cleanup() }
        let manager = host.manager()
        #expect(throws: RemoteWorkspaceJobError.unknownConnection(requested: nil, offered: ["pcornet-backup", "-p 2222 agent@vm.example.test"])) {
            try manager.connection(target: nil)
        }
        #expect(try manager.connection(target: "-p 2222 agent@vm.example.test").arguments == ["-p", "2222", "agent@vm.example.test"])
        #expect(throws: RemoteWorkspaceJobError.self) { try manager.connection(target: "other-host") }
    }

    // MARK: - Record and derivation

    @Test("Observations are monotonic: older ones are dropped and a terminal status stays")
    func observationsAreMonotonic() throws {
        let created = Date(timeIntervalSince1970: 1_000)
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), connection: Self.connection, command: "x", createdAt: created)
        let running = try #require(RemoteWorkspaceJobHostSnapshot.parse(Self.probe(pidAlive: true)))
        let finished = try #require(RemoteWorkspaceJobHostSnapshot.parse(Self.probe(pidAlive: false, result: #"{"status":"succeeded","exit_code":0,"completed_at":"2026-10-21T12:00:00Z"}"#)))

        job.apply(.reachable(at: created.addingTimeInterval(20), snapshot: finished, derived: .init(status: .succeeded, exitCode: 0)))
        #expect(job.status == .succeeded)
        job.apply(.reachable(at: created.addingTimeInterval(10), snapshot: running, derived: .init(status: .running)))
        #expect(job.lastObservation?.at == created.addingTimeInterval(20))
        job.apply(.reachable(at: created.addingTimeInterval(30), snapshot: running, derived: .init(status: .running)))
        #expect(job.status == .succeeded)
        #expect(job.exitCode == 0)
        job.apply(.unreachable(at: created.addingTimeInterval(40), error: "down"))
        #expect(job.status == .succeeded)
        #expect(job.lastVerifiedAt == created.addingTimeInterval(30))
    }

    @Test("The status table")
    func statusTable() throws {
        let created = Date(timeIntervalSince1970: 1_000)
        let job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), connection: Self.connection, command: "x", createdAt: created)
        func derive(_ probe: String, at seconds: TimeInterval = 5) throws -> RemoteWorkspaceJobStatus {
            let snapshot = try #require(RemoteWorkspaceJobHostSnapshot.parse(probe))
            return RemoteWorkspaceJobStatusDerivation.derive(snapshot: snapshot, record: job, now: created.addingTimeInterval(seconds)).status
        }
        #expect(try derive(Self.probe(pidAlive: true)) == .running)
        #expect(try derive(Self.probe(pidAlive: true, pidMarker: "Mon Oct 20 09:00:00 2026")) == .lost, "a reused pid is not the job")
        #expect(try derive(Self.probe(pidAlive: false, supervisorAlive: true)) == .running, "the supervisor is writing the result")
        #expect(try derive(Self.probe(pidAlive: false)) == .lost)
        #expect(try derive(Self.probe(pidAlive: true, hostBoot: "boot-2")) == .lost)
        #expect(try derive(Self.probe(pidAlive: false, result: #"{"status":"timed_out","exit_code":124,"completed_at":"2026-10-21T12:00:00Z"}"#)) == .timedOut)
        #expect(try derive(Self.probe(pidAlive: false, result: #"{"status":"failed","exit_code":2,"completed_at":"2026-10-21T12:00:00Z"}"#)) == .failed)
        #expect(try derive("astra_probe=1\nhost_boot_id=boot-1\nstate=present\npid_alive=0\nsupervisor_alive=0") == .starting)
        #expect(try derive("astra_probe=1\nhost_boot_id=boot-1\nstate=present\npid_alive=0\nsupervisor_alive=0", at: 61) == .lost)
        #expect(try derive("astra_probe=1\nhost_boot_id=boot-1\nstate=missing") == .starting, "a start still in flight")
        #expect(try derive("astra_probe=1\nhost_boot_id=boot-1\nstate=missing", at: 61) == .lost)
        // A login banner is not evidence about the job.
        #expect(RemoteWorkspaceJobHostSnapshot.parse("Welcome to Ubuntu\nstate=present\n") == nil)
    }

    @Test("Job ids are lowercase UUIDs before they become any path")
    func jobIDsAreCanonical() throws {
        let id = UUID()
        #expect(try RemoteWorkspaceJobStore.canonicalJobID(id.uuidString) == id.uuidString.lowercased())
        for bad in ["", "../etc", "abc", "\(id.uuidString)/x", "\(id.uuidString) ; rm -rf ~"] {
            #expect(throws: RemoteWorkspaceJobStoreError.self) { try RemoteWorkspaceJobStore.canonicalJobID(bad) }
        }
    }

    @Test("Heredoc delimiters never equal a line of the text they wrap")
    func heredocDelimiterAvoidsContent() {
        var made = ["ASTRA_JOB_X", "ASTRA_JOB_Y"]
        let delimiter = RemoteWorkspaceJobScripts.delimiter(avoiding: "echo hi\nASTRA_JOB_X\n", make: { made.removeFirst() })
        #expect(delimiter == "ASTRA_JOB_Y_")
    }

    // MARK: - CLI

    @Test("start needs `--`, joins the remote command like ssh, and there is no wait")
    func cliParsing() throws {
        #expect(try RemoteWorkspaceJobCLI.parse(["start", "--connection", "box", "--label=SAS scan", "--timeout", "3600", "--", "cd /data &&", "sas run.sas"])
            == .start(connection: "box", label: "SAS scan", timeoutSeconds: 3600, command: "cd /data && sas run.sas"))
        #expect(try RemoteWorkspaceJobCLI.parse(["status", "abc"]) == .status(jobID: "abc"))
        #expect(try RemoteWorkspaceJobCLI.parse(["tail", "abc", "--stream", "stderr", "--lines", "9000"])
            == .tail(jobID: "abc", stream: "stderr", lines: RemoteWorkspaceJobScripts.maximumTailLines))
        #expect(try RemoteWorkspaceJobCLI.parse([]) == .help)
        for bad in [["start", "sleep 60"], ["start", "--"], ["start", "--bogus", "x", "--", "ls"], ["status"], ["wait", "abc"], ["start", "--timeout", "0", "--", "ls"]] {
            #expect(throws: RemoteWorkspaceJobError.self, "\(bad)") { try RemoteWorkspaceJobCLI.parse(bad) }
        }
        let wait = RemoteWorkspaceJobCLI.run(arguments: ["wait", "abc"], environment: [:])
        #expect(wait.exitCode == 2)
        #expect(wait.stderr.contains("There is no wait"))
    }

    @Test("Without the launch shim's environment the helper says it was not offered")
    func cliWithoutShimEnvironment() {
        let output = RemoteWorkspaceJobCLI.run(arguments: ["status", UUID().uuidString], environment: [:])
        #expect(output.exitCode == 1)
        #expect(output.stderr.contains("not offered to this run"))
    }

    @Test("Output is keyed by remote_job_id so the process monitor never holds the turn for it")
    func cliOutputKeys() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let output = RemoteWorkspaceJobCLI.run(
            arguments: ["start", "--label", "quick", "--", "echo ok"],
            environment: host.environment
        )
        #expect(output.exitCode == 0, "\(output.stderr)")
        let keys = output.stdout.split(separator: "\n").compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
        #expect(keys.first == "remote_job_id")
        #expect(!keys.contains("job_id"))
        #expect(!keys.contains("heartbeat"))
        #expect(keys.contains("next"))
        #expect(output.stdout.contains("runtime: ssh"))
    }

    // MARK: - Helpers

    private static let connection = RemoteWorkspaceJobConnection(id: "c1", name: "backup", target: "pcornet-backup", arguments: ["pcornet-backup"])

    private static func probe(
        pidAlive: Bool,
        pidMarker: String = "Tue Oct 21 11:00:00 2026",
        supervisorAlive: Bool = false,
        hostBoot: String = "boot-1",
        result: String? = nil
    ) -> String {
        var lines = [
            "astra_probe=1",
            "host_boot_id=\(hostBoot)",
            "state=present",
            "evidence.pid=4242",
            "evidence.start_marker=Tue Oct 21 11:00:00 2026",
            "evidence.supervisor_pid=4240",
            "evidence.supervisor_start_marker=Tue Oct 21 10:59:59 2026",
            "evidence.boot_id=boot-1",
            "evidence.isolation=setsid",
            "pid_alive=\(pidAlive ? 1 : 0)",
            "supervisor_alive=\(supervisorAlive ? 1 : 0)"
        ]
        if pidAlive { lines.append("pid_start_marker=\(pidMarker)") }
        if supervisorAlive { lines.append("supervisor_start_marker=Tue Oct 21 10:59:59 2026") }
        if let result { lines.append("result=\(result)") }
        return lines.joined(separator: "\n")
    }

    private func record(_ outcome: RemoteWorkspaceJobOutcome) -> RemoteWorkspaceJobRecord? {
        if case .record(let record) = outcome { return record }
        Issue.record("expected a record, got \(outcome)")
        return nil
    }

    /// Polls by count, not by wall clock: the job is local, so a few seconds
    /// of polls is plenty even on a loaded machine.
    private func settled(_ manager: RemoteWorkspaceJobManager, _ jobID: String) async throws -> RemoteWorkspaceJobRecord {
        for _ in 0..<150 {
            if case .record(let job) = manager.status(jobID: jobID), job.status.isTerminal { return job }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("job \(jobID) never settled")
        return try manager.store.load(jobID: jobID)
    }
}

/// A scratch "host": `$HOME`, a task folder for records, and an `ssh` that
/// logs its arguments, fails like ssh when asked to, and otherwise runs the
/// trailing `sh -s` locally.
private struct FakeSSHHost {
    let root: URL
    let home: URL
    let records: URL
    let ssh: URL
    let log: URL
    let unreachableFlag: URL
    let connections: [RemoteWorkspaceJobConnection]

    init(targets: [String] = ["pcornet-backup"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-remote-job-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        records = root.appendingPathComponent("task/remote-jobs", isDirectory: true)
        ssh = root.appendingPathComponent("ssh")
        log = root.appendingPathComponent("ssh.log")
        unreachableFlag = root.appendingPathComponent("unreachable")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(quoted(log))
        if [ -f \(quoted(unreachableFlag)) ]; then
          echo "ssh: connect to host vm port 22: Connection refused" >&2
          exit 255
        fi
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) shift 2 ;;
            sh) break ;;
            *) shift ;;
          esac
        done
        HOME=\(quoted(home)) SHELL=/bin/sh exec "$@"
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        connections = targets.enumerated().map { index, target in
            RemoteWorkspaceJobConnection(
                id: "connection-\(index)",
                name: "vm \(index)",
                target: target,
                arguments: target.split(separator: " ").map(String.init)
            )
        }
    }

    var configuration: RemoteWorkspaceJobConfiguration {
        RemoteWorkspaceJobConfiguration(recordRootPath: records.path, sshExecutable: ssh.path, connections: connections, taskID: "task-1", runID: "run-1")
    }

    var environment: [String: String] {
        [
            RemoteWorkspaceJobConfiguration.recordRootKey: records.path,
            RemoteWorkspaceJobConfiguration.sshExecutableKey: ssh.path,
            RemoteWorkspaceJobConfiguration.connectionsKey: RemoteWorkspaceJobConfiguration.connectionsJSON(connections)
        ]
    }

    func manager(
        now: @escaping () -> Date = Date.init,
        makeJobID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) -> RemoteWorkspaceJobManager {
        RemoteWorkspaceJobManager(configuration: configuration, now: now, makeJobID: makeJobID)
    }

    func setUnreachable(_ unreachable: Bool) throws {
        if unreachable {
            try Data().write(to: unreachableFlag)
        } else {
            try? FileManager.default.removeItem(at: unreachableFlag)
        }
    }

    func invocations() throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// SIGKILL, so the supervisor cannot write a result on its way out.
    func kill(_ launch: RemoteWorkspaceJobLaunchEvidence) {
        if let supervisor = launch.supervisorPID { _ = Darwin.kill(supervisor, SIGKILL) }
        _ = Darwin.kill(launch.pid, SIGKILL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
