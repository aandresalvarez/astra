import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// A leaked pre-isolation fixture left a legacy pointer whose journal folder
/// was later purged. Admission must keep refusing it; only the person may
/// release it, and only on evidence observed from the disk and the kernel.
@Suite("Reviewed release of unverifiable provider reservations", .serialized)
struct ProviderReservationReviewTests {
    private struct Planted {
        let name: String
        let pointer: URL
        let lock: URL
        var bytes: Data
    }

    private static let afterRestart = Date().addingTimeInterval(3_600)

    private func plant(in fixture: ProviderCoordinationFixture, journalRoot: String? = nil, lock: Bool = true,
                       bytes override: Data? = nil, mode: Int = 0o600) throws -> Planted {
        _ = try ProviderSharedStateDirectory(fixture.coordination)
        let lockName = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        #expect(ProviderSharedStateCompatibility.isLegacyLock(lockName))
        let lockURL = fixture.coordination.appendingPathComponent(lockName)
        if lock {
            try Data().write(to: lockURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        }
        let reference = RuntimeProviderOwnershipReference(
            journalRoot: journalRoot ?? fixture.data.appendingPathComponent("purged-journal-" + UUID().uuidString).path,
            taskID: UUID(), ownerID: UUID())
        let bytes = try override ?? JSONEncoder().encode(reference)
        let pointer = lockURL.appendingPathExtension("json")
        try bytes.write(to: pointer)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: pointer.path)
        return Planted(name: lockName + ".json", pointer: pointer, lock: lockURL, bytes: bytes)
    }

