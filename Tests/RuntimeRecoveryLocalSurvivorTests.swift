import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// Whether a run's tools stopped is a question for the process table. These
/// launch real processes: one that leaves nothing behind, and one that leaves
/// a daemon outside the provider's process group, where only the scope value
/// in its environment still ties it to the launch.
@Suite("Local cleanup is observed from the process table", .serialized)
@MainActor
struct RuntimeRecoveryLocalSurvivorTests {
    /// Forks, lets the parent exit like a finished provider, and keeps a child
    /// alive in its own session with no inherited descriptors.
    static let daemon = "use POSIX; exit 0 if fork; POSIX::setsid(); close STDIN; close STDOUT; close STDERR; sleep 120"

    /// For fixtures elsewhere that need a run whose cleanup is really unproven:
    /// a shell line that leaves a sleeper outside the provider's group, still
    /// sitting in its folder. Pair it with `stopOrphans(under:)`.
    static let survivorLine = #"/usr/bin/perl -e 'use POSIX; exit 0 if fork; POSIX::setsid(); close STDIN; close STDOUT; close STDERR; exec "/bin/sleep", "300"'"#

    /// Stops every orphan of this user whose working directory is inside `root`.
    static func stopOrphans(under root: String) {
        let root = RuntimeExecutionLocalSurvivors.resolved(root)
        var pids = [pid_t](repeating: 0, count: 8_192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        for pid in pids.prefix(Int(max(0, count))) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1, info.pbi_uid == getuid() else { continue }
            var paths = proc_vnodepathinfo()
            let pathSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathSize) == pathSize else { continue }
            let directory = withUnsafePointer(to: &paths.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if directory == root || directory.hasPrefix(root + "/") { kill(pid, SIGKILL) }
        }
    }

    /// Each launch gets its own folder: the hidden-environment rule asks who is still sitting in it.
    static func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astra-survivors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func finished(_ executable: String, _ arguments: [String], in directory: String? = nil,
                         environment: [String: String] = ["PATH": "/usr/bin:/bin"]) async throws -> AgentExecutionScopedProcess {
        let process = AgentExecutionScopedProcess(executablePath: executable, arguments: arguments,
            currentDirectory: try directory ?? folder(), environment: environment, stdinMode: .closed)
        try process.run()
        var polls = 0
        while process.isRunning, polls < 1_000 { try await Task.sleep(for: .milliseconds(10)); polls += 1 }
        try #require(!process.isRunning)
        return process
    }

    static func stop(_ survivors: [RuntimeLocalSurvivorObservation.Survivor]) async throws {
        for survivor in survivors where survivor.process.presence == .present { kill(survivor.process.pid, SIGKILL) }
        var polls = 0
        while survivors.contains(where: { $0.process.presence != .absent }), polls < 1_000 {
            try await Task.sleep(for: .milliseconds(10)); polls += 1
        }
        try #require(survivors.allSatisfy { $0.process.presence == .absent })
    }

