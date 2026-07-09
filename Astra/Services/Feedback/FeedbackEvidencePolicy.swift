import Foundation
import ASTRACore

struct FeedbackEvidenceSelections: Equatable, Sendable {
    var includeApplicationLogs = true
    var includeTaskLogs = true
    var includeBrowserEvidence = false
    var includeScreenshots = false
    var includeMacOSDiagnostics = false
}

struct FeedbackBrowserEvidenceRecord: Codable, Equatable, Sendable {
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
    let observedOutcome: String?
}

struct FeedbackScreenshotCandidate: Equatable, Sendable {
    let jpegData: Data
    let source: String
    let width: Int
    let height: Int
}

struct FeedbackEvidenceInput: Sendable {
    let reportID: UUID
    let reportCreatedAt: Date
    let applicationLogEntries: [LogEntry]
    let taskLogEntries: [LogEntry]
    let browserRecords: [FeedbackBrowserEvidenceRecord]
    let screenshots: [FeedbackScreenshotCandidate]
    let crashReports: [CrashReportSummary]
    let makeReportEnvelopeData: @Sendable (FeedbackEvidenceManifestV1) throws -> Data

    init(
        reportID: UUID,
        reportCreatedAt: Date,
        applicationLogEntries: [LogEntry],
        taskLogEntries: [LogEntry],
        browserRecords: [FeedbackBrowserEvidenceRecord],
        screenshots: [FeedbackScreenshotCandidate],
        crashReports: [CrashReportSummary],
        makeReportEnvelopeData: @escaping @Sendable (FeedbackEvidenceManifestV1) throws -> Data
    ) {
        self.reportID = reportID
        self.reportCreatedAt = reportCreatedAt
        self.applicationLogEntries = applicationLogEntries
        self.taskLogEntries = taskLogEntries
        self.browserRecords = browserRecords
        self.screenshots = screenshots
        self.crashReports = crashReports
        self.makeReportEnvelopeData = makeReportEnvelopeData
    }
}

struct FeedbackPreparedEvidencePackage: Equatable, Sendable {
    let reportID: UUID
    let reportCreatedAt: Date
    let directoryURL: URL
    let reportURL: URL
    let archiveURL: URL
    let manifestURL: URL
    let manifest: FeedbackEvidenceManifestV1
    let manifestSHA256: String
    let reportSHA256: String
    let archiveSHA256: String
}

enum FeedbackEvidencePolicy {
    static let redactionPolicyVersion = "feedback-redaction-v1"
    static let reportFileName = "feedback-report.json"
    static let archiveFileName = "evidence.zip"
    static let manifestFileName = "manifest.json"
    static let maximumTextArtifactBytes = 2 * 1_024 * 1_024
    static let maximumBrowserRecords = 200
    static let maximumScreenshots = 8
    static let maximumScreenshotDimension = 8_192
    static let maximumScreenshotPixels = 32_000_000
    static let maximumCrashReports = 20
    static let maximumCrashInspectionBytes = 128 * 1_024

    struct Rule: Equatable, Sendable {
        let kind: FeedbackEvidenceArtifactKindV1
        let disclosureClass: FeedbackEvidenceDisclosureClassV1
        let relativePath: String
        let mediaType: String
        let maximumBytes: Int
    }

    static let applicationLog = Rule(
        kind: .applicationLog,
        disclosureClass: .standard,
        relativePath: "logs/application-log.jsonl",
        mediaType: "application/x-ndjson",
        maximumBytes: maximumTextArtifactBytes
    )

    static let taskLog = Rule(
        kind: .taskLog,
        disclosureClass: .standard,
        relativePath: "logs/task-log.jsonl",
        mediaType: "application/x-ndjson",
        maximumBytes: maximumTextArtifactBytes
    )

    static let browserEvidence = Rule(
        kind: .browserEvidence,
        disclosureClass: .explicitOptIn,
        relativePath: "browser/browser-evidence.json",
        mediaType: "application/json",
        maximumBytes: maximumTextArtifactBytes
    )

    static let macOSDiagnostic = Rule(
        kind: .macOSDiagnostic,
        disclosureClass: .explicitOptIn,
        relativePath: "diagnostics/macos-diagnostics.json",
        mediaType: "application/json",
        maximumBytes: maximumTextArtifactBytes
    )

    static func screenshotRule(index: Int) -> Rule {
        Rule(
            kind: .screenshot,
            disclosureClass: .explicitOptIn,
            relativePath: String(format: "screenshots/browser-%03d.jpg", index + 1),
            mediaType: "image/jpeg",
            maximumBytes: Int(FeedbackContractLimitsV1.maximumArtifactBytes)
        )
    }

