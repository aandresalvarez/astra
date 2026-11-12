import Darwin
import Foundation
import SwiftData
import ASTRALogging
import ASTRAModels

/// What the person sees, and may decide, when older legacy ownership pointers
/// stand in front of a launch. Admission never calls this and stays read-only.
/// A pointer the person continues past is moved beside a manifest, never
/// rewritten or deleted; its lock and every journal stay put.
enum ProviderReservationReview {
    /// A pointer whose journal folder no longer exists: nothing can ever settle it.
    struct Candidate: Equatable, Sendable {
        let name: String
        let bytes: Data
        let journalRoot: String
        let changedAt: Date
        /// A restart ended every local process from before it. It says nothing
        /// about another machine, and its absence is told to the person.
        let predatesRestart: Bool
    }

    /// A pointer whose journal still reads as unreleased. Only its own task can settle it.
    struct Holder: Equatable, Sendable {
        let taskID: UUID
        let journalRoot: String
    }

    struct Findings: Equatable, Sendable {
        var releasable: [Candidate] = []
        var holders: [Holder] = []
        /// In use right now, unsafe, malformed, or with a journal that cannot be read.
        var unexamined = 0
        var restartedAt: Date?
        var isClear: Bool { releasable.isEmpty && holders.isEmpty && unexamined == 0 }
    }

    struct Receipt: Equatable, Sendable {
        let released: Int
        /// Reviewed candidates that changed or became busy before their move.
        let preserved: Int
        let auditPath: String
    }

    private enum Standing {
        case releasable(Candidate), holder(Holder), settled, unexamined
    }

    static func inspect(root override: URL? = nil,
                        restartedAt: Date? = ProviderSharedStateReadObservation.hostBootTime()) throws -> Findings {
        let directory = try ProviderSharedStateDirectory(ProviderSharedStateNamespace.resolve(override: override), createIfMissing: false)
        var findings = Findings(restartedAt: restartedAt)
        for name in try pointerNames(in: directory) {
            switch examine(name, in: directory, restartedAt: restartedAt, whileLocked: { $0 }) {
            case .releasable(let candidate): findings.releasable.append(candidate)
            case .holder(let holder): findings.holders.append(holder)
            case .unexamined: findings.unexamined += 1
            case .settled: break
            }
        }
        return findings
    }

