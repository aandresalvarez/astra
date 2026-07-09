import Foundation
import Testing
import ASTRACore
import Darwin
@testable import ASTRA

@Suite("Feedback Evidence Privacy")
struct FeedbackEvidencePrivacyTests {
    @Test("Second-pass sanitizer removes secrets, contact values, and local paths")
    func sanitizerRemovesSensitiveValues() {
        let raw = """
        authorization: Bearer sk-super-secret-token
        reporter@example.com
        +1 (650) 555-0123
        /Users/reporter/Documents/private/report.txt
        https://person:password@example.test/private
        """

        let result = FeedbackEvidenceSanitizer.sanitize(raw, maximumBytes: 4_000)

        #expect(!result.text.contains("sk-super-secret-token"))
        #expect(!result.text.contains("reporter@example.com"))
        #expect(!result.text.contains("555-0123"))
        #expect(!result.text.contains("/Users/reporter"))
        #expect(!result.text.contains("person:password"))
        #expect(result.redaction.secretPatterns > 0)
        #expect(result.redaction.contactPatterns > 0)
        #expect(result.redaction.pathPatterns > 0)
    }

    @Test("Browser, screenshot, and crash evidence are excluded by default")
    func sensitiveEvidenceRequiresOptIn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crash = try fixture.crashReport(contents: "Process: ASTRA Dev\nprivate raw line")
        let input = fixture.input(
            browserRecords: [fixture.browserRecord(outcome: "typed outcome")],
            screenshots: [fixture.jpegScreenshot],
            crashReports: [crash]
        )

        let package = try FeedbackEvidenceBuilder().prepare(
            input: input,
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )

