import Foundation
import Darwin
import Combine
import ASTRACore
import ASTRAModels

struct FeedbackCrashOffer: Equatable, Sendable {
    let fingerprint: String
    let consentVersion: String
    let reportID: UUID
    let report: CrashReportSummary

    fileprivate init(
        fingerprint: String,
        consentVersion: String,
        reportID: UUID,
        report: CrashReportSummary
    ) {
        self.fingerprint = fingerprint
        self.consentVersion = consentVersion
        self.reportID = reportID
        self.report = report
    }
}

enum FeedbackCrashOfferOutcome: String, Codable, Equatable, Sendable {
    case offered
    case declined
    case reportCreated
}

enum FeedbackCrashOfferError: Error, Equatable {
    case offerNotFound
    case persistenceFailed
    case illegalTransition
    case ledgerUnavailable
}

struct FeedbackCrashVerifiedLink: Equatable, Sendable {
    let reportID: UUID
    let outcome: FeedbackCrashOfferOutcome
}

@MainActor
protocol FeedbackCrashOfferLedgerReading {
    func validateOffer(_ offer: FeedbackCrashOffer) async throws -> Bool
    func verifiedLink(fingerprint: String, consentVersion: String) throws -> FeedbackCrashVerifiedLink?
    func linkedReportIDs() throws -> Set<UUID>
    func reconcileOfferedReport(
        fingerprint: String,
        consentVersion: String,
        reportID: UUID
    ) throws -> FeedbackCrashVerifiedLink
}

private struct FeedbackCrashOfferLedgerRecord: Codable, Equatable {
    let fingerprint: String
    let consentVersion: String
    var outcome: FeedbackCrashOfferOutcome
    var reportID: UUID?
}

/// Durable once-per-fingerprint-and-consent-version crash offer ledger. It is
/// intentionally independent of FeedbackReport schema evolution.
@MainActor
final class FeedbackCrashOfferService: ObservableObject {
    typealias Fingerprint = @Sendable (CrashReportSummary) -> String?

    private let defaults: UserDefaults
    private let key: String
    private let fingerprint: Fingerprint
    private let writeData: ((Data) -> Bool)?
    private let makeReportID: @Sendable () -> UUID

    init(
        defaults: UserDefaults = .standard,
        key: String = AppStorageKeys.feedbackCrashOfferLedger,
        fingerprint: @escaping Fingerprint = { FeedbackCrashFingerprint.make($0) },
        writeData: ((Data) -> Bool)? = nil,
        makeReportID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.defaults = defaults
        self.key = key
        self.fingerprint = fingerprint
        self.writeData = writeData
        self.makeReportID = makeReportID
    }

    /// Claims and records the offer before presentation so a crash between the
    /// decision and the sheet cannot produce a prompt loop.
    func claimOffer(
        from reports: [CrashReportSummary],
        consentVersion: String = FeedbackReportFormState.consentVersion,
        recoverableReportIDs: Set<UUID> = []
    ) async throws -> FeedbackCrashOffer? {
        let fingerprint = fingerprint
        let worker = Task.detached(priority: .utility) {
            var values: [(CrashReportSummary, String)] = []
            for report in reports {
                try Task.checkCancellation()
                if let value = fingerprint(report), !value.isEmpty {
                    values.append((report, value))
                }
            }
            return values.sorted {
                if $0.0.modifiedAt != $1.0.modifiedAt { return $0.0.modifiedAt > $1.0.modifiedAt }
                return $0.1 < $1.1
            }
        }
        let candidates: [(CrashReportSummary, String)]
        do {
            candidates = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
        } catch {
            worker.cancel()
            throw error
        }
        guard var records = loadLedger() else { throw FeedbackCrashOfferError.ledgerUnavailable }
        for (report, value) in candidates {
            if let existing = records.first(where: {
                $0.fingerprint == value && $0.consentVersion == consentVersion
            }) {
                if let reportID = existing.reportID,
                   recoverableReportIDs.contains(reportID),
                   existing.outcome == .offered {
                    return FeedbackCrashOffer(
                        fingerprint: value,
                        consentVersion: consentVersion,
                        reportID: reportID,
                        report: report
                    )
                }
                continue
            }
            try Task.checkCancellation()
            guard records.count < 1_000 else {
                AppLogger.error("Feedback crash-offer ledger is full; prompt suppressed", category: "Diagnostics")
                throw FeedbackCrashOfferError.ledgerUnavailable
            }
            let reportID = makeReportID()
            records.append(FeedbackCrashOfferLedgerRecord(
                fingerprint: value,
                consentVersion: consentVersion,
                outcome: .offered,
                reportID: reportID
            ))
            guard save(records) else { throw FeedbackCrashOfferError.persistenceFailed }
            return FeedbackCrashOffer(
                fingerprint: value,
                consentVersion: consentVersion,
                reportID: reportID,
                report: report
            )
        }
        return nil
    }