    @Test("A run whose tools left nothing alive proves its tools stopped")
    func nothingSurvives() async throws {
        let process = try await Self.finished("/bin/sh", ["-c", "/bin/ls / >/dev/null; (/bin/sleep 0 &) ; exit 0"])
        let id = UUID()
        // The transcript's answer stands unless the caller asks the process table.
        let unasked = try #require(process.stopProof(executionID: id, toolsStopped: false, remoteWorkExcluded: true))
        #expect(!unasked.toolsStopped && unasked.localSurvivors == nil && !unasked.permitsReplacement)
        let proof = try #require(process.stopProof(executionID: id, toolsStopped: false, remoteWorkExcluded: true,
            observingLocalSurvivors: true))
        #expect(proof.reaped && proof.processGroupEmpty && proof.toolsStopped && proof.permitsReplacement)
        let observation = try #require(proof.localSurvivors)
        #expect(observation.clean && observation.launch.scope == process.localScope && observation.launch.provider == proof.process)
        // A transcript that already proves no tool ran is not second-guessed.
        let known = try #require(process.stopProof(executionID: id, toolsStopped: true, remoteWorkExcluded: true,
            observingLocalSurvivors: true))
        #expect(known.toolsStopped && known.localSurvivors == nil)
        // Remote work is a separate question the process table cannot answer.
        let remote = try #require(process.stopProof(executionID: id, toolsStopped: false, remoteWorkExcluded: false,
            observingLocalSurvivors: true))
        #expect(remote.toolsStopped && !remote.permitsReplacement)
    }

    @Test("A daemon outside the process group is found, named, and scoped to its own launch")
    func daemonSurvives() async throws {
        let process = try await Self.finished("/usr/bin/perl", ["-e", Self.daemon])
        let proof = try #require(process.stopProof(executionID: UUID(), toolsStopped: false, remoteWorkExcluded: true,
            observingLocalSurvivors: true))
        let observation = try #require(proof.localSurvivors)
        do {
            // The group is empty: only the inherited scope ties the daemon to this launch.
            #expect(proof.reaped && proof.processGroupEmpty)
            #expect(!proof.toolsStopped && !proof.permitsReplacement)
            #expect(observation.complete && observation.survivors.count == 1)
            let survivor = try #require(observation.survivors.first)
            #expect(survivor.name.hasPrefix("perl") && survivor.process.presence == .present)
            #expect(getpgid(survivor.process.pid) != process.processIdentifier)

            // Another launch, in another folder, is not blamed for it.
            let other = try await Self.finished("/bin/sh", ["-c", "exit 0"])
            let unrelated = try #require(other.stopProof(executionID: UUID(), toolsStopped: false, remoteWorkExcluded: true,
                observingLocalSurvivors: true))
            #expect(unrelated.toolsStopped && unrelated.localSurvivors?.clean == true)
        } catch { try await Self.stop(observation.survivors); throw error }

        try await Self.stop(observation.survivors)
        #expect(RuntimeExecutionLocalSurvivors.observe(observation.launch).clean)
        #expect(proof.observing(RuntimeExecutionLocalSurvivors.observe(observation.launch)).permitsReplacement)
    }

    /// The kernel hides a system binary's environment, so `perl` above is found
    /// as an orphan in the launch's folder. A binary outside the system volume
    /// shows its environment and is found by the scope value wherever it sits.
    @Test("Each of the two ties finds its survivor: the scope value, and an orphan in the launch's folder",
          arguments: ["scopeElsewhere", "orphanInFolder", "orphanElsewhere"])
    func eachTie(shape: String) async throws {
        let folder = try Self.folder()
        // A re-signed copy is not a system binary, so its environment is readable.
        let copy = folder + "/survivor"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: copy)
        if shape == "scopeElsewhere" {
            let signing = try await Self.finished("/usr/bin/codesign", ["--force", "--sign", "-", copy])
            try #require(signing.terminationStatus == 0)
        }
        // The shell leaves the group, moves or stays, and backgrounds one sleeper before it exits.
        let leave = "use POSIX; exit 0 if fork; POSIX::setsid(); close STDIN; close STDOUT; close STDERR;"
        let script: String
        switch shape {
        case "scopeElsewhere": script = leave + " chdir '/'; exec '\(copy)', '120'"
        case "orphanInFolder": script = leave + " exec '/bin/sleep', '120'"
        default: script = leave + " chdir '/'; exec '/bin/sleep', '120'"
        }
        let process = try await Self.finished("/usr/bin/perl", ["-e", script], in: folder)
        let proof = try #require(process.stopProof(executionID: UUID(), toolsStopped: false, remoteWorkExcluded: true,
            observingLocalSurvivors: true))
        let observation = try #require(proof.localSurvivors)
        let sleepers = { () -> [pid_t] in
            var pids = [pid_t](repeating: 0, count: 8_192)
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            return pids.prefix(Int(max(0, count))).filter { pid in
                guard let identity = RuntimeProcessIdentity.read(pid), identity.startedSeconds >= proof.process.startedSeconds else { return false }
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_ppid == 1 && info.pbi_pgid == UInt32(pid)
                    && withUnsafePointer(to: &info.pbi_name) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
                        .hasPrefix(shape == "scopeElsewhere" ? "survivor" : "sleep")
            }
        }
        do {
            #expect(proof.reaped && proof.processGroupEmpty && observation.complete)
            if shape == "orphanElsewhere" {
                // The stated limit: a hidden-environment orphan that left the folder is not seen.
                #expect(observation.clean && proof.toolsStopped)
            } else {
                #expect(observation.survivors.count == 1 && !proof.toolsStopped)
                #expect(observation.survivors.first?.name == (shape == "scopeElsewhere" ? "survivor" : "sleep"))
            }
        } catch { for pid in sleepers() { kill(pid, SIGKILL) }; throw error }
        // Whatever the observation saw, nothing this test started stays behind.
        for pid in sleepers() { kill(pid, SIGKILL) }
        try await Self.stop(observation.survivors)
    }

    @Test("An unreadable or malformed scope is never clean")
    func incompleteObservation() {
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let observation = RuntimeExecutionLocalSurvivors.observe(.init(scope: "not-a-scope", root: "/", provider: dead, ended: Date()))
        #expect(!observation.complete && !observation.clean)
        #expect(!RuntimeExecutionLocalSurvivors.observe(.init(scope: UUID().uuidString, root: "relative", provider: dead, ended: Date())).complete)
        let proof = RuntimeExecutionStopProof(executionID: UUID(), process: dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date())
        #expect(!proof.observing(observation).toolsStopped)
        // The process table cannot vouch for a provider that was not reaped or whose group is not empty.
        let clean = RuntimeLocalSurvivorObservation(launch: .init(scope: UUID().uuidString, root: "/", provider: dead, ended: Date()),
            observedAt: Date(), complete: true, survivors: [])
        for (reaped, empty) in [(false, true), (true, false)] {
            let open = RuntimeExecutionStopProof(executionID: UUID(), process: dead, reaped: reaped, processGroupEmpty: empty,
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date())
            #expect(open.observing(clean) == open)
        }
    }

    @Test("Receipts written before the observation existed decode unchanged")
    func olderReceiptsDecode() throws {
        let dead = RuntimeProcessIdentity(pid: 7, startedSeconds: 1, startedMicroseconds: 1)
        let proof = RuntimeExecutionStopProof(executionID: UUID(), process: dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(proof)
        #expect(!String(decoding: data, as: UTF8.self).contains("localSurvivors"))
        #expect(try JSONDecoder().decode(RuntimeExecutionStopProof.self, from: data) == proof)
    }

    private func receipt(_ h: HeadlessChatHarness, survivors: [RuntimeLocalSurvivorObservation.Survivor],
                         observed: RuntimeExecutionStopProof? = nil) throws -> (AgentTask, RuntimeExecutionOwnerRecord) {
        let task = h.makeTask(runtime: .copilotCLI, goal: "Preserve", model: "test")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        h.context.insert(run); try h.context.save()
        let dead = observed?.process ?? RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let executionID = observed?.executionID ?? UUID()
        var proof = observed ?? RuntimeExecutionStopProof(executionID: executionID, process: dead, reaped: true, processGroupEmpty: true,
            toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date())
        if observed == nil {
            proof.localSurvivors = .init(launch: .init(scope: UUID().uuidString, root: h.workspaceURL.path, provider: dead, ended: Date()),
                observedAt: Date(), complete: true, survivors: survivors)
        }
        let record = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: executionID,
            runID: run.id, appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            providerProcess: dead, runtime: "copilot_cli", state: .finished,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 3, secondsRemaining: 60, tokensSpent: 42, costSpent: 0.1),
            stopProof: proof, settlementInProgress: false, settlementLocalWorkStopped: true, settlementToolsStopped: true,
            resourceClaims: [.init(taskID: task.id, resourceKey: h.workspaceURL.path, accessMode: .write, runMode: "continue")],
            resourcesReleased: false, updatedAt: Date())
        return (task, record)
    }

    @Test("A receipt that recorded survivors is released only when the process table is asked again and is clean",
          arguments: ["valid", "stillAlive", "newDescendant", "unreadable", "remote", "inherited", "settlement", "settlementTools",
                      "cancelled", "unfinished", "execution", "liveProvider", "noSurvivorsRecorded"])
    func reobservationGates(fault: String) throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let gone = RuntimeLocalSurvivorObservation.Survivor(
            process: .init(pid: Int32.max - 1, startedSeconds: 1, startedMicroseconds: 1), name: "node")
        let alive = RuntimeLocalSurvivorObservation.Survivor(
            process: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)), name: "node")
        let (_, initial) = try receipt(h, survivors: fault == "noSurvivorsRecorded" ? [] : [fault == "stillAlive" ? alive : gone])
        var record = initial
        let p = try #require(record.stopProof)
        switch fault {
        case "remote":
            var proof = RuntimeExecutionStopProof(executionID: p.executionID, process: p.process, reaped: true, processGroupEmpty: true,
                toolsStopped: false, remoteWorkExcluded: false, capturedAt: p.capturedAt)
            proof.localSurvivors = p.localSurvivors
            record.stopProof = proof
        case "inherited": record.inheritedToolUncertainty = true
        case "settlement": record.settlementInProgress = true
        case "settlementTools": record.settlementToolsStopped = false
        case "cancelled": record.cancellationRequested = true
        case "unfinished": record.state = .unverified
        case "execution": record.executionID = UUID()
        case "liveProvider": record.providerProcess = alive.process
        default: break
        }
        var asked = 0
        let repaired = RuntimeHostNoToolReceiptReconciliation.reobserved(record) { launch in
            asked += 1
            #expect(launch == p.localSurvivors?.launch)
            switch fault {
            case "newDescendant": return .init(launch: launch, observedAt: Date(), complete: true, survivors: [alive])
            case "unreadable": return .init(launch: launch, observedAt: Date(), complete: false, survivors: [])
            default: return .init(launch: launch, observedAt: Date(), complete: true, survivors: [])
            }
        }
        if fault == "valid" {
            let repaired = try #require(repaired)
            #expect(repaired.canReplace && repaired.resourcesReleased == true && asked == 1)
            #expect(repaired.hostNoToolReconciliationOriginalProof == p)
            #expect(repaired.stopProof?.toolsStopped == true && repaired.stopProof?.localSurvivors?.clean == true)
            #expect(repaired.limits == record.limits && repaired.executionID == record.executionID)
        } else {
            #expect(repaired == nil)
            // The process table is not consulted while a recorded survivor is alive or a gate already fails.
            #expect(asked == (["newDescendant", "unreadable"].contains(fault) ? 1 : 0))
        }
    }

    @Test("Admission names the survivor while it runs and releases the workspace once it is gone")
    func admissionReleasesAfterSurvivorExits() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let process = try await Self.finished("/usr/bin/perl", ["-e", Self.daemon])
        let proof = try #require(process.stopProof(executionID: UUID(), toolsStopped: false, remoteWorkExcluded: true,
            observingLocalSurvivors: true))
        let observed = try #require(proof.localSurvivors)
        do {
            try #require(observed.survivors.count == 1)
            let (task, record) = try receipt(h, survivors: [], observed: proof)
            let store = RuntimeExecutionOwner.store(in: h.context)
            var lease: RuntimeExecutionOwnerStore.Lease? = try store.acquire(taskID: task.id)
            try lease?.save(record)
            lease = nil

            let queue = TaskQueue(poolSize: 0)
            queue.refreshResourceOwnership(in: h.context)
            let other = h.makeTask(runtime: .copilotCLI, goal: "Next", model: "test")
            let claims = queue.resourceLockClaims(for: nil, task: other, runMode: "task")
            #expect(!queue.canAcquireResourceLocks(claims))
            let waiting = queue.resourceBlockerSummary(claims, modelContext: h.context)
            #expect(waiting.contains("running") && waiting.contains("process \(observed.survivors[0].process.pid)"))
            #expect(try store.read(taskID: task.id) == record)

            try await Self.stop(observed.survivors)
            queue.refreshResourceOwnership(in: h.context)
            let released = try #require(try store.read(taskID: task.id))
            #expect(released.resourcesReleased == true && released.canReplace)
            #expect(released.hostNoToolReconciliationOriginalProof == record.stopProof)
            #expect(queue.canAcquireResourceLocks(claims))
        } catch { try await Self.stop(observed.survivors); throw error }
    }
}