    private func fileKey(_ fixture: ProviderCoordinationFixture) throws -> AgentRuntimeSharedStateKey {
        try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: fixture.data.appendingPathComponent("profile/settings.json"))
    }

    @Test("Admission refuses a pointer whose journal is gone until the person continues past it; the pointer moves intact beside a manifest")
    func reviewedRelease() async throws {
        let fixture = try ProviderCoordinationFixture()
        let leaked = try plant(in: fixture)
        let key = try fileKey(fixture)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: fixture.coordination, registeredStoreRoots: [])
        await #expect(throws: ProviderSharedStateCompatibility.UnreadableReservation.self) { _ = try await gate.acquire(key) }
        #expect(try Data(contentsOf: leaked.pointer) == leaked.bytes)

        let findings = try ProviderReservationReview.inspect(root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(findings.releasable.map(\.name) == [leaked.name] && findings.holders.isEmpty && findings.unexamined == 0)
        #expect(findings.releasable.first?.bytes == leaked.bytes && findings.releasable.first?.predatesRestart == true)
        // Inspecting is read-only: the launch is still refused.
        #expect(try Data(contentsOf: leaked.pointer) == leaked.bytes)
        await #expect(throws: ProviderSharedStateCompatibility.UnreadableReservation.self) { _ = try await gate.acquire(key) }

        let taskID = UUID(), reviewID = UUID()
        let receipt = try ProviderReservationReview.release(findings.releasable, requestedBy: taskID, reviewID: reviewID,
            root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(receipt.released == 1 && receipt.preserved == 0)
        let audit = URL(fileURLWithPath: receipt.auditPath, isDirectory: true)
        #expect(audit.lastPathComponent == "released-" + reviewID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: leaked.pointer.path))
        #expect(try Data(contentsOf: audit.appendingPathComponent(leaked.name)) == leaked.bytes)
        #expect(FileManager.default.fileExists(atPath: leaked.lock.path))
        let manifest = try String(contentsOf: audit.appendingPathComponent("review.json"), encoding: .utf8)
        #expect(manifest.contains(taskID.uuidString) && manifest.contains(leaked.name))

        let lease = try await gate.acquire(key)
        await gate.release(lease)
        // The audit folder is not a reservation and never stands in a later launch's way.
        #expect(try ProviderReservationReview.inspect(root: fixture.coordination, restartedAt: Self.afterRestart).isClear)
    }

    @Test("A pointer that is in use, unsafe, malformed or on an absent volume is never offered or moved", arguments: [
        "journal-without-record", "lock-held", "lock-missing", "unmounted-volume", "malformed", "group-readable"
    ])
    func unexamined(fault: String) throws {
        let fixture = try ProviderCoordinationFixture()
        let journal = fixture.data.appendingPathComponent("journal-" + UUID().uuidString, isDirectory: true)
        var held: Int32 = -1
        defer { if held >= 0 { close(held) } }
        let planted: Planted
        switch fault {
        case "journal-without-record":
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            planted = try plant(in: fixture, journalRoot: journal.path)
        case "lock-held":
            planted = try plant(in: fixture)
            held = open(planted.lock.path, O_RDWR | O_CLOEXEC)
            #expect(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
        case "lock-missing":
            planted = try plant(in: fixture, lock: false)
        case "unmounted-volume":
            planted = try plant(in: fixture, journalRoot: "/Volumes/astra-absent-" + UUID().uuidString + "/runtime-owners")
        case "malformed":
            planted = try plant(in: fixture, bytes: Data("{invalid ownership reference".utf8))
        default:
            planted = try plant(in: fixture, mode: 0o640)
        }
        let findings = try ProviderReservationReview.inspect(root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(findings.releasable.isEmpty && findings.holders.isEmpty && findings.unexamined == 1)

        // A request naming it anyway is examined again and moves nothing.
        let forged = ProviderReservationReview.Candidate(name: planted.name, bytes: planted.bytes,
            journalRoot: journal.path, changedAt: .distantPast, predatesRestart: true)
        let receipt = try ProviderReservationReview.release([forged], requestedBy: nil, root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(receipt.released == 0 && receipt.preserved == 1)
        #expect(try Data(contentsOf: planted.pointer) == planted.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: receipt.auditPath) == ["review.json"])
    }

    @Test("A pointer whose journal still reads belongs to its own task: held while unreleased, clear once released, never offered")
    @MainActor
    func journalIsAuthority() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Holder", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        RuntimeProviderResourceRegistry.unregister(store.root)
        let old = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "older-profile")
        record.providerSharedStateKey = old.rawValue; record.providerSharedStateReleased = false; record.resourcesReleased = false
        func save() throws { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        try save()
        let root = h.providerLockRoot
        do {
            let lease = try await ProviderSharedStateProcessLock.acquire(old, root: root)
            try lease.handoff(old, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID)) {}
        }
        let pointer = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let bytes = try Data(contentsOf: pointer)

        let held = try ProviderReservationReview.inspect(root: root, restartedAt: Self.afterRestart)
        #expect(held.releasable.isEmpty && held.unexamined == 0)
        #expect(held.holders == [.init(taskID: task.id, journalRoot: store.root.path)])
        let forged = ProviderReservationReview.Candidate(name: pointer.lastPathComponent, bytes: bytes,
            journalRoot: store.root.path, changedAt: .distantPast, predatesRestart: true)
        #expect(try ProviderReservationReview.release([forged], requestedBy: nil, root: root, restartedAt: Self.afterRestart).released == 0)
        #expect(try Data(contentsOf: pointer) == bytes)

        record.providerSharedStateReleased = true
        try save()
        #expect(try ProviderReservationReview.inspect(root: root, restartedAt: Self.afterRestart).isClear)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("A pointer rewritten after the person reviewed it stays reserved")
    func changedAfterReview() throws {
        let fixture = try ProviderCoordinationFixture()
        let leaked = try plant(in: fixture)
        let untouched = try plant(in: fixture)
        let findings = try ProviderReservationReview.inspect(root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(findings.releasable.count == 2)
        let replacement = try JSONEncoder().encode(RuntimeProviderOwnershipReference(
            journalRoot: fixture.data.appendingPathComponent("another-purged-journal").path, taskID: UUID(), ownerID: UUID()))
        try replacement.write(to: leaked.pointer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leaked.pointer.path)

        let receipt = try ProviderReservationReview.release(findings.releasable, requestedBy: nil,
            root: fixture.coordination, restartedAt: Self.afterRestart)
        #expect(receipt.released == 1 && receipt.preserved == 1)
        #expect(try Data(contentsOf: leaked.pointer) == replacement)
        #expect(!FileManager.default.fileExists(atPath: untouched.pointer.path))
    }

    @Test("A pointer written since this Mac's own last restart is offered with the stronger warning, never presented as safe")
    func hostRestartBoundary() throws {
        let fixture = try ProviderCoordinationFixture()
        let recent = try plant(in: fixture)
        let findings = try ProviderReservationReview.inspect(root: fixture.coordination)
        #expect(try #require(findings.restartedAt) < Date())
        #expect(findings.releasable.map(\.predatesRestart) == [false])
        let warning = ProviderReservationReview.guidance(for: findings, provider: "Antigravity")
        #expect(warning.detail.contains("may still be running here") && !warning.detail.contains("nothing from"))
        // With no restart time to compare against, nothing is presented as predating one.
        let unknown = try ProviderReservationReview.inspect(root: fixture.coordination, restartedAt: nil)
        #expect(unknown.releasable.map(\.predatesRestart) == [false] && unknown.restartedAt == nil)
        #expect(ProviderReservationReview.guidance(for: unknown, provider: "Antigravity").detail.contains("may still be running here"))
        #expect(try Data(contentsOf: recent.pointer) == recent.bytes)
    }

    @Test("The warning states what holds the settings, what is known, and what continuing does")
    func guidance() {
        func candidate(_ predatesRestart: Bool) -> ProviderReservationReview.Candidate {
            .init(name: "a.json", bytes: Data(), journalRoot: "/gone", changedAt: .distantPast, predatesRestart: predatesRestart)
        }
        var findings = ProviderReservationReview.Findings(restartedAt: Date(timeIntervalSince1970: 1_793_814_007))
        findings.releasable = [candidate(true), candidate(true)]
        findings.holders = [.init(taskID: UUID(), journalRoot: "/journal")]
        findings.unexamined = 1
        let ask = ProviderReservationReview.guidance(for: findings, provider: "Antigravity", holderTitle: "Nightly import")
        #expect(ask.title == "An earlier Antigravity run may still be active")
        #expect(ask.detail.contains("2 earlier reservations still hold Antigravity's shared settings"))
        #expect(ask.detail.contains("nothing from those runs is still running here") && ask.detail.contains("another machine"))
        #expect(ask.detail.contains("If you continue, ASTRA sets these reservations aside and starts this task"))
        #expect(ask.detail.contains("not deleted") && ask.detail.contains("both will use the same settings file"))
        #expect(ask.detail.contains("held by “Nightly import” stays in place") && ask.detail.contains("1 more could not be examined and stays in place"))

        findings.releasable = [candidate(true), candidate(false)]
        #expect(ProviderReservationReview.guidance(for: findings, provider: "Antigravity").detail
            .contains("1 of them was written since this Mac last restarted, so an earlier process may still be running here"))

        findings.releasable = []
        let held = ProviderReservationReview.guidance(for: findings, provider: "Antigravity", holderTitle: "Nightly import")
        #expect(held.title == "Another task holds Antigravity's shared settings")
        #expect(held.detail.contains("“Nightly import” reserved them") && held.detail.contains("Open that task"))
        let foreign = ProviderReservationReview.guidance(for: findings, provider: "Antigravity")
        #expect(foreign.detail.contains("another ASTRA app or store") && foreign.detail.contains("/journal"))

        findings.holders = []
        let busy = ProviderReservationReview.guidance(for: findings, provider: "Antigravity")
        #expect(busy.title == "Reservations could not be examined" && busy.detail.contains("1 reservation is in use right now"))
    }
}

@MainActor
@Suite("Continuing past an earlier provider reservation from the decision dock")
struct ProviderReservationReviewDockTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [[ProviderReservationReview.Candidate]] = []
        func append(_ candidates: [ProviderReservationReview.Candidate]) { lock.withLock { value.append(candidates) } }
        var all: [[ProviderReservationReview.Candidate]] { lock.withLock { value } }
    }

    private let candidate = ProviderReservationReview.Candidate(name: "a.json", bytes: Data("a".utf8), journalRoot: "/gone",
        changedAt: .distantPast, predatesRestart: true)

    private func findings(releasable: [ProviderReservationReview.Candidate] = [], holders: [ProviderReservationReview.Holder] = [],
                          unexamined: Int = 0) -> ProviderReservationReview.Findings {
        var findings = ProviderReservationReview.Findings(restartedAt: .distantPast)
        findings.releasable = releasable; findings.holders = holders; findings.unexamined = unexamined
        return findings
    }

    @Test("The warning only reports; Continue sets aside exactly the reviewed pointers once, records it on the task, then continues")
    func confirmedContinue() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Blocked", model: "test")
        let calls = Calls()
        let reviewed = findings(releasable: [candidate])
        let presentation = TaskRepairActionPresentation(
            inspect: { reviewed },
            release: { candidates, taskID in
                calls.append(candidates)
                return .init(released: candidates.count, preserved: 0, auditPath: "/audit/released-" + taskID.uuidString)
            })
        var continued = 0
        await presentation.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        #expect(presentation.notice?.releasable == [candidate] && presentation.notice?.holderTaskID == nil)
        #expect(presentation.notice?.guidance.title == "An earlier Google Antigravity CLI run may still be active"
            || presentation.notice?.guidance.title.hasSuffix("run may still be active") == true)
        #expect(calls.all.isEmpty && continued == 0)

        await presentation.confirmContinue()?.value
        #expect(calls.all == [[candidate]] && continued == 1)
        #expect(presentation.notice == nil)
        let recorded = task.events.filter { $0.type == TaskEventTypes.System.info.rawValue }.map(\.payload)
        #expect(recorded.count == 1)
        #expect(recorded.first?.contains("continued past 1 earlier provider reservation") == true)
        #expect(recorded.first?.contains("/audit/released-" + task.id.uuidString) == true)
        // Nothing is left to confirm a second time.
        #expect(presentation.confirmContinue() == nil && continued == 1)
    }

    @Test("Cancel sets nothing aside and does not continue; a move that changed nothing says so, with no record and no continue")
    func declinedAndEmpty() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Blocked", model: "test")
        let calls = Calls()
        let reviewed = findings(releasable: [candidate])
        let presentation = TaskRepairActionPresentation(
            inspect: { reviewed },
            release: { candidates, _ in calls.append(candidates); return .init(released: 0, preserved: candidates.count, auditPath: "/audit") })
        var continued = 0
        await presentation.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        presentation.dismiss()
        #expect(presentation.confirmContinue() == nil && calls.all.isEmpty && continued == 0)

        await presentation.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        await presentation.confirmContinue()?.value
        #expect(calls.all.count == 1 && continued == 0)
        #expect(presentation.notice?.guidance.title == "Nothing was released" && presentation.notice?.releasable.isEmpty == true)
        #expect(task.events.allSatisfy { $0.type != TaskEventTypes.System.info.rawValue })
    }

    @Test("With nothing reviewable in the way the task continues at once, and an unreadable folder changes nothing")
    func clearAndUnreadable() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Blocked", model: "test")
        let clear = findings()
        var continued = 0
        let open = TaskRepairActionPresentation(inspect: { clear },
            release: { _, _ in Issue.record("Nothing was reviewed"); throw RuntimeExecutionOwnerStore.Failure.busy })
        await open.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        #expect(open.notice == nil && continued == 1)

        let unreadable = TaskRepairActionPresentation(inspect: { throw RuntimeExecutionOwnerStore.Failure.unsafePath },
            release: { _, _ in Issue.record("Nothing was reviewed"); throw RuntimeExecutionOwnerStore.Failure.busy })
        await unreadable.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        #expect(unreadable.notice?.guidance == ProviderReservationReview.unreadableGuidance)
        #expect(unreadable.confirmContinue() == nil && continued == 1)
    }

    @Test("A reservation another task still holds offers to open that task, never to continue past it")
    func heldByAnotherTask() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Blocked", model: "test")
        let owner = h.makeTask(runtime: .antigravityCLI, goal: "Nightly import", model: "test")
        try h.context.save()
        let ownerID = owner.id
        let held = findings(holders: [.init(taskID: UUID(), journalRoot: "/elsewhere"), .init(taskID: ownerID, journalRoot: "/journal")])
        var opened: [UUID] = []
        var continued = 0
        let presentation = TaskRepairActionPresentation(inspect: { held },
            release: { _, _ in Issue.record("A held reservation cannot be set aside"); throw RuntimeExecutionOwnerStore.Failure.busy },
            open: { opened.append($0) })
        await presentation.start(.reviewProviderReservations, events: [], runID: nil, task: task) { continued += 1 }.value
        #expect(presentation.notice?.holderTaskID == ownerID && presentation.notice?.releasable.isEmpty == true)
        #expect(presentation.notice?.guidance.title.hasPrefix("Another task holds") == true)
        #expect(presentation.notice?.guidance.detail.contains(owner.title) == true)
        #expect(presentation.confirmContinue() == nil)
        presentation.openHolder()
        #expect(opened == [ownerID] && presentation.notice == nil && continued == 0)
    }
}
