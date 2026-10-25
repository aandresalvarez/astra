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
            connectionTarget: "pcornet-backup",
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
        #expect(launch.isolation == "managed_process_group")
        #expect(launch.shell == "/bin/sh")

        let finished = try await settled(manager, started.jobID)
        #expect(finished.status == .succeeded)
        #expect(finished.exitCode == 0)
        #expect(finished.stdoutBytes == 5)
        // Even a terminal result is rechecked; it is not cleanup authority.
        let probes = try host.invocations().count
        #expect(record(manager.status(jobID: started.jobID))?.status == .succeeded)
        #expect(try host.invocations().count == probes + 1)
    }

    @Test("An unreachable host keeps the last verified status; a killed job and supervisor become lost")
    func unreachableThenLost() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "sleep 30")))
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
        let lost = try #require(record(manager.status(jobID: started.jobID)))
        #expect(lost.status == .unverified)
        #expect(lost.exitCode == nil)
        #expect(lost.message?.contains("no exit code was recorded") == true)
    }

    @Test("Boot id drift and a vanished job directory are lost, never running")
    func rebootAndMissingDirectoryAreLost() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()

        let rebooted = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "sleep 30")))
        let rebootedLaunch = try #require(rebooted.launch)
        defer { host.kill(rebootedLaunch) }
        // The evidence came from an earlier boot of this host.
        try manager.store.update(jobID: rebooted.jobID) { $0.launch?.bootID = "an-earlier-boot" }
        let afterReboot = try #require(record(manager.status(jobID: rebooted.jobID)))
        #expect(afterReboot.status == .unverified)
        #expect(afterReboot.message?.contains("rebooted") == true)

        let vanished = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "sleep 31")))
        let vanishedLaunch = try #require(vanished.launch)
        defer { host.kill(vanishedLaunch) }
        try FileManager.default.removeItem(at: host.home.appendingPathComponent(".astra/jobs/\(vanished.jobID)"))
        let afterRemoval = try #require(record(manager.status(jobID: vanished.jobID)))
        #expect(afterRemoval.status == .unverified)
        #expect(afterRemoval.message?.contains("missing") == true)
    }

    @Test("An existing job directory refuses the launch and runs nothing")
    func existingDirectoryRefusesLaunch() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let jobID = UUID().uuidString.lowercased()
        let directory = host.home.appendingPathComponent(".astra/jobs/\(jobID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = host.manager(makeJobID: { jobID })

        let outcome = manager.start(connectionTarget: "pcornet-backup", command: "touch should-not-exist")
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
        let outcome = host.manager().start(connectionTarget: "pcornet-backup", command: "true")
        guard case .failure(let message, let pending) = outcome, let pending else {
            Issue.record("expected an unconfirmed launch with a record, got \(outcome)")
            return
        }
        #expect(pending.status == .starting)
        #expect(message.contains("No command was launched"))

        // Back online: a start that never made its directory is still
        // `starting` inside the grace window, and `lost` once it has passed.
        try host.setUnreachable(false)
        var clock = Date()
        let manager = host.manager(now: { clock })
        #expect(record(manager.status(jobID: pending.jobID))?.status == .starting)
        clock = clock.addingTimeInterval(RemoteWorkspaceJobStatusDerivation.launchGraceSeconds + 1)
        let lost = try #require(record(manager.status(jobID: pending.jobID)))
        #expect(lost.status == .unverified)
        #expect(lost.message?.contains("delayed launch") == true)
    }

    @Test("Tail is capped at 500 lines however many are asked for")
    func tailIsBounded() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "i=0; while [ $i -lt 1200 ]; do echo line-$i; i=$((i+1)); done")))
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

    @Test("Cancellation survives disconnect and a reopened manager")
    func cancelAfterReconnect() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: "pcornet-backup", command: "trap '' TERM; while :; do sleep 1; done")))
        defer { if let launch = started.launch { host.kill(launch) } }
        try host.setUnreachable(true)
        _ = manager.cancel(jobID: started.jobID)
        #expect(try manager.store.load(jobID: started.jobID).cancellationRequestedAt != nil)
        try host.setUnreachable(false)
        let reopened = host.manager()
        let finished = try await settled(reopened, started.jobID)
        #expect(finished.status == .cancelled)
        #expect(!finished.cleanupVerified)
        let repeated = try #require(record(reopened.start(connectionTarget: "pcornet-backup", command: started.command)))
        #expect(repeated.jobID == started.jobID)
    }

    @Test("Timeout still kills an ignoring child after its parent shell exits")
    func timeoutAfterParentExit() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let started = try #require(record(manager.start(connectionTarget: "pcornet-backup",
            command: "(trap '' TERM; while :; do sleep 1; done) & echo $! > child.pid; exit 0", timeoutSeconds: 2)))
        defer { if let launch = started.launch { host.kill(launch) } }
        let finished = try await settled(manager, started.jobID)
        #expect(finished.status == .timedOut)
        #expect(!finished.cleanupVerified)
        let pid = try #require(Int32(String(contentsOf: host.home.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // A zombie may await the OS reaper but cannot perform work.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        #expect(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) != size || info.pbi_status == SZOMB)
    }

    @Test("A delayed launch is observed again after the grace period without another start")
    func delayedLaunchReconciles() throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let admitted = try manager.register(connectionTarget: "pcornet-backup", command: "sleep 10")
        var observedAt = admitted.record.createdAt.addingTimeInterval(120)
        let late = host.manager(now: { observedAt })
        #expect(record(late.status(jobID: admitted.record.jobID))?.status == .unverified)
        let nonce = try #require(admitted.record.launchNonce)
        _ = SSHRemoteWorkspaceJobTransport(sshExecutable: host.ssh.path).run(connection: host.connections[0],
            script: RemoteWorkspaceJobScripts.start(jobID: admitted.record.jobID, command: "sleep 10", timeoutSeconds: 15, nonce: nonce, clock: try #require(admitted.record.remoteClock)), timeoutSeconds: 20)
        // This is a later check, not another reply at the same fixed instant
        // (the journal serializes dates at millisecond precision).
        observedAt = observedAt.addingTimeInterval(1)
        let observed = try #require(record(late.status(jobID: admitted.record.jobID)))
        defer { if let launch = observed.launch { host.kill(launch) } }
        #expect(observed.status == .running, "\(observed.message ?? "") \(observed.lastObservation?.error ?? "")")
        #expect(try manager.register(connectionTarget: "pcornet-backup", command: "sleep 10").created == false)
    }

    @Test("An admission that expires during SSH connection never starts its command")
    func expiredRemoteAdmission() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let job = try manager.register(connectionTarget: "pcornet-backup", command: "touch expired-command-ran", timeoutSeconds: 30).record
        _ = SSHRemoteWorkspaceJobTransport(sshExecutable: host.ssh.path).run(connection: host.connections[0],
            script: RemoteWorkspaceJobScripts.start(jobID: job.jobID, command: job.command, timeoutSeconds: 30,
                nonce: try #require(job.launchNonce), clock: .init(bootID: try #require(job.remoteClock).bootID, deadline: try #require(job.remoteClock).deadline - 60)), timeoutSeconds: 20)
        let finished = try await settled(manager, job.jobID)
        #expect(finished.status == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: host.home.appendingPathComponent("expired-command-ran").path))
    }

    @Test("A remote wall clock behind the Mac cannot extend a monotonic deadline")
    func clockSkewDoesNotExtend() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let job = try manager.register(connectionTarget: "pcornet-backup", command: "sleep 30", timeoutSeconds: 2).record
        let script = RemoteWorkspaceJobScripts.start(jobID: job.jobID, command: job.command, timeoutSeconds: 30,
            nonce: try #require(job.launchNonce), clock: try #require(job.remoteClock))
            .replacingOccurrences(of: "root = pathlib.Path(sys.argv[1])", with: "time.time = lambda: -999999999\nroot = pathlib.Path(sys.argv[1])")
        _ = SSHRemoteWorkspaceJobTransport(sshExecutable: host.ssh.path).run(connection: host.connections[0], script: script, timeoutSeconds: 20)
        let finished = try await settled(manager, job.jobID)
        #expect(finished.status == .timedOut)
        #expect(!finished.cleanupVerified)
    }

    @Test("Time spent starting a command cannot move its admitted deadline")
    func slowProcessCreationKeepsDeadline() async throws {
        let host = try FakeSSHHost()
        defer { host.cleanup() }
        let manager = host.manager()
        let job = try manager.register(connectionTarget: "pcornet-backup", command: "sleep 1; touch extended-deadline", timeoutSeconds: 30).record
        let injected = """
        def launch_after_delay(*args, **kwargs):
            child = subprocess.Popen(*args, **kwargs)
            original_clock = time.monotonic
            time.monotonic = lambda: original_clock() + 120
            return child
        root = pathlib.Path(sys.argv[1])
        """
        let script = RemoteWorkspaceJobScripts.start(jobID: job.jobID, command: job.command, timeoutSeconds: 30,
            nonce: try #require(job.launchNonce), clock: try #require(job.remoteClock))
            .replacingOccurrences(of: "root = pathlib.Path(sys.argv[1])", with: injected)
            .replacingOccurrences(of: "command = subprocess.Popen(", with: "command = launch_after_delay(")
        _ = SSHRemoteWorkspaceJobTransport(sshExecutable: host.ssh.path).run(connection: host.connections[0], script: script, timeoutSeconds: 20)
        #expect(try await settled(manager, job.jobID).status == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: host.home.appendingPathComponent("extended-deadline").path))
    }

    // MARK: - Record and derivation

    @Test("Older observations are dropped; new evidence can correct a terminal observation")
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
        #expect(job.status == .running)
        #expect(job.exitCode == nil)
        job.apply(.unreachable(at: created.addingTimeInterval(40), error: "down"))
        #expect(job.status == .running)
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
        #expect(try derive(Self.probe(pidAlive: true, pidMarker: "Mon Oct 20 09:00:00 2026")) == .unverified, "a reused pid is not the job")
        #expect(try derive(Self.probe(pidAlive: false, supervisorAlive: true)) == .running, "the supervisor is writing the result")
        #expect(try derive(Self.probe(pidAlive: false)) == .unverified)
        #expect(try derive(Self.probe(pidAlive: true, hostBoot: "boot-2")) == .unverified)
        #expect(try derive(Self.probe(pidAlive: false, result: #"{"status":"timed_out","exit_code":124,"completed_at":"2026-10-21T12:00:00Z"}"#)) == .timedOut)
        #expect(try derive(Self.probe(pidAlive: false, result: #"{"status":"failed","exit_code":2,"completed_at":"2026-10-21T12:00:00Z"}"#)) == .failed)
        #expect(try derive(Self.emptyProbe(state: "present")) == .starting)
        #expect(try derive(Self.emptyProbe(state: "present"), at: 61) == .unverified)
        #expect(try derive(Self.emptyProbe(state: "missing")) == .starting, "a start still in flight")
        #expect(try derive(Self.emptyProbe(state: "missing"), at: 61) == .unverified)
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
        let output = RemoteWorkspaceJobCLI.run(.start(connection: "pcornet-backup", label: "quick", timeoutSeconds: nil, command: "echo ok"), manager: host.manager())
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

    private static let probeID = "11111111-1111-1111-1111-111111111111"
    private static let probeNonce = "22222222-2222-2222-2222-222222222222"
    private static func emptyProbe(state: String) -> String {
        "astra_probe=2\njob_id=\(probeID)\nnonce=\(probeNonce)\nhost_boot_id=boot-1\nstate=\(state)\npid_alive=0\nsupervisor_alive=0\nastra_probe_end=\(probeID):\(probeNonce)"
    }

    private static func probe(
        pidAlive: Bool,
        pidMarker: String = "Tue Oct 21 11:00:00 2026",
        supervisorAlive: Bool = false,
        hostBoot: String = "boot-1",
        result: String? = nil
    ) -> String {
        var lines = [
            "astra_probe=2",
            "job_id=\(probeID)",
            "nonce=\(probeNonce)",
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
        if let result {
            let bound = result.replacingOccurrences(of: "{", with: "{\"job_id\":\"\(probeID)\",\"nonce\":\"\(probeNonce)\",", range: result.startIndex..<result.index(after: result.startIndex))
            lines.append("result=\(bound)")
        }
        lines.append("astra_probe_end=\(probeID):\(probeNonce)")
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
struct FakeSSHHost {
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
        _ = Darwin.kill(-launch.pid, SIGKILL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