    func validateOffer(_ offer: FeedbackCrashOffer) async throws -> Bool {
        let fingerprint = fingerprint
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return fingerprint(offer.report)
        }
        do {
            let current = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard current == offer.fingerprint else { return false }
            return try verifiedLink(
                fingerprint: offer.fingerprint,
                consentVersion: offer.consentVersion
            )?.reportID == offer.reportID
        } catch {
            worker.cancel()
            throw error
        }
    }

    func decline(_ offer: FeedbackCrashOffer) throws {
        try transition(offer, outcome: .declined, reportID: nil)
    }

    func confirmReportCreated(_ offer: FeedbackCrashOffer, reportID: UUID) throws {
        guard reportID == offer.reportID else { throw FeedbackCrashOfferError.offerNotFound }
        try transition(offer, outcome: .reportCreated, reportID: reportID)
    }

    func verifiedLink(
        fingerprint: String,
        consentVersion: String
    ) throws -> FeedbackCrashVerifiedLink? {
        guard let records = loadLedger() else { throw FeedbackCrashOfferError.ledgerUnavailable }
        guard let record = records.first(where: {
            $0.fingerprint == fingerprint && $0.consentVersion == consentVersion
        }), let reportID = record.reportID else { return nil }
        return FeedbackCrashVerifiedLink(reportID: reportID, outcome: record.outcome)
    }

    func linkedReportIDs() throws -> Set<UUID> {
        guard let records = loadLedger() else { throw FeedbackCrashOfferError.ledgerUnavailable }
        return Set(records.compactMap(\.reportID))
    }

    func reconcileOfferedReport(
        fingerprint: String,
        consentVersion: String,
        reportID: UUID
    ) throws -> FeedbackCrashVerifiedLink {
        guard let current = try verifiedLink(
            fingerprint: fingerprint,
            consentVersion: consentVersion
        ), current.reportID == reportID else {
            throw FeedbackCrashOfferError.offerNotFound
        }
        if current.outcome == .reportCreated { return current }
        guard current.outcome == .offered else {
            throw FeedbackCrashOfferError.illegalTransition
        }
        try confirmReportCreated(
            fingerprint: fingerprint,
            consentVersion: consentVersion,
            reportID: reportID
        )
        return FeedbackCrashVerifiedLink(reportID: reportID, outcome: .reportCreated)
    }

    func confirmReportCreated(fingerprint: String, consentVersion: String, reportID: UUID) throws {
        guard var records = loadLedger() else { throw FeedbackCrashOfferError.ledgerUnavailable }
        guard let index = records.firstIndex(where: {
            $0.fingerprint == fingerprint && $0.consentVersion == consentVersion
        }), records[index].reportID == reportID
        else { throw FeedbackCrashOfferError.offerNotFound }
        let record = records[index]
        if record.outcome == .reportCreated { return }
        guard record.outcome == .offered else { throw FeedbackCrashOfferError.illegalTransition }
        records[index].outcome = .reportCreated
        guard save(records) else { throw FeedbackCrashOfferError.persistenceFailed }
    }

    private func transition(
        _ offer: FeedbackCrashOffer,
        outcome: FeedbackCrashOfferOutcome,
        reportID: UUID?
    ) throws {
        guard var records = loadLedger(),
              let index = records.firstIndex(where: {
                  $0.fingerprint == offer.fingerprint && $0.consentVersion == offer.consentVersion
              })
        else { throw FeedbackCrashOfferError.offerNotFound }
        let current = records[index]
        if current.outcome == outcome && current.reportID == reportID { return }
        guard current.outcome == .offered,
              current.reportID == offer.reportID,
              (outcome == .declined && reportID == nil
                  || outcome == .reportCreated && reportID == offer.reportID)
        else { throw FeedbackCrashOfferError.illegalTransition }
        records[index].outcome = outcome
        records[index].reportID = reportID
        guard save(records) else {
            AppLogger.error("Feedback crash-offer outcome could not be persisted", category: "Diagnostics")
            throw FeedbackCrashOfferError.persistenceFailed
        }
    }

    private func loadLedger() -> [FeedbackCrashOfferLedgerRecord]? {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([FeedbackCrashOfferLedgerRecord].self, from: data),
              decoded.count <= 1_000,
              validate(decoded)
        else {
            AppLogger.error("Feedback crash-offer ledger is unreadable; prompt suppressed", category: "Diagnostics")
            return nil
        }
        return decoded
    }

    private func save(_ records: [FeedbackCrashOfferLedgerRecord]) -> Bool {
        guard records.count <= 1_000, validate(records),
              let data = try? JSONEncoder().encode(records) else { return false }
        if let writeData { return writeData(data) }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    private func validate(_ records: [FeedbackCrashOfferLedgerRecord]) -> Bool {
        var keys = Set<String>()
        var linkedReportIDs = Set<UUID>()
        for record in records {
            let key = "\(record.fingerprint)|\(record.consentVersion)"
            guard keys.insert(key).inserted,
                  record.fingerprint.count == 64,
                  record.fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  !record.consentVersion.isEmpty,
                  record.consentVersion.count <= FeedbackContractLimitsV1.identifierLength
            else { return false }
            switch record.outcome {
            case .offered:
                guard let reportID = record.reportID,
                      linkedReportIDs.insert(reportID).inserted else { return false }
            case .declined:
                guard record.reportID == nil else { return false }
            case .reportCreated:
                guard let reportID = record.reportID,
                      linkedReportIDs.insert(reportID).inserted else { return false }
            }
        }
        return true
    }
}