        #expect(package.manifest.artifacts.map(\.kind) == [.applicationLog, .taskLog])
        #expect(package.manifest.omissions.contains { $0.kind == .browserEvidence && $0.reason == .notSelected })
        #expect(package.manifest.omissions.contains { $0.kind == .screenshot && $0.reason == .notSelected })
        #expect(package.manifest.omissions.contains { $0.kind == .macOSDiagnostic && $0.reason == .notSelected })
        #expect(try zipEntry("browser/browser-evidence.json", archive: package.archiveURL).isEmpty)
        #expect(try zipEntry("screenshots/browser-001.jpg", archive: package.archiveURL).isEmpty)
        #expect(try zipEntry("diagnostics/macos-diagnostics.json", archive: package.archiveURL).isEmpty)
    }

    @Test("Opt-in evidence is structured, allowlisted, and contact-free")
    func structuredOptInEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rawSecret = "RAW-CRASH-SECRET-MUST-NOT-SURVIVE"
        let crash = try fixture.crashReport(contents: """
        Process: ASTRA Dev [123]
        Exception Type: EXC_BAD_ACCESS reporter@example.com
        \(rawSecret)
        """)
        let browserSecret = "token=sk-browser-secret reporter@example.com /Users/reporter/private"
        let input = fixture.input(
            browserRecords: [fixture.browserRecord(outcome: browserSecret)],
            screenshots: [fixture.jpegScreenshot],
            crashReports: [crash]
        )
        var selections = FeedbackEvidenceSelections()
        selections.includeBrowserEvidence = true
        selections.includeScreenshots = true
        selections.includeMacOSDiagnostics = true

        let package = try FeedbackEvidenceBuilder().prepare(
            input: input,
            selections: selections,
            directory: fixture.outputDirectory
        )
        let browser = try zipEntry("browser/browser-evidence.json", archive: package.archiveURL)
        let diagnostics = try zipEntry("diagnostics/macos-diagnostics.json", archive: package.archiveURL)
        let screenshot = try zipEntryData("screenshots/browser-001.jpg", archive: package.archiveURL)
        let manifestBytes = try Data(contentsOf: package.manifestURL)
        let combined = browser + diagnostics + String(decoding: manifestBytes, as: UTF8.self)

        #expect(!combined.contains("sk-browser-secret"))
        #expect(!combined.contains("reporter@example.com"))
        #expect(!combined.contains("/Users/reporter"))
        #expect(!combined.contains(rawSecret))
        #expect(!combined.localizedCaseInsensitiveContains("reporterName"))
        #expect(!combined.localizedCaseInsensitiveContains("reporterEmail"))
        #expect(!combined.localizedCaseInsensitiveContains("contactEmail"))
        #expect(!browser.contains("observedOutcome"))
        #expect(package.manifest.warnings.contains { $0.code == "browser_freeform_values_omitted" })
        #expect(diagnostics.contains("exceptionType"))
        #expect(screenshot == fixture.jpegScreenshot.jpegData)
        #expect(package.manifest.artifacts.first { $0.kind == .browserEvidence }?.disclosureClass == .explicitOptIn)
        #expect(package.manifest.artifacts.first { $0.kind == .screenshot }?.disclosureClass == .explicitOptIn)
        #expect(package.manifest.artifacts.first { $0.kind == .macOSDiagnostic }?.disclosureClass == .explicitOptIn)
    }

    @Test("Stable inputs produce identical final bytes, hashes, and inventory")
    func deterministicPackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstOutput = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondOutput = fixture.root.appendingPathComponent("second", isDirectory: true)
        var selections = FeedbackEvidenceSelections()
        selections.includeBrowserEvidence = true
        selections.includeScreenshots = true
        let input = fixture.input(
            browserRecords: [fixture.browserRecord(outcome: "complete")],
            screenshots: [fixture.jpegScreenshot]
        )

        let first = try FeedbackEvidenceBuilder().prepare(input: input, selections: selections, directory: firstOutput)
        let second = try FeedbackEvidenceBuilder().prepare(input: input, selections: selections, directory: secondOutput)

        #expect(first.manifest == second.manifest)
        #expect(first.manifestSHA256 == second.manifestSHA256)
        #expect(first.archiveSHA256 == second.archiveSHA256)
        #expect(try Data(contentsOf: first.manifestURL) == Data(contentsOf: second.manifestURL))
        #expect(try Data(contentsOf: first.archiveURL) == Data(contentsOf: second.archiveURL))
        for artifact in first.manifest.artifacts {
            let bytes = try zipEntryData(artifact.relativePath, archive: first.archiveURL)
            #expect(FeedbackCanonicalJSONV1.sha256Hex(bytes) == artifact.sha256)
            #expect(Int64(bytes.count) == artifact.byteCount)
        }
    }

    @Test("Invalid screenshots and unsafe crash sources fail closed")
    func invalidSourcesAreOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = try fixture.crashReport(contents: "Process: ASTRA Dev")
        let symlinkURL = fixture.root.appendingPathComponent("ASTRA-symlink.ips")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: target.url)
        let symlink = CrashReportSummary(
            url: symlinkURL,
            appName: "ASTRA Dev",
            modifiedAt: fixture.createdAt,
            sizeBytes: target.sizeBytes
        )
        let oversizedURL = fixture.root.appendingPathComponent("ASTRA-oversized.ips")
        #expect(FileManager.default.createFile(atPath: oversizedURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(FeedbackContractLimitsV1.maximumArtifactBytes + 1))
        try handle.close()
        let oversized = CrashReportSummary(
            url: oversizedURL,
            appName: "ASTRA Dev",
            modifiedAt: fixture.createdAt,
            sizeBytes: FeedbackContractLimitsV1.maximumArtifactBytes + 1
        )
        let hardlinkURL = fixture.root.appendingPathComponent("ASTRA-hardlink.ips")
        try FileManager.default.linkItem(at: target.url, to: hardlinkURL)
        let hardlink = CrashReportSummary(
            url: hardlinkURL,
            appName: "ASTRA Dev",
            modifiedAt: fixture.createdAt,
            sizeBytes: target.sizeBytes
        )
        let corrupt = try fixture.crashReport(contents: "not a supported crash document")
        let corruptScreenshot = FeedbackScreenshotCandidate(
            jpegData: Data("not-an-image".utf8),
            source: "browser",
            width: 10,
            height: 10
        )
        var selections = FeedbackEvidenceSelections()
        selections.includeScreenshots = true
        selections.includeMacOSDiagnostics = true

        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(
                screenshots: [corruptScreenshot],
                crashReports: [symlink, oversized, hardlink, corrupt]
            ),
            selections: selections,
            directory: fixture.outputDirectory
        )

        #expect(package.manifest.omissions.contains { $0.kind == .screenshot && $0.reason == .unsupported })
        #expect(package.manifest.omissions.contains { $0.kind == .macOSDiagnostic && $0.reason == .unsupported })
        #expect(package.manifest.omissions.contains { $0.kind == .macOSDiagnostic && $0.reason == .oversized })
        #expect(package.manifest.omissions.filter { $0.kind == .macOSDiagnostic && $0.reason == .unsupported }.count >= 3)
        #expect(!package.manifest.artifacts.contains { $0.kind == .screenshot || $0.kind == .macOSDiagnostic })
    }

    @Test("Unreadable crash content is omitted rather than copied")
    func unreadableCrashIsOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crash = try fixture.crashReport(contents: "Process: ASTRA Dev")

        let result = try FeedbackCrashEvidenceTransformer.transform([crash], readPrefix: { _ in nil })

        #expect(result.artifact == nil)
        #expect(result.omissions.count == 1)
        #expect(result.omissions.first?.reason == .unavailable)
    }

    @Test("Crash source changes during read are omitted")
    func changingCrashIsOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crash = try fixture.crashReport(contents: "Process: ASTRA Dev")

        let result = try FeedbackCrashEvidenceTransformer.transform([crash], readPrefix: { url in
            try? Data("Process: ASTRA Dev\nchanged while reading".utf8).write(to: url)
            return "Process: ASTRA Dev"
        })

        #expect(result.artifact == nil)
        #expect(result.omissions.first?.reason == .unavailable)
    }

    @Test("Cancellation removes construction staging without publishing a package")
    func cancellationCleansStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = CancellationGate(throwOnCall: 3)
        let builder = FeedbackEvidenceBuilder(cancellationCheck: { try gate.check() })

        #expect(throws: SyntheticCancellation.self) {
            try builder.prepare(
                input: fixture.input(),
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)
    }

    @Test("Write failure removes construction staging without publishing a package")
    func writeFailureCleansStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = WriteGate(throwOnCall: 2)
        let builder = FeedbackEvidenceBuilder(writeData: { data, url in
            try gate.write(data, to: url)
        })

        #expect(throws: SyntheticDiskFull.self) {
            try builder.prepare(
                input: fixture.input(),
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)
    }

    @Test("Prepared package is restrictive and remains after atomic adoption")
    func adoptedPackageRemainsOwnedByConsumer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(),
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )
        #expect(permissions(package.directoryURL) == 0o700)
        #expect(permissions(package.reportURL) == 0o400)
        #expect(permissions(package.archiveURL) == 0o400)
        #expect(permissions(package.manifestURL) == 0o400)

        let retentionRoot = fixture.root.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.createDirectory(
            at: retentionRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let adoptedURL = retentionRoot.appendingPathComponent(package.directoryURL.lastPathComponent)
        let renameResult: Int32 = package.directoryURL.withUnsafeFileSystemRepresentation { source in
            adoptedURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return Darwin.rename(source, destination)
            }
        }

        #expect(renameResult == 0)
        #expect(FileManager.default.fileExists(atPath: adoptedURL.path))
        #expect(!FileManager.default.fileExists(atPath: package.directoryURL.path))
    }

    @Test("Prepared package has only declared top-level files and exact report bytes")
    func preparedPackageLayoutAndExactReportBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reportID = fixture.reportID
        let createdAt = fixture.createdAt
        let input = fixture.input(makeReportEnvelopeData: { manifest in
            var object = try #require(JSONSerialization.jsonObject(
                with: makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            ) as? [String: Any])
            object["futureAdditiveMember"] = ["retained": true]
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        })

        let package = try FeedbackEvidenceBuilder().prepare(
            input: input,
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )
        let topLevel = try FileManager.default.contentsOfDirectory(
            at: package.directoryURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        let reportBytes = try Data(contentsOf: package.reportURL)
        let expectedBytes = try input.makeReportEnvelopeData(package.manifest)
        let envelope = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: reportBytes)

        #expect(topLevel == ["evidence.zip", "feedback-report.json", "manifest.json"])
        #expect(reportBytes == expectedBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(reportBytes) == package.reportSHA256)
        #expect(envelope.payload.evidence == package.manifest)
        #expect(String(decoding: reportBytes, as: UTF8.self).contains("futureAdditiveMember"))
        #expect(package.manifest.artifacts.allSatisfy { artifact in
            !artifact.relativePath.hasPrefix("/") &&
                !artifact.relativePath.split(separator: "/").contains("..")
        })
    }

    @Test("Reporter contact members are rejected before package publication")
    func reporterContactMembersAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reportID = fixture.reportID
        let createdAt = fixture.createdAt
        let input = fixture.input(makeReportEnvelopeData: { manifest in
            var object = try #require(JSONSerialization.jsonObject(
                with: makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            ) as? [String: Any])
            object["reporterEmail"] = "reporter@example.com"
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        })

        #expect(throws: FeedbackEvidenceBuildError.self) {
            try FeedbackEvidenceBuilder().prepare(
                input: input,
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)
    }
}