    static func isSelected(_ rule: Rule, selections: FeedbackEvidenceSelections) -> Bool {
        switch rule.kind {
        case .applicationLog:
            selections.includeApplicationLogs
        case .taskLog:
            selections.includeTaskLogs
        case .browserEvidence:
            selections.includeBrowserEvidence
        case .screenshot:
            selections.includeScreenshots
        case .macOSDiagnostic:
            selections.includeMacOSDiagnostics
        default:
            false
        }
    }
}

enum FeedbackContactMemberPolicy {
    private static let forbiddenNormalizedMemberNames: Set<String> = [
        "contact",
        "contactaddress",
        "contactemail",
        "contactemailaddress",
        "contactinfo",
        "contactinformation",
        "contactname",
        "contactphone",
        "contactphonenumber",
        "email",
        "emailaddress",
        "fullname",
        "phone",
        "phonenumber",
        "replyto",
        "reporter",
        "reportercontact",
        "reportercontactaddress",
        "reporteremail",
        "reporteremailaddress",
        "reportername",
        "reporterphone",
        "reporterphonenumber",
        "telephone"
    ]

    static func containsForbiddenMember(in data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return true }
        return containsForbiddenMember(in: root)
    }

    private static func containsForbiddenMember(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if forbiddenNormalizedMemberNames.contains(normalize(key)) {
                    return true
                }
                if containsForbiddenMember(in: child) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsForbiddenMember)
        }
        return false
    }

    private static func normalize(_ memberName: String) -> String {
        let separators: Set<UnicodeScalar> = [" ", "\t", "_", "-", "."]
        return memberName
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { !separators.contains($0) }
            .map(String.init)
            .joined()
    }
}

enum FeedbackRawCanonicalJSONVerifier {
    private static let maximumInteroperableInteger: Int64 = 9_007_199_254_740_991

    static func isCanonicalObject(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else { return false }

        var output = String()
        guard appendCanonical(object, to: &output) else { return false }
        return Data(output.utf8) == data
    }

    private static func appendCanonical(_ value: Any, to output: inout String) -> Bool {
        switch value {
        case is NSNull:
            output += "null"
            return true
        case let string as String:
            guard isNormalized(string) else { return false }
            appendCanonicalString(string, to: &output)
            return true
        case let number as NSNumber:
            let type = String(cString: number.objCType)
            if type == "c" {
                output += number.boolValue ? "true" : "false"
                return true
            }
            guard ["s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type),
                  let integer = Int64(number.stringValue),
                  (-maximumInteroperableInteger...maximumInteroperableInteger).contains(integer)
            else { return false }
            output += number.stringValue
            return true
        case let array as [Any]:
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                guard appendCanonical(element, to: &output) else { return false }
            }
            output += "]"
            return true
        case let dictionary as [String: Any]:
            guard dictionary.keys.allSatisfy(isNormalized) else { return false }
            output += "{"
            let keys = dictionary.keys.sorted(by: utf16LessThan)
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                appendCanonicalString(key, to: &output)
                output += ":"
                guard let member = dictionary[key], appendCanonical(member, to: &output) else {
                    return false
                }
            }
            output += "}"
            return true
        default:
            return false
        }
    }

    private static func isNormalized(_ value: String) -> Bool {
        value.unicodeScalars.elementsEqual(
            FeedbackContractNormalizationV1.text(value).unicodeScalars
        )
    }

    private static func appendCanonicalString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0a: output += "\\n"
            case 0x0c: output += "\\f"
            case 0x0d: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x00...0x1f:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func utf16LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}

enum FeedbackEvidenceBuildError: LocalizedError, Equatable {
    case packageAlreadyExists(String)
    case unsafeDestination(String)
    case archiveCreationFailed(String)
    case noArchiveTool
    case invalidReportEnvelope(String)

    var errorDescription: String? {
        switch self {
        case .packageAlreadyExists(let path):
            "A prepared feedback package already exists at \(path)."
        case .unsafeDestination(let path):
            "Feedback evidence resolved outside its staging directory: \(path)."
        case .archiveCreationFailed(let message):
            "Could not create the feedback evidence archive: \(message)"
        case .noArchiveTool:
            "The system zip tool is unavailable."
        case .invalidReportEnvelope(let detail):
            "The feedback report envelope does not match its prepared evidence: \(detail)"
        }
    }
}
