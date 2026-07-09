import Foundation
import ASTRACore

struct FeedbackTransformedArtifact: Equatable, Sendable {
    let data: Data
    let redaction: FeedbackRedactionSummaryV1
    let warnings: [FeedbackEvidenceWarningV1]
}

struct FeedbackCrashTransformationResult: Equatable, Sendable {
    let artifact: FeedbackTransformedArtifact?
    let omissions: [FeedbackEvidenceOmissionV1]
}

private struct FeedbackBrowserEvidenceDocument: Codable {
    let formatVersion: Int
    let records: [FeedbackBrowserArtifactRecord]
}

private struct FeedbackBrowserArtifactRecord: Codable {
    let sequence: Int
    let createdAt: Date
    let method: String
    let path: String
    let statusCode: Int
    let durationMilliseconds: Int
    let beforeHost: String
    let afterHost: String
    let urlChanged: Bool
    let succeeded: Bool
    let errorCode: String?
    let outcomeCode: String?
}

private struct FeedbackCrashEvidenceDocument: Codable {
    let formatVersion: Int
    let reports: [FeedbackCrashEvidenceRecord]
}

private struct FeedbackCrashEvidenceRecord: Codable, Equatable {
    let reportID: String
    let appName: String
    let kind: String
    let modifiedAt: Date
    let sourceByteCount: Int64
    let metadata: [String: String]
}

enum FeedbackBrowserEvidenceTransformer {
    static func transform(_ records: [FeedbackBrowserEvidenceRecord]) throws -> FeedbackTransformedArtifact? {
        guard !records.isEmpty else { return nil }
        let selected = Array(records.sorted(by: ordered).prefix(FeedbackEvidencePolicy.maximumBrowserRecords))
        var redaction = FeedbackRedactionAccumulator()
        var droppedFreeformValues = 0
        let sanitized = selected.map { record -> FeedbackBrowserArtifactRecord in
            let errorCode = safeCode(record.errorCode)
            let outcomeCode = safeCode(record.observedOutcome)
            if record.errorCode != nil && errorCode == nil { droppedFreeformValues += 1 }
            if record.observedOutcome != nil && outcomeCode == nil { droppedFreeformValues += 1 }
            return FeedbackBrowserArtifactRecord(
                sequence: max(0, record.sequence),
                createdAt: record.createdAt,
                method: safeMethod(record.method),
                path: redaction.sanitize(pathWithoutQueryOrFragment(record.path), maximumBytes: 160),
                statusCode: record.statusCode,
                durationMilliseconds: max(0, record.durationMilliseconds),
                beforeHost: redaction.sanitize(record.beforeHost, maximumBytes: 253),
                afterHost: redaction.sanitize(record.afterHost, maximumBytes: 253),
                urlChanged: record.urlChanged,
                succeeded: record.succeeded,
                errorCode: errorCode,
                outcomeCode: outcomeCode
            )
        }
        let data = try FeedbackCanonicalJSONV1.encode(
            FeedbackBrowserEvidenceDocument(formatVersion: 1, records: sanitized)
        )
        var warnings: [FeedbackEvidenceWarningV1] = []
        if records.count > selected.count {
            warnings.append(FeedbackEvidenceWarningV1(
                code: "browser_records_truncated",
                artifactID: "browser-evidence",
                message: "Browser evidence was limited to the newest \(selected.count) structured records."
            ))
        }
        if droppedFreeformValues > 0 {
            warnings.append(FeedbackEvidenceWarningV1(
                code: "browser_freeform_values_omitted",
                artifactID: "browser-evidence",
                message: "Browser evidence omitted \(droppedFreeformValues) non-allowlisted free-form values."
            ))
        }
        return FeedbackTransformedArtifact(data: data, redaction: redaction.summary, warnings: warnings)
    }

    private static func ordered(_ lhs: FeedbackBrowserEvidenceRecord, _ rhs: FeedbackBrowserEvidenceRecord) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.method != rhs.method { return lhs.method < rhs.method }
        return lhs.path < rhs.path
    }

    private static func safeMethod(_ value: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"].contains(candidate)
            ? candidate
            : "UNKNOWN"
    }

    private static func safeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty,
              candidate.utf8.count <= 80,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-").contains($0)
              })
        else { return nil }
        return candidate
    }

    private static func pathWithoutQueryOrFragment(_ value: String) -> String {
        String(value.prefix { $0 != "?" && $0 != "#" })
    }
}

enum FeedbackCrashEvidenceTransformer {
    static func transform(
        _ reports: [CrashReportSummary],
        fileManager: FileManager = .default,
        readPrefix: (URL) -> String? = readPrefixFromDisk
    ) throws -> FeedbackCrashTransformationResult {
        guard !reports.isEmpty else {
            return FeedbackCrashTransformationResult(artifact: nil, omissions: [])
        }

        let ordered = reports.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.fileName < rhs.fileName
        }
        let limited = Array(ordered.prefix(FeedbackEvidencePolicy.maximumCrashReports))
        var omissions: [FeedbackEvidenceOmissionV1] = []
        var records: [FeedbackCrashEvidenceRecord] = []
        var redaction = FeedbackRedactionAccumulator()