    /// Each candidate is examined again under its lock and must still be the
    /// exact pointer the person reviewed. The manifest is durable before any move.
    static func release(_ candidates: [Candidate], requestedBy taskID: UUID?, reviewID: UUID = UUID(), root override: URL? = nil,
                        restartedAt: Date? = ProviderSharedStateReadObservation.hostBootTime()) throws -> Receipt {
        guard !candidates.isEmpty else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        let directory = try ProviderSharedStateDirectory(ProviderSharedStateNamespace.resolve(override: override), createIfMissing: false)
        let auditName = "released-" + reviewID.uuidString
        guard mkdirat(directory.descriptor, auditName, 0o700) == 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        let audit = openat(directory.descriptor, auditName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard audit >= 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        defer { close(audit) }
        try save(Manifest(reviewID: reviewID, reviewedAt: Date(), restartedAt: restartedAt, requestedByTaskID: taskID,
                          candidates: candidates.map {
                              .init(name: $0.name, journalRoot: $0.journalRoot, changedAt: $0.changedAt, predatesRestart: $0.predatesRestart)
                          }), in: audit)
        var released = 0
        for expected in candidates {
            released += examine(expected.name, in: directory, restartedAt: restartedAt) { standing in
                guard case .releasable(let current) = standing, current == expected,
                      renameat(directory.descriptor, current.name, audit, current.name) == 0 else { return 0 }
                return 1
            }
        }
        // The moves already happened; report them even if flushing the directories fails.
        _ = fsync(audit); _ = fsync(directory.descriptor)
        return Receipt(released: released, preserved: candidates.count - released,
                       auditPath: directory.url.appendingPathComponent(auditName, isDirectory: true).path)
    }

    private static func pointerNames(in directory: ProviderSharedStateDirectory) throws -> [String] {
        try directory.names().filter { $0.hasSuffix(".json") && ProviderSharedStateCompatibility.isLegacyLock(String($0.dropLast(5))) }.sorted()
    }

    /// Everything is observed on disk or from the kernel. `body` runs while the
    /// pointer's own lock is held whenever the standing is `.releasable`.
    /// Nothing is inferred from where a journal used to live.
    private static func examine<T>(_ name: String, in directory: ProviderSharedStateDirectory, restartedAt: Date?,
                                   whileLocked body: (Standing) -> T) -> T {
        let lockName = String(name.dropLast(5))
        let lock = openat(directory.descriptor, lockName, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard lock >= 0 else { return body(.unexamined) }
        defer { close(lock) }
        func lockIsPrivate() -> Bool {
            (try? directory.verifiedLock(lock, named: lockName)).map { $0.st_mode & 0o077 == 0 } ?? false
        }
        guard lockIsPrivate(), flock(lock, LOCK_EX | LOCK_NB) == 0, lockIsPrivate(),
              let pointer = try? RuntimeProviderOwnershipReference.contents(in: directory, name: name),
              pointer.reference.journalRoot.hasPrefix("/") else { return body(.unexamined) }
        let root = pointer.reference.journalRoot
        var journal = stat()
        guard lstat(root, &journal) != 0, errno == ENOENT else {
            // The journal is the only release authority while it can be read.
            guard let record = try? pointer.reference.journalRecord() else { return body(.unexamined) }
            let released = record.resourcesReleased == true || record.providerSharedStateReleased == true || record.canRecoverPreparation
            return body(released ? .settled : .holder(Holder(taskID: record.taskID, journalRoot: root)))
        }
        // An unmounted volume also reads as missing, and can come back.
        guard !root.hasPrefix("/Volumes/") else { return body(.unexamined) }
        // The later inode time cannot be moved back by rewriting the modification date.
        func seconds(_ time: timespec) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000 }
        let changed = max(seconds(pointer.info.st_mtimespec), seconds(pointer.info.st_ctimespec))
        return body(.releasable(Candidate(name: name, bytes: pointer.bytes, journalRoot: root,
            changedAt: Date(timeIntervalSince1970: changed),
            predatesRestart: restartedAt.map { changed < $0.timeIntervalSince1970 } ?? false)))
    }

    private struct Manifest: Encodable {
        struct Entry: Encodable { let name: String; let journalRoot: String; let changedAt: Date; let predatesRestart: Bool }
        let reviewID: UUID
        let reviewedAt: Date
        let restartedAt: Date?
        let requestedByTaskID: UUID?
        var criteria = "journal root absent; lock idle; the person was told whether each pointer predates the last restart and chose to continue"
        let candidates: [Entry]
    }

    private static func save(_ manifest: Manifest, in audit: Int32) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let fd = openat(audit, "review.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        defer { close(fd) }
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0 else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
    }
}

extension ProviderReservationReview {
    static let unreadableGuidance = TaskRepairAction.Guidance(title: "Reservations could not be reviewed",
        detail: "ASTRA could not read the reservation folder. Nothing was changed.")

