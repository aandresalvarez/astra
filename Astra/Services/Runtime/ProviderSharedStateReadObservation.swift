import Darwin
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A reader may use session-local settings after all of a legacy owner's local
/// executions predate this Mac's boot. This does not release any writer claim.
struct ProviderSharedStateReadObservation: Codable, Equatable, Sendable {
    let executionID: UUID
    let retainedHead: UUID?
    let legacyKey: String
    let bootedAt: Date

    func covers(_ writer: RuntimeExecutionOwnerRecord, heldBy owner: RuntimeExecutionOwnerRecord,
                requested key: AgentRuntimeSharedStateKey) -> Bool {
        owner.executionID == executionID && owner.retainedExecutionHead == retainedHead
            && owner.state == .finished && owner.cancellationRequested != true
            && owner.settlementInProgress == false && owner.sessionVerificationPending != true
            && owner.pendingSSHJobSetDigest == nil
            && key.runtimeName == AgentRuntimeID.antigravityCLI.rawValue && key.filePath != nil
            && legacyKey.hasPrefix("antigravity_cli:/") && writer.providerSharedStateKey == legacyKey
            && writer.runtime == key.runtimeName && Self.endedLocally(writer, before: bootedAt)
    }

    static func hostBootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout.size(ofValue: boot)
        var launchd = kinfo_proc()
        var processSize = MemoryLayout.size(ofValue: launchd)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, 1]
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, boot.tv_sec > 0,
              sysctl(&mib, 4, &launchd, &processSize, nil, 0) == 0, processSize == MemoryLayout<kinfo_proc>.size,
              launchd.kp_proc.p_pid == 1, launchd.kp_proc.p_un.__p_starttime.tv_sec > 0 else { return nil }
        // Use the earlier boundary. A clock adjustment that moves the kernel's
        // estimate past launchd's recorded start must not broaden eligibility.
        let seconds = min(boot.tv_sec, launchd.kp_proc.p_un.__p_starttime.tv_sec)
        let boundary = Date(timeIntervalSince1970: TimeInterval(seconds))
        return boundary < Date() ? boundary : nil
    }

    static func endedLocally(_ record: RuntimeExecutionOwnerRecord, before boot: Date) -> Bool {
        guard record.state == .finished || record.state == .stopped || record.state == .unverified,
              record.sessionVerificationPending != true, record.cancellationRequested != true,
              record.pendingSSHJobSetDigest == nil,
              record.settlementInProgress == false, record.settlementLocalWorkStopped == true,
              record.settlementToolsStopped == true, let proof = record.stopProof,
              proof.executionID == record.executionID, proof.process == record.providerProcess,
              proof.reaped, proof.processGroupEmpty, proof.remoteWorkExcluded,
              proof.process.pid > 1, record.appProcess.pid > 1,
              record.appProcess.startedSeconds > 0, proof.process.startedSeconds >= record.appProcess.startedSeconds,
              proof.capturedAt.timeIntervalSince1970 >= Double(proof.process.startedSeconds),
              proof.capturedAt < boot, proof.process.presence == .absent,
              record.appProcess.presence == .absent else { return false }
        return true
    }

    @MainActor
    static func reconcile(_ block: RuntimeProviderResourceRegistry.Block, in context: ModelContext,
                          bootedAt: Date?) throws -> Bool {
        let store = RuntimeExecutionOwner.store(in: context)
        guard block.legacyIdentity, !block.missingClaims, block.key.filePath != nil,
              block.key.runtimeName == AgentRuntimeID.antigravityCLI.rawValue,
              store.root.path == block.journalRoot, let bootedAt else { return false }
        let admission = try store.acquireAdmission()
        defer { withExtendedLifetime(admission) {} }
        let taskID = block.taskID
        let tasks = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
        let candidates = try store.records().filter { $0.taskID == taskID && $0.ownerID == block.ownerID }
        guard candidates.count == 1, let candidate = candidates.first,
              let owner = tasks.first(where: { $0.persistentModelID == candidate.taskOwnerID }) else { return false }
        let lease = try RuntimeTaskOwnerJournal.acquire(task: owner, context: context)
        defer { withExtendedLifetime(lease) {} }
        guard var record = try lease.read(), record == candidate, record.resourcesReleased == false,
              record.providerSharedStateReleased != true, record.resourceClaims != nil,
              owner.status == .completed, record.state == .finished, let runID = record.runID,
              let latest = owner.runs.max(by: { $0.startedAt < $1.startedAt }),
              latest.id == runID, latest.status == .completed, latest.typedStopReason == .completed,
              !owner.runs.contains(where: { $0.status == .running }),
              try TaskTurnRequestRepository.activeRequests(for: owner, in: context).isEmpty,
              journalPredatesBoot(lease.recordURL, bootedAt: bootedAt) else { return false }
        let history = try store.retainedExecutions(of: record) + [record]
        let keys = Set(history.flatMap { ($0.retainedProviderSharedStateKeys ?? []) + [$0.providerSharedStateKey].compactMap { $0 } })
        guard keys.count == 1, let legacyKey = keys.first, legacyKey.hasPrefix("antigravity_cli:/"),
              history.contains(where: { $0.providerSharedStateKey == legacyKey }),
              noRemoteRegistrations(for: owner.id, store: store) else { return false }
        let runs = Dictionary(grouping: owner.runs, by: \.id)
        var boundRuns = Set<UUID>()
        for execution in history {
            // A missing directory does not discharge a saved remote-work inventory.
            guard execution.taskOwnerID == owner.persistentModelID, execution.sessionVerificationPending != true,
                  execution.pendingSSHJobSetDigest == nil,
                  execution.resourceClaims != nil, let id = execution.runID, boundRuns.insert(id).inserted,
                  let matches = runs[id], matches.count == 1, let run = matches.first, run.runtimeID == execution.runtime,
                  let ended = run.completedAt, run.status != .running, run.startedAt <= ended, ended < bootedAt,
                  let json = run.executionEnvironmentSnapshotJSON,
                  let environment = try? JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: Data(json.utf8)),
                  environment.isHost else { return false }
            if execution.state == .notStarted {
                guard execution.provesNoProviderLaunch(for: run), execution.providerSharedStateKey == nil,
                      execution.providerSharedStateReleased != false, execution.settlementInProgress != true,
                      execution.settlementLocalWorkStopped != false, execution.settlementToolsStopped != false else { return false }
            } else if !endedLocally(execution, before: bootedAt) { return false }
        }
        let observation = Self(executionID: record.executionID, retainedHead: record.retainedExecutionHead,
                               legacyKey: legacyKey, bootedAt: bootedAt)
        record.legacyProviderReadObservation = observation
        // The existing lineage check must account for every inherited writer,
        // including a history with a missing original claim.
        guard !RuntimeProviderResourceRegistry.conflicts(block.key, record: record, checkingHistoryIn: store) else { return false }
        // Persist the verification before publishing the journal's permission.
        // An interrupted publication can repeat the check without duplicating the event.
        let type = TaskEventTypes.System.legacyProviderReaderVerified
        if !TaskHistoryRead.events(for: owner, ofTypes: [type.rawValue]).contains(where: {
            $0.run?.id == runID && (try? JSONDecoder().decode(Self.self, from: Data($0.payload.utf8))) == observation
        }) {
            let payload = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
            let event = TaskEvent(task: owner, eventType: type, payload: payload, run: latest)
            context.insert(event)
            do {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: owner.workspace, modelContext: context,
                    taskID: taskID, auditFields: ["operation": "verify_legacy_provider_reader_after_boot"])
            } catch { context.delete(event); throw error }
        }
        try lease.save(record)
        return true
    }

    static func journalPredatesBoot(_ url: URL, bootedAt: Date) -> Bool {
        var info = stat(), fs = statfs()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_ctimespec.tv_sec > 0, statfs(url.path, &fs) == 0,
              fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return false }
        return TimeInterval(info.st_ctimespec.tv_sec) + 1 <= bootedAt.timeIntervalSince1970
    }

    static func noRemoteRegistrations(for taskID: UUID, store: RuntimeExecutionOwnerStore) -> Bool {
        let directory = store.root.deletingLastPathComponent().appendingPathComponent("remote-jobs")
        var info = stat()
        if lstat(directory.path, &info) != 0 { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFDIR else { return false }
        return lstat(directory.appendingPathComponent(taskID.uuidString).path, &info) != 0 && errno == ENOENT
    }
}