private enum SyntheticCancellation: Error {
    case requested
}

private enum SyntheticDiskFull: Error {
    case noSpace
}

private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let throwOnCall: Int
    private var calls = 0

    init(throwOnCall: Int) {
        self.throwOnCall = throwOnCall
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls >= throwOnCall {
            throw SyntheticCancellation.requested
        }
    }
}

private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let throwOnCall: Int
    private var calls = 0

    init(throwOnCall: Int) {
        self.throwOnCall = throwOnCall
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        calls += 1
        let shouldThrow = calls >= throwOnCall
        lock.unlock()
        if shouldThrow { throw SyntheticDiskFull.noSpace }
        try data.write(to: url, options: .atomic)
    }
}

private final class Fixture {
    let root: URL
    let outputDirectory: URL
    let reportID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-evidence-tests-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var jpegScreenshot: FeedbackScreenshotCandidate {
        FeedbackScreenshotCandidate(
            jpegData: Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0xff, 0xd9]),
            source: "browser",
            width: 2,
            height: 2
        )
    }

    func input(
        browserRecords: [FeedbackBrowserEvidenceRecord] = [],
        screenshots: [FeedbackScreenshotCandidate] = [],
        crashReports: [CrashReportSummary] = [],
        makeReportEnvelopeData: (@Sendable (FeedbackEvidenceManifestV1) throws -> Data)? = nil
    ) -> FeedbackEvidenceInput {
        let reportID = reportID
        let createdAt = createdAt
        return FeedbackEvidenceInput(
            reportID: reportID,
            reportCreatedAt: createdAt,
            applicationLogEntries: [
                LogEntry(
                    level: .info,
                    category: "App",
                    message: "started token=sk-application-secret reporter@example.com /Users/reporter/private",
                    timestamp: createdAt
                )
            ],
            taskLogEntries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "task warning",
                    taskID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                    timestamp: createdAt.addingTimeInterval(1)
                )
            ],
            browserRecords: browserRecords,
            screenshots: screenshots,
            crashReports: crashReports,
            makeReportEnvelopeData: makeReportEnvelopeData ?? { manifest in
                try makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            }
        )
    }

    func browserRecord(outcome: String?) -> FeedbackBrowserEvidenceRecord {
        FeedbackBrowserEvidenceRecord(
            sequence: 1,
            createdAt: createdAt,
            method: "GET",
            path: "/issues/123",
            statusCode: 200,
            durationMilliseconds: 12,
            beforeHost: "example.test",
            afterHost: "example.test",
            urlChanged: false,
            succeeded: true,
            errorCode: nil,
            observedOutcome: outcome
        )
    }

    func crashReport(contents: String) throws -> CrashReportSummary {
        let url = root.appendingPathComponent("ASTRA-\(UUID().uuidString).ips")
        let data = Data(contents.utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: createdAt], ofItemAtPath: url.path)
        return CrashReportSummary(
            url: url,
            appName: "ASTRA Dev",
            modifiedAt: createdAt,
            sizeBytes: Int64(data.count)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func zipEntry(_ path: String, archive: URL) throws -> String {
    String(decoding: try zipEntryData(path, archive: archive), as: UTF8.self)
}

private func zipEntryData(_ path: String, archive: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return output.fileHandleForReading.readDataToEndOfFile()
}

private func permissions(_ url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func makeEnvelopeData(
    reportID: UUID,
    createdAt: Date,
    manifest: FeedbackEvidenceManifestV1
) throws -> Data {
    let selections = manifest.artifacts.map { artifact in
        FeedbackEvidenceSelectionV1(
            artifactID: artifact.artifactID,
            disclosureClass: artifact.disclosureClass,
            included: true,
            reviewedAt: artifact.disclosureClass == .standard ? nil : createdAt
        )
    }
    let payload = FeedbackReportPayloadV1(
        reportID: FeedbackReportIDV1(reportID),
        createdAt: createdAt,
        statement: FeedbackUserStatementV1(
            intendedOutcome: "Submit a private diagnostic report.",
            actualResult: "The task did not complete.",
            expectedResult: "The task completes successfully.",
            workBlocked: true
        ),
        build: FeedbackBuildProvenanceV1(
            version: "0.1.0",
            build: "1",
            channel: "development",
            gitCommit: "0123456789abcdef0123456789abcdef01234567",
            buildDate: "2026-07-09T20:00:00Z",
            source: "local_build"
        ),
        platform: FeedbackPlatformV1(macOSVersion: "15.5", architecture: "arm64"),
        evidenceWindow: FeedbackEvidenceWindowV1(
            start: createdAt.addingTimeInterval(-900),
            end: createdAt
        ),
        consent: FeedbackConsentV1(
            version: "feedback-consent-v1",
            evidenceSelections: selections
        ),
        evidence: manifest
    )
    let payloadSHA256 = try payload.canonicalSHA256()
    var envelope = FeedbackReportEnvelopeV1(
        installationID: FeedbackInstallationIDV1(rawValue: "installation-test"),
        idempotencyKey: "feedback-\(reportID.uuidString.lowercased())",
        payloadSHA256: payloadSHA256,
        evidenceArchiveSHA256: manifest.archiveSHA256,
        canonicalDigestSHA256: String(repeating: "0", count: 64),
        payload: payload
    )
    envelope.canonicalDigestSHA256 = try envelope.computedCanonicalDigestSHA256()
    return try envelope.canonicalData()
}
