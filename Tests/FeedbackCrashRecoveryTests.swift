import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Feedback Crash Recovery")
struct FeedbackCrashRecoveryTests {
    @Test("Claim is deterministic, durable, and once per fingerprint and consent version")
    @MainActor
    func deterministicOncePerConsent() async throws {
        let defaults = crashDefaults()
        let firstID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!
        let reportIDs = CrashReportIDSequence([firstID, secondID])
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { summary in String(repeating: summary.appName == "A" ? "a" : "b", count: 64) },
            makeReportID: { reportIDs.next() }
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = crashSummary(appName: "A", date: date)
        let b = crashSummary(appName: "B", date: date)
        let forward = try #require(try await service.claimOffer(from: [b, a]))
        #expect(forward.report.appName == "A")
        #expect(forward.reportID == firstID)
        #expect(try await service.claimOffer(from: [a]) == nil)

        let reversedService = FeedbackCrashOfferService(
            defaults: crashDefaults(),
            fingerprint: { summary in String(repeating: summary.appName == "A" ? "a" : "b", count: 64) }
        )
        let reversed = try #require(try await reversedService.claimOffer(from: [a, b]))
        #expect(reversed.report.appName == forward.report.appName)
        let nextConsent = try #require(try await service.claimOffer(
            from: [a],
            consentVersion: "feedback-consent-v2"
        ))
        #expect(nextConsent.fingerprint == forward.fingerprint)
    }

    @Test("Ledger transitions require the reserved report ID and are idempotent only forward")
    @MainActor
    func legalTransitions() async throws {
        let defaults = crashDefaults()
        let reportID = UUID()
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "c", count: 64) },
            makeReportID: { reportID }
        )
        let offer = try #require(try await service.claimOffer(from: [crashSummary()]))
        #expect(throws: FeedbackCrashOfferError.offerNotFound) {
            try service.confirmReportCreated(offer, reportID: UUID())
        }
        try service.confirmReportCreated(offer, reportID: reportID)
        try service.confirmReportCreated(offer, reportID: reportID)
        #expect(try service.verifiedLink(
            fingerprint: offer.fingerprint,
            consentVersion: offer.consentVersion
        )?.outcome == .reportCreated)
        #expect(throws: FeedbackCrashOfferError.illegalTransition) { try service.decline(offer) }
    }

    @Test("Decline cannot later become a report and failed writes are surfaced")
    @MainActor
    func declineAndPersistenceFailure() async throws {
        let defaults = crashDefaults()
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "d", count: 64) }
        )
        let offer = try #require(try await service.claimOffer(from: [crashSummary()]))
        try service.decline(offer)
        #expect(throws: FeedbackCrashOfferError.illegalTransition) {
            try service.confirmReportCreated(offer, reportID: offer.reportID)
        }

        let failing = FeedbackCrashOfferService(
            defaults: crashDefaults(),
            fingerprint: { _ in String(repeating: "e", count: 64) },
            writeData: { _ in false }
        )
        await #expect(throws: FeedbackCrashOfferError.persistenceFailed) {
            _ = try await failing.claimOffer(from: [crashSummary()])
        }
    }

    @Test("Declined and report-created crashes never become offers again")
    @MainActor
    func completedOutcomesNeverReoffer() async throws {
        let defaults = crashDefaults()
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { report in
                FeedbackCanonicalJSONV1.sha256Hex(Data(report.appName.utf8))
            }
        )
        let declined = try #require(try await service.claimOffer(from: [
            crashSummary(appName: "Declined")
        ]))
        try service.decline(declined)
        #expect(try await service.claimOffer(
            from: [declined.report],
            recoverableReportIDs: [declined.reportID]
        ) == nil)

        let created = try #require(try await service.claimOffer(from: [
            crashSummary(appName: "Created")
        ]))
        try service.confirmReportCreated(created, reportID: created.reportID)
        #expect(try await service.claimOffer(
            from: [created.report],
            recoverableReportIDs: [created.reportID]
        ) == nil)
    }

    @Test("Corrupt and duplicate ledger bytes fail closed instead of becoming empty")
    @MainActor
    func corruptLedgerFailsClosed() {
        let defaults = crashDefaults()
        defaults.set(Data("not-json".utf8), forKey: AppStorageKeys.feedbackCrashOfferLedger)
        let service = FeedbackCrashOfferService(defaults: defaults)
        #expect(throws: FeedbackCrashOfferError.ledgerUnavailable) {
            _ = try service.linkedReportIDs()
        }

        defaults.set(
            crashLedgerData(count: 2, duplicateKey: false, duplicateReportID: true),
            forKey: AppStorageKeys.feedbackCrashOfferLedger
        )
        #expect(throws: FeedbackCrashOfferError.ledgerUnavailable) {
            _ = try service.linkedReportIDs()
        }
        #expect(throws: FeedbackCrashOfferError.ledgerUnavailable) {
            _ = try service.verifiedLink(
                fingerprint: String(repeating: "a", count: 64),
                consentVersion: FeedbackReportFormState.consentVersion
            )
        }

        defaults.set(
            crashLedgerData(count: 2, duplicateKey: true),
            forKey: AppStorageKeys.feedbackCrashOfferLedger
        )
        #expect(throws: FeedbackCrashOfferError.ledgerUnavailable) {
            _ = try service.linkedReportIDs()
        }
    }

    @Test("Full ledger fails closed without evicting old crash claims")
    @MainActor
    func ledgerCapacityDoesNotEvict() async {
        let defaults = crashDefaults()
        let full = crashLedgerData(count: 1_000, duplicateKey: false)
        defaults.set(full, forKey: AppStorageKeys.feedbackCrashOfferLedger)
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "f", count: 64) }
        )
        await #expect(throws: FeedbackCrashOfferError.ledgerUnavailable) {
            _ = try await service.claimOffer(from: [crashSummary()])
        }
        #expect(defaults.data(forKey: AppStorageKeys.feedbackCrashOfferLedger) == full)
    }

    @Test("Fingerprint hashes the complete file and is stable across rename and mtime")
    func completeFingerprintAndMetadataStability() throws {
        let root = try crashRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = Data("Incident Identifier: ABC\nException Type: EXC_BAD_ACCESS\n".utf8)
        let firstURL = root.appendingPathComponent("ASTRA-1.crash")
        let secondURL = root.appendingPathComponent("ASTRA-2.crash")
        try (prefix + Data(repeating: 1, count: 180_000)).write(to: firstURL)
        try (prefix + Data(repeating: 2, count: 180_000)).write(to: secondURL)
        let first = summary(firstURL)
        let second = summary(secondURL)
        let firstFingerprint = try #require(FeedbackCrashFingerprint.make(first))
        #expect(firstFingerprint != FeedbackCrashFingerprint.make(second))

        let renamed = root.appendingPathComponent("renamed.crash")
        try FileManager.default.moveItem(at: firstURL, to: renamed)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
            ofItemAtPath: renamed.path
        )
        #expect(FeedbackCrashFingerprint.make(summary(renamed)) == firstFingerprint)
        let changedMetadata = CrashReportSummary(
            url: renamed,
            appName: "Renamed Product Label",
            modifiedAt: Date.distantFuture,
            sizeBytes: Int64((try Data(contentsOf: renamed)).count),
            kind: .crash
        )
        #expect(FeedbackCrashFingerprint.make(changedMetadata) == firstFingerprint)
    }

    @Test("Oversized diagnostics are rejected before any file read")
    func oversizedFileFailsBeforeRead() throws {
        let root = try crashRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.crash")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FeedbackContractLimitsV1.maximumArtifactBytes + 1))
        try handle.close()
        let reads = CrashLockedInt()

        #expect(FeedbackCrashFingerprint.make(summary(url), readData: { _, _ in
            reads.increment()
            return nil
        }) == nil)
        #expect(reads.value == 0)
    }

    @Test("A diagnostic mutated during the complete-byte read fails closed")
    func concurrentMutationDuringReadFailsClosed() throws {
        let root = try crashRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("concurrent.crash")
        try Data("Incident Identifier: BEFORE\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: url)
        let original = summary(url)

        let fingerprint = FeedbackCrashFingerprint.make(original, readData: { source, _ in
            guard let stableBytes = try? Data(contentsOf: source),
                  let handle = try? FileHandle(forWritingTo: source) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0a]))
            } catch {
                return nil
            }
            return stableBytes
        })

        #expect(fingerprint == nil)
        #expect(try Data(contentsOf: url).count == Int(original.sizeBytes) + 1)
    }

    @Test("Empty garbage symlink and hardlink diagnostics fail closed")
    func unsafeFilesFailClosed() throws {
        let root = try crashRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.crash")
        try Data().write(to: empty)
        #expect(FeedbackCrashFingerprint.make(summary(empty)) == nil)
        let garbage = root.appendingPathComponent("garbage.crash")
        try Data("garbage".utf8).write(to: garbage)
        #expect(FeedbackCrashFingerprint.make(summary(garbage)) == nil)
        let truncated = root.appendingPathComponent("truncated.crash")
        try Data("Exception Type: EXC_BAD_ACCESS without incident metadata".utf8).write(to: truncated)
        #expect(FeedbackCrashFingerprint.make(summary(truncated)) == nil)

        let valid = root.appendingPathComponent("valid.crash")
        try Data("Incident Identifier: ABC\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: valid)
        let hard = root.appendingPathComponent("hard.crash")
        try FileManager.default.linkItem(at: valid, to: hard)
        #expect(FeedbackCrashFingerprint.make(summary(valid)) == nil)
        #expect(FeedbackCrashFingerprint.make(summary(hard)) == nil)
        let symlink = root.appendingPathComponent("link.crash")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)
        #expect(FeedbackCrashFingerprint.make(summary(symlink)) == nil)
    }

    @Test("First feature launch establishes watermark without offering historical crashes")
    @MainActor
    func firstLaunchBaseline() async {
        let defaults = crashDefaults()
        let scans = CrashLockedInt()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { now },
            scan: { _, _ in scans.increment(); return [crashSummary()] }
        )
        let offer = await monitor.claimNextOffer(using: FeedbackCrashOfferService(defaults: defaults))
        #expect(offer == nil)
        #expect(scans.value == 0)
        #expect(defaults.double(forKey: watermarkKey(.development)) == now.timeIntervalSince1970)
    }

    @Test("Later launch scans exact open-closed boundary once across window calls")
    @MainActor
    func nextLaunchBoundaryAndProcessClaim() async throws {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let current = previous.addingTimeInterval(60)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        let scans = CrashLockedInt()
        let report = crashSummary(date: current)
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { current },
            scan: { interval, displayName in
                scans.increment()
                #expect(interval.start == previous)
                #expect(interval.end == current)
                #expect(displayName == AppChannel.development.displayName)
                return [report]
            }
        )
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "f", count: 64) }
        )
        #expect(await monitor.claimNextOffer(using: service) != nil)
        #expect(await monitor.claimNextOffer(using: service) == nil)
        #expect(scans.value == 1)
        #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
    }

    @Test("Successive launches drain every crash before committing the interval")
    @MainActor
    func multipleCrashesDrainAcrossLaunches() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        let firstCrash = crashSummary(appName: "A", date: previous.addingTimeInterval(10))
        let secondCrash = crashSummary(appName: "B", date: previous.addingTimeInterval(20))
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { String(repeating: $0.appName == "A" ? "a" : "b", count: 64) }
        )

        for (index, expected) in ["B", "A"].enumerated() {
            let boundary = previous.addingTimeInterval(TimeInterval(60 + index))
            let monitor = FeedbackCrashLaunchMonitor(
                defaults: defaults,
                channel: .development,
                now: { boundary },
                scan: { _, _ in [firstCrash, secondCrash] }
            )
            #expect(await monitor.claimNextOffer(using: service)?.report.appName == expected)
            #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
        }
        let finalBoundary = previous.addingTimeInterval(120)
        let finalMonitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { finalBoundary },
            scan: { _, _ in [firstCrash, secondCrash] }
        )
        #expect(await finalMonitor.claimNextOffer(using: service) == nil)
        #expect(defaults.double(forKey: watermarkKey(.development)) == finalBoundary.timeIntervalSince1970)
    }

    @Test("A bounded launch interval drains crashes beyond the former twenty-file cap")
    @MainActor
    func moreThanTwentyCrashesDrainBeforeWatermarkCommit() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = previous.addingTimeInterval(60)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        let reports = (1...25).map { index in
            crashSummary(
                appName: String(format: "Crash-%02d", index),
                date: previous.addingTimeInterval(TimeInterval(index))
            )
        }
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { FeedbackCanonicalJSONV1.sha256Hex(Data($0.appName.utf8)) }
        )

        for expected in reports.reversed() {
            let monitor = FeedbackCrashLaunchMonitor(
                defaults: defaults,
                channel: .development,
                now: { boundary },
                scan: { _, _ in reports }
            )
            #expect(await monitor.claimNextOffer(using: service)?.report.appName == expected.appName)
            #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
        }

        let finalMonitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { boundary },
            scan: { _, _ in reports }
        )
        #expect(await finalMonitor.claimNextOffer(using: service) == nil)
        #expect(defaults.double(forKey: watermarkKey(.development)) == boundary.timeIntervalSince1970)
    }

    @Test("Ledger capacity leaves the bounded interval watermark unchanged")
    @MainActor
    func ledgerCapacityPreservesOldWatermark() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = previous.addingTimeInterval(60)
        let full = crashLedgerData(count: 1_000, duplicateKey: false)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        defaults.set(full, forKey: AppStorageKeys.feedbackCrashOfferLedger)
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { boundary },
            scan: { _, _ in [crashSummary(appName: "Unseen", date: boundary)] }
        )
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "f", count: 64) }
        )

        #expect(await monitor.claimNextOffer(using: service) == nil)
        #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
        #expect(defaults.data(forKey: AppStorageKeys.feedbackCrashOfferLedger) == full)
    }

    @Test("Claim persistence failure leaves the prior watermark for safe retry")
    @MainActor
    func failedClaimDoesNotAdvanceWatermark() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let current = previous.addingTimeInterval(60)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { current },
            scan: { _, _ in [crashSummary(date: current)] }
        )
        let failing = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "1", count: 64) },
            writeData: { _ in false }
        )
        #expect(await monitor.claimNextOffer(using: failing) == nil)
        #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
    }

    @Test("Watermark readback failure rolls back to the old cursor")
    @MainActor
    func watermarkReadbackFailureRestoresOldCursor() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let current = previous.addingTimeInterval(60)
        let storage = CrashBoundaryStore(initial: NSNumber(value: previous.timeIntervalSince1970))
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { current },
            readBoundary: { storage.read() },
            writeBoundaryValue: { storage.write($0) },
            scan: { _, _ in [] }
        )
        storage.failNextReadbackAfterWrite = true

        #expect(await monitor.claimNextOffer(using: FeedbackCrashOfferService(defaults: defaults)) == nil)
        #expect((storage.value as? NSNumber)?.doubleValue == previous.timeIntervalSince1970)
        #expect(storage.writeCount == 2)
    }

    @Test("Cancelled startup leaves the old cursor and never claims")
    @MainActor
    func cancelledScanDoesNotClaimOrAdvance() async {
        let defaults = crashDefaults()
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let current = previous.addingTimeInterval(60)
        defaults.set(previous.timeIntervalSince1970, forKey: watermarkKey(.development))
        let began = CrashLockedInt()
        let release = DispatchSemaphore(value: 0)
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            now: { current },
            scan: { _, _ in
                began.increment()
                release.wait()
                return [crashSummary(date: current)]
            }
        )
        let service = FeedbackCrashOfferService(
            defaults: defaults,
            fingerprint: { _ in String(repeating: "3", count: 64) }
        )
        let task = Task { await monitor.claimNextOffer(using: service) }
        while began.value == 0 { await Task.yield() }
        let mainActorRemainedResponsive = true
        task.cancel()
        release.signal()
        #expect(await task.value == nil)
        #expect(mainActorRemainedResponsive)
        #expect(defaults.double(forKey: watermarkKey(.development)) == previous.timeIntervalSince1970)
        #expect((try? service.linkedReportIDs()) == Set<UUID>())
    }

    @Test("Clock rollback and corrupt watermark suppress scan without mutation")
    @MainActor
    func badWatermarkFailsClosed() async {
        let defaults = crashDefaults()
        let key = watermarkKey(.development)
        defaults.set("corrupt", forKey: key)
        let scans = CrashLockedInt()
        let monitor = FeedbackCrashLaunchMonitor(
            defaults: defaults,
            channel: .development,
            scan: { _, _ in scans.increment(); return [] }
        )
        #expect(await monitor.claimNextOffer(using: FeedbackCrashOfferService(defaults: defaults)) == nil)
        #expect(scans.value == 0)
        #expect(defaults.string(forKey: key) == "corrupt")
    }

    @Test("Offer validation rejects crash replacement after durable claim")
    @MainActor
    func mutationAfterClaimFailsValidation() async throws {
        let root = try crashRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mutable.crash")
        try Data("Incident Identifier: FIRST\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: url)
        let service = FeedbackCrashOfferService(defaults: crashDefaults())
        let offer = try #require(try await service.claimOffer(from: [summary(url)]))
        #expect(try await service.validateOffer(offer))
        try Data("Incident Identifier: SECOND\nException Type: EXC_BAD_ACCESS\n".utf8).write(to: url)
        #expect(try await service.validateOffer(offer) == false)
    }
}