    /// The warning: what holds the settings, what is known about it, and what
    /// continuing does. `holderTitle` names the first holder this store can open.
    static func guidance(for findings: Findings, provider: String, holderTitle: String? = nil) -> TaskRepairAction.Guidance {
        let count = findings.releasable.count
        guard count > 0 else {
            guard let holder = findings.holders.first else {
                return .init(title: "Reservations could not be examined",
                    detail: "\(findings.unexamined.formatted()) \(noun(findings.unexamined)) \(findings.unexamined == 1 ? "is" : "are") in use right now or cannot be read, so nothing was changed. Try again when no other ASTRA task is starting.")
            }
            let others = findings.holders.count == 1 ? "" : " \((findings.holders.count - 1).formatted()) more \(findings.holders.count == 2 ? "task holds a reservation" : "tasks hold reservations") too."
            return .init(title: "Another task holds \(provider)'s shared settings", detail: holderTitle.map {
                "“\($0)” reserved them, and ASTRA has not confirmed that its run stopped. Open that task to stop it or let it finish, then continue here.\(others)"
            } ?? "A task in another ASTRA app or store on this Mac reserved them, and ASTRA has not confirmed that its run stopped. Its records are in \(holder.journalRoot). Stop that task or let it finish, then continue here.\(others)")
        }
        let one = count == 1
        let recent = findings.releasable.filter { !$0.predatesRestart }.count
        let held = one
            ? "An earlier reservation still holds \(provider)'s shared settings. Its ownership record is gone, so ASTRA cannot confirm that run stopped."
            : "\(count.formatted()) earlier reservations still hold \(provider)'s shared settings. Their ownership records are gone, so ASTRA cannot confirm those runs stopped."
        let evidence: String
        if recent == 0, let restartedAt = findings.restartedAt {
            evidence = "This Mac restarted after \(one ? "it was" : "they were") written (\(restartedAt.formatted(date: .abbreviated, time: .shortened))), so nothing from \(one ? "that run" : "those runs") is still running here. Work left running on another machine cannot be ruled out."
        } else {
            let which = recent == count ? (one ? "It was" : "They were") : "\(recent.formatted()) of them \(recent == 1 ? "was" : "were")"
            evidence = "\(which) written since this Mac last restarted, so an earlier process may still be running here or on another machine."
        }
        var kept = ""
        if !findings.holders.isEmpty {
            kept += findings.holders.count == 1 ? " A reservation held by \(holderTitle.map { "“\($0)”" } ?? "another task") stays in place."
                : " \(findings.holders.count.formatted()) reservations held by other tasks stay in place."
        }
        if findings.unexamined > 0 {
            kept += " \(findings.unexamined.formatted()) more could not be examined and \(stays(findings.unexamined)) in place."
        }
        return .init(title: "An earlier \(provider) run may still be active",
            detail: "\(held) \(evidence)\n\nIf you continue, ASTRA sets \(one ? "this reservation" : "these reservations") aside and starts this task. \(one ? "Its record is" : "Their records are") moved to a separate folder, not deleted. If an earlier run is still active, both will use the same settings file.\(kept)")
    }

    /// Shown only when nothing moved; a release is reported in the thread.
    static func guidance(for receipt: Receipt) -> TaskRepairAction.Guidance {
        .init(title: "Nothing was released",
            detail: "The \(noun(receipt.preserved)) changed or became busy after the review, so \(receipt.preserved == 1 ? "it stays" : "they stay") in place and nothing was recorded. Review them again.")
    }

    /// The task that asked keeps the durable record, even if its view has moved on.
    @MainActor
    static func record(_ receipt: Receipt, task: AgentTask) {
        guard receipt.released > 0, task.isLive, let context = task.modelContext else { return }
        AppLogger.audit(.workerProviderReservationsReleased, category: "Worker", taskID: task.id, fields: [
            "released_count": String(receipt.released),
            "preserved_count": String(receipt.preserved),
            "audit_directory": URL(fileURLWithPath: receipt.auditPath).lastPathComponent
        ])
        RuntimeExecutionOwner.report("You continued past \(receipt.released.formatted()) earlier provider \(noun(receipt.released)) that ASTRA could no longer verify. \(receipt.released == 1 ? "Its record is" : "Their records are") kept in \(receipt.auditPath).",
            task: task, context: context, autoExport: false)
    }

    private static func noun(_ count: Int) -> String { count == 1 ? "reservation" : "reservations" }
    private static func stays(_ count: Int) -> String { count == 1 ? "stays" : "stay" }
}