        for (index, report) in limited.enumerated() {
            let artifactID = String(format: "macos-diagnostic-%03d", index + 1)
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
            guard let values = try? report.url.resourceValues(forKeys: keys) else {
                omissions.append(omission(artifactID, reason: .unavailable, detail: "Diagnostic metadata could not be read."))
                continue
            }
            guard values.isSymbolicLink != true else {
                omissions.append(omission(artifactID, reason: .unsupported, detail: "Symbolic-link diagnostics are not accepted."))
                continue
            }
            guard values.isRegularFile == true else {
                omissions.append(omission(artifactID, reason: .unsupported, detail: "Diagnostic source is not a regular file."))
                continue
            }
            let sourceSize = Int64(values.fileSize ?? 0)
            guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: report.url.path) else {
                omissions.append(omission(artifactID, reason: .unavailable, detail: "Diagnostic attributes could not be read."))
                continue
            }
            let referenceCount = (sourceAttributes[.referenceCount] as? NSNumber)?.intValue ?? 1
            guard referenceCount <= 1 else {
                omissions.append(omission(artifactID, reason: .unsupported, detail: "Hard-linked diagnostics are not accepted."))
                continue
            }
            guard sourceSize <= FeedbackContractLimitsV1.maximumArtifactBytes else {
                omissions.append(omission(artifactID, reason: .oversized, detail: "Diagnostic source exceeds the V1 artifact limit."))
                continue
            }
            guard let prefix = readPrefix(report.url) else {
                omissions.append(omission(artifactID, reason: .unavailable, detail: "Diagnostic source could not be read."))
                continue
            }
            guard let afterValues = try? report.url.resourceValues(forKeys: keys),
                  let afterAttributes = try? fileManager.attributesOfItem(atPath: report.url.path),
                  afterValues.isRegularFile == true,
                  afterValues.isSymbolicLink != true,
                  (afterAttributes[.size] as? NSNumber)?.int64Value == sourceSize,
                  (afterAttributes[.modificationDate] as? Date) == (sourceAttributes[.modificationDate] as? Date),
                  (afterAttributes[.systemFileNumber] as? NSNumber)?.uint64Value ==
                    (sourceAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else {
                omissions.append(omission(artifactID, reason: .unavailable, detail: "Diagnostic source changed while it was read."))
                continue
            }

            var metadata: [String: String] = [:]
            for (key, value) in allowlistedMetadata(from: prefix) {
                metadata[key] = redaction.sanitize(value, maximumBytes: 500)
            }
            guard !metadata.isEmpty else {
                omissions.append(omission(artifactID, reason: .unsupported, detail: "Diagnostic did not contain supported metadata."))
                continue
            }
            records.append(FeedbackCrashEvidenceRecord(
                reportID: artifactID,
                appName: redaction.sanitize(report.appName, maximumBytes: 160),
                kind: report.kind.rawValue,
                modifiedAt: report.modifiedAt,
                sourceByteCount: sourceSize,
                metadata: metadata
            ))
        }

        if ordered.count > limited.count {
            for index in limited.count..<ordered.count {
                omissions.append(omission(
                    String(format: "macos-diagnostic-%03d", index + 1),
                    reason: .oversized,
                    detail: "Diagnostic count exceeds the V1 collection limit."
                ))
            }
        }

        guard !records.isEmpty else {
            return FeedbackCrashTransformationResult(artifact: nil, omissions: omissions)
        }
        let data = try FeedbackCanonicalJSONV1.encode(
            FeedbackCrashEvidenceDocument(formatVersion: 1, reports: records)
        )
        return FeedbackCrashTransformationResult(
            artifact: FeedbackTransformedArtifact(data: data, redaction: redaction.summary, warnings: []),
            omissions: omissions
        )
    }

    private static func readPrefixFromDisk(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: FeedbackEvidencePolicy.maximumCrashInspectionBytes) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func allowlistedMetadata(from prefix: String) -> [String: String] {
        var result: [String: String] = [:]
        let lineKeys = [
            "process": "Process:",
            "exceptionType": "Exception Type:",
            "terminationReason": "Termination Reason:",
            "osVersion": "OS Version:",
            "event": "Event:",
            "duration": "Duration:"
        ]
        for line in prefix.split(whereSeparator: \.isNewline).prefix(120) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for (key, marker) in lineKeys where result[key] == nil && text.hasPrefix(marker) {
                result[key] = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        for line in prefix.split(whereSeparator: \.isNewline).prefix(5) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("{"), text.hasSuffix("}"),
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (source, target) in [
                "app_name": "appName",
                "bug_type": "bugType",
                "os_version": "osVersion",
                "timestamp": "timestamp",
                "event": "event"
            ] where result[target] == nil {
                if let value = object[source] as? String {
                    result[target] = value
                } else if let value = object[source] as? NSNumber {
                    result[target] = value.stringValue
                }
            }
            break
        }
        return result
    }

    private static func omission(
        _ artifactID: String,
        reason: FeedbackEvidenceReasonV1,
        detail: String
    ) -> FeedbackEvidenceOmissionV1 {
        FeedbackEvidenceOmissionV1(
            artifactID: artifactID,
            kind: .macOSDiagnostic,
            reason: reason,
            detail: detail
        )
    }
}

struct FeedbackRedactionAccumulator {
    private(set) var replacements = 0
    private(set) var secretPatterns = 0
    private(set) var pathPatterns = 0
    private(set) var contactPatterns = 0

    var summary: FeedbackRedactionSummaryV1 {
        FeedbackRedactionSummaryV1(
            replacements: replacements,
            secretPatterns: secretPatterns,
            pathPatterns: pathPatterns,
            contactPatterns: contactPatterns
        )
    }

    mutating func sanitize(_ value: String, maximumBytes: Int) -> String {
        let result = FeedbackEvidenceSanitizer.sanitize(value, maximumBytes: maximumBytes)
        add(result.redaction)
        return result.text
    }

    mutating func add(_ summary: FeedbackRedactionSummaryV1) {
        replacements += summary.replacements
        secretPatterns += summary.secretPatterns
        pathPatterns += summary.pathPatterns
        contactPatterns += summary.contactPatterns
    }
}