private final class CrashLockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class CrashReportIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private final class CrashBoundaryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Any?
    private var writes = 0
    private var failNext = false
    private var shouldFailReadback = false

    init(initial: Any?) {
        storedValue = initial
    }

    var value: Any? { lock.withLock { storedValue } }
    var writeCount: Int { lock.withLock { writes } }
    var failNextReadbackAfterWrite: Bool {
        get { lock.withLock { failNext } }
        set { lock.withLock { failNext = newValue } }
    }

    func read() -> Any? {
        lock.withLock {
            if shouldFailReadback {
                shouldFailReadback = false
                return "readback-failed"
            }
            return storedValue
        }
    }

    func write(_ newValue: Any?) {
        lock.withLock {
            storedValue = newValue
            writes += 1
            if failNext {
                failNext = false
                shouldFailReadback = true
            }
        }
    }
}

private func crashDefaults() -> UserDefaults {
    UserDefaults(suiteName: "feedback-crash-tests-\(UUID().uuidString)")!
}

private func crashSummary(
    appName: String = "ASTRA Dev",
    date: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> CrashReportSummary {
    CrashReportSummary(
        url: URL(fileURLWithPath: "/tmp/unused.crash"),
        appName: appName,
        modifiedAt: date,
        sizeBytes: 64,
        kind: .crash
    )
}

private func crashRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("feedback-crash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func summary(_ url: URL) -> CrashReportSummary {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return CrashReportSummary(
        url: url,
        appName: "ASTRA Dev",
        modifiedAt: values?.contentModificationDate ?? Date(),
        sizeBytes: Int64(values?.fileSize ?? 0),
        kind: .crash
    )
}

private func watermarkKey(_ channel: AppChannel) -> String {
    "\(AppStorageKeys.feedbackCrashScanWatermarkPrefix).\(channel.rawValue)"
}

private func crashLedgerData(
    count: Int,
    duplicateKey: Bool,
    duplicateReportID: Bool = false
) -> Data {
    let records: [[String: Any]] = (0..<count).map { index in
        let value = duplicateKey ? 1 : index + 1
        let reportIDValue = duplicateReportID ? 1 : index + 1
        return [
            "fingerprint": String(format: "%064x", value),
            "consentVersion": FeedbackReportFormState.consentVersion,
            "outcome": "offered",
            "reportID": String(
                format: "00000000-0000-4000-8000-%012llx",
                UInt64(reportIDValue)
            )
        ]
    }
    return try! JSONSerialization.data(withJSONObject: records)
}