extension FeedbackCrashOfferService: FeedbackCrashOfferLedgerReading {}

enum FeedbackCrashFingerprint {
    typealias DataReader = (_ url: URL, _ maximumBytes: Int) -> Data?

    static func make(
        _ report: CrashReportSummary,
        readData: DataReader? = nil
    ) -> String? {
        guard report.sizeBytes >= 0,
              report.sizeBytes <= Int64(FeedbackContractLimitsV1.maximumArtifactBytes)
        else { return nil }
        guard let before = metadata(report.url),
              before.size == report.sizeBytes,
              before.linkCount == 1,
              before.isRegular
        else { return nil }
        let maximumBytes = Int(report.sizeBytes) + 1
        let data: Data?
        if let readData {
            data = readData(report.url, maximumBytes)
        } else {
            let broker = HostFileAccessBroker()
            data = try? broker.readData(
                at: report.url,
                maxBytes: maximumBytes,
                keeping: .prefix,
                intent: .implicitScan(root: report.url.deletingLastPathComponent())
            )
        }
        guard let data, !data.isEmpty, data.count == Int(report.sizeBytes),
              metadata(report.url) == before
        else { return nil }
        guard isStructurallyValid(data, kind: report.kind) else { return nil }
        var canonical = Data("astra-feedback-crash-fingerprint-v1\0".utf8)
        canonical.append(data)
        return FeedbackCanonicalJSONV1.sha256Hex(canonical)
    }

    private struct FileMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let linkCount: UInt64
        let isRegular: Bool
    }

    private static func metadata(_ url: URL) -> FileMetadata? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return FileMetadata(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            linkCount: UInt64(value.st_nlink),
            isRegular: (value.st_mode & S_IFMT) == S_IFREG
        )
    }

    private static func isStructurallyValid(_ data: Data, kind: CrashReportKind) -> Bool {
        guard data.count >= 32,
              let text = String(data: data, encoding: .utf8)
        else { return false }
        let normalized = text.lowercased()
        switch kind {
        case .crash:
            let legacy = normalized.contains("incident identifier:")
                && normalized.contains("exception type:")
            let ips = normalized.contains("\"app_name\"")
                && normalized.contains("\"timestamp\"")
                && (normalized.contains("\"exception\"") || normalized.contains("\"termination\""))
            return legacy || ips
        case .hang, .spin, .stackshot:
            return normalized.contains("process:")
                && (normalized.contains("date/time:") || normalized.contains("event:"))
        case .unknown:
            return false
        }
    }
}
