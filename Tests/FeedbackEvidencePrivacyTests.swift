import Foundation
import Testing
import ASTRACore
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    @Test("Authorization redaction consumes complete Basic and Bearer credentials")
    func authorizationCredentialsAreFullyRedacted() {
        let credentials = ["x", "short", "abc123", String(repeating: "L", count: 256)]
        let raw = """
        Authorization: Bearer \(credentials[0])
        authorization=basic \(credentials[1])
        AUTHORIZATION: bEaReR \(credentials[2])
        Authorization: Basic \(credentials[3])
        standalone Bearer tiny
        """

        let result = FeedbackEvidenceSanitizer.sanitize(raw, maximumBytes: 4_000)

        for credential in credentials {
            #expect(!result.text.contains(credential), "Credential survived: \(credential)")
        }
        #expect(!result.text.contains("tiny"))
        #expect(result.redaction.secretPatterns >= 5)
    }

    @Test("Bare Google API keys are redacted even without a key= label")
    func bareGoogleAPIKeysAreRedacted() {
        let key = "AIzaodJFCrnl2edlBDdz1C5Jau2RJtBRnlWmTSH"
        let raw = "Copied from the console: \(key)"

        let result = FeedbackEvidenceSanitizer.sanitize(raw, maximumBytes: 4_000)

        #expect(!result.text.contains(key))
        #expect(result.redaction.secretPatterns > 0)
    }

    @Test("Punctuated non-home paths are redacted completely, not just their prefix")
    func punctuatedNonHomePathsAreFullyRedacted() {
        let raw = "See /Volumes/Macintosh HD/Client (Secret)/diagnosis  notes.txt for details"

        let result = FeedbackEvidenceSanitizer.sanitize(raw, maximumBytes: 4_000)

        #expect(!result.text.contains("Secret"))
        #expect(!result.text.contains("notes.txt"))
        #expect(result.text.contains("for details"))
        #expect(result.redaction.pathPatterns > 0)
    }

    @Test("Repeated-space home paths are fully redacted in default log evidence")
    func repeatedSpaceHomePathsAreFullyRedactedInDefaultLogs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let privatePath = "/Users/alvaro/Patient  Jane/diagnosis  notes.txt"
        let message = "opened \(privatePath) then preserved safe context"

        let sanitized = FeedbackEvidenceSanitizer.sanitize(message, maximumBytes: 4_000)

        #expect(sanitized.text == "opened [redacted-home-path] then preserved safe context")
        #expect(sanitized.redaction.pathPatterns == 1)

        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(applicationLogEntries: [
                LogEntry(
                    level: .info,
                    category: "Diagnostics",
                    message: message,
                    timestamp: fixture.createdAt
                )
            ]),
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )
        let applicationLog = try zipEntry("logs/application-log.jsonl", archive: package.archiveURL)

        #expect(!applicationLog.contains("Patient"))
        #expect(!applicationLog.contains("Jane"))
        #expect(!applicationLog.contains("notes.txt"))
        #expect(applicationLog.contains("then preserved safe context"))
    }

    @Test("Unchecked browser, screenshot, and crash evidence perform no disclosure")
    func sensitiveEvidenceHonorsExplicitOptOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crash = try fixture.crashReport(contents: "Process: ASTRA Dev\nprivate raw line")
        let input = fixture.input(
            browserRecords: [fixture.browserRecord(outcome: "typed outcome")],
            screenshots: [fixture.jpegScreenshot],
            crashReports: [crash]
        )

        var selections = FeedbackEvidenceSelections()
        selections.includeBrowserEvidence = false
        selections.includeScreenshots = false
        selections.includeMacOSDiagnostics = false
        let package = try FeedbackEvidenceBuilder().prepare(
            input: input,
            selections: selections,
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

    @Test("Heterogeneous omission overflow retains every evidence kind deterministically")
    func heterogeneousOmissionOverflowRetainsEveryKind() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let crash = try fixture.crashReport(contents: "Process: ASTRA Dev")
        let screenshots = (0..<(FeedbackContractLimitsV1.maximumOmissions + 20)).map { index in
            FeedbackScreenshotCandidate(
                jpegData: fixture.jpegScreenshot.jpegData,
                source: String(format: "browser-%03d", index),
                width: 2,
                height: 2
            )
        }
        var selections = FeedbackEvidenceSelections()
        selections.includeBrowserEvidence = false
        selections.includeMacOSDiagnostics = false

        let first = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(
                browserRecords: [fixture.browserRecord(outcome: nil)],
                screenshots: screenshots,
                crashReports: [crash]
            ),
            selections: selections,
            directory: fixture.root.appendingPathComponent("omissions-first", isDirectory: true)
        )
        let second = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(
                browserRecords: [fixture.browserRecord(outcome: nil)],
                screenshots: Array(screenshots.reversed()),
                crashReports: [crash]
            ),
            selections: selections,
            directory: fixture.root.appendingPathComponent("omissions-second", isDirectory: true)
        )
        let omissionKinds = Set(first.manifest.omissions.map(\.kind))

        #expect(first.manifest.omissions == second.manifest.omissions)
        #expect(first.manifest.omissions.count <= FeedbackContractLimitsV1.maximumOmissions)
        #expect(omissionKinds.contains(.browserEvidence))
        #expect(omissionKinds.contains(.screenshot))
        #expect(omissionKinds.contains(.macOSDiagnostic))
        #expect(first.manifest.omissions.contains { omission in
            omission.kind == .screenshot &&
                omission.reason == .oversized &&
                omission.detail?.contains("coalesced") == true
        })
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
        #expect(CGImageSourceCreateWithData(screenshot as CFData, nil) != nil)
        #expect(!screenshot.isEmpty)
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

        var utcEnvironment = ProcessInfo.processInfo.environment
        utcEnvironment["TZ"] = "UTC"
        var pacificEnvironment = ProcessInfo.processInfo.environment
        pacificEnvironment["TZ"] = "America/Los_Angeles"
        let immutableUTCEnvironment = utcEnvironment
        let immutablePacificEnvironment = pacificEnvironment
        let first = try FeedbackEvidenceBuilder(processEnvironment: { immutableUTCEnvironment }).prepare(
            input: input,
            selections: selections,
            directory: firstOutput
        )
        let second = try FeedbackEvidenceBuilder(processEnvironment: { immutablePacificEnvironment }).prepare(
            input: input,
            selections: selections,
            directory: secondOutput
        )

        #expect(first.manifest == second.manifest)
        #expect(first.manifestSHA256 == second.manifestSHA256)
        #expect(first.archiveSHA256 == second.archiveSHA256)
        #expect(try Data(contentsOf: first.manifestURL) == Data(contentsOf: second.manifestURL))
        #expect(try Data(contentsOf: first.archiveURL) == Data(contentsOf: second.archiveURL))
        for artifact in first.manifest.artifacts {
            let looseBytes = try Data(contentsOf: first.directoryURL.appendingPathComponent(artifact.relativePath))
            let bytes = try zipEntryData(artifact.relativePath, archive: first.archiveURL)
            #expect(looseBytes == bytes)
            #expect(FeedbackCanonicalJSONV1.sha256Hex(bytes) == artifact.sha256)
            #expect(Int64(bytes.count) == artifact.byteCount)
        }
    }

    @Test("Hostile ZIPOPT cannot alter the declared archive layout")
    func hostileZIPOPTDoesNotAlterArchiveLayout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        environment["ZIPOPT"] = "-j"
        let immutableEnvironment = environment

        let package = try FeedbackEvidenceBuilder(processEnvironment: { immutableEnvironment }).prepare(
            input: fixture.input(),
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )

        let nestedApplicationLog = try zipEntry("logs/application-log.jsonl", archive: package.archiveURL)
        #expect(!nestedApplicationLog.isEmpty)
        #expect(try zipEntry("application-log.jsonl", archive: package.archiveURL).isEmpty)
        try assertAdoptionCompatibleLayout(package)
    }

    @Test("Submillisecond report timestamps crossing a second boundary remain stable")
    func submillisecondTimestampBoundaryIsCanonicalized() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.9996)

        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(reportCreatedAt: createdAt),
            selections: FeedbackEvidenceSelections(),
            directory: fixture.outputDirectory
        )
        let envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: Data(contentsOf: package.reportURL)
        )

        #expect(envelope.payload.createdAt == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(package.reportCreatedAt == createdAt)
    }

    @Test("Browser truncation retains the newest 200 records in canonical order")
    func browserTruncationRetainsNewestWindow() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (1...205).map { sequence in
            FeedbackBrowserEvidenceRecord(
                sequence: sequence,
                createdAt: createdAt.addingTimeInterval(TimeInterval(sequence)),
                method: "GET",
                path: "/records/\(sequence)",
                statusCode: 200,
                durationMilliseconds: sequence,
                beforeHost: "example.test",
                afterHost: "example.test",
                urlChanged: false,
                succeeded: true,
                errorCode: nil,
                observedOutcome: "complete"
            )
        }

        let transformedOrNil = try FeedbackBrowserEvidenceTransformer.transform(Array(records.reversed()))
        let transformed = try #require(transformedOrNil)
        let object = try #require(JSONSerialization.jsonObject(with: transformed.data) as? [String: Any])
        let retained = try #require(object["records"] as? [[String: Any]])
        let sequences = retained.compactMap { ($0["sequence"] as? NSNumber)?.intValue }

        #expect(sequences == Array(6...205))
        #expect(transformed.warnings.contains { warning in
            warning.code == "browser_records_truncated" && warning.message.contains("newest 200")
        })
    }

    @Test("Browser code fields drop secret-shaped values after sanitization")
    func browserCodesRejectSecrets() throws {
        let record = FeedbackBrowserEvidenceRecord(
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            method: "GET",
            path: "/",
            statusCode: 200,
            durationMilliseconds: 1,
            beforeHost: "example.test",
            afterHost: "example.test",
            urlChanged: false,
            succeeded: false,
            errorCode: "sk-abcdefgh",
            observedOutcome: "token=short-secret"
        )

        let transformedOrNil = try FeedbackBrowserEvidenceTransformer.transform([record])
        let transformed = try #require(transformedOrNil)
        let text = String(decoding: transformed.data, as: UTF8.self)

        #expect(!text.contains("sk-abcdefgh"))
        #expect(!text.contains("short-secret"))
        #expect(!text.contains("errorCode"))
        #expect(!text.contains("outcomeCode"))
        #expect(transformed.warnings.contains { $0.code == "browser_freeform_values_omitted" })
    }

    @Test("Browser route paths survive sanitization while query secrets are stripped")
    func browserRoutePathsAreNotTreatedAsFilesystemPaths() throws {
        let record = FeedbackBrowserEvidenceRecord(
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            method: "GET",
            path: "/issues/123?token=sk-should-be-stripped-entirely",
            statusCode: 200,
            durationMilliseconds: 1,
            beforeHost: "example.test",
            afterHost: "example.test",
            urlChanged: false,
            succeeded: true,
            errorCode: nil,
            observedOutcome: nil
        )

        let transformedOrNil = try FeedbackBrowserEvidenceTransformer.transform([record])
        let transformed = try #require(transformedOrNil)
        let object = try #require(JSONSerialization.jsonObject(with: transformed.data) as? [String: Any])
        let retained = try #require(object["records"] as? [[String: Any]])
        let path = try #require(retained.first?["path"] as? String)

        #expect(path == "/issues/123")
    }

    @Test("Identifier-shaped free-form outcome values are dropped, not published as outcomeCode")
    func observedOutcomeIsRestrictedToKnownCodes() throws {
        let record = FeedbackBrowserEvidenceRecord(
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            method: "GET",
            path: "/",
            statusCode: 200,
            durationMilliseconds: 1,
            beforeHost: "example.test",
            afterHost: "example.test",
            urlChanged: false,
            succeeded: true,
            errorCode: nil,
            observedOutcome: "phoenix_launch"
        )

        let transformedOrNil = try FeedbackBrowserEvidenceTransformer.transform([record])
        let transformed = try #require(transformedOrNil)
        let text = String(decoding: transformed.data, as: UTF8.self)

        #expect(!text.contains("phoenix_launch"))
        #expect(!text.contains("outcomeCode"))
        #expect(transformed.warnings.contains { $0.code == "browser_freeform_values_omitted" })
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
        let validJPEG = fixture.jpegScreenshot.jpegData
        let corruptScreenshots = [
            FeedbackScreenshotCandidate(
                jpegData: Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0xff, 0xd9]),
                source: "marker-wrapped-garbage",
                width: 10,
                height: 10
            ),
            FeedbackScreenshotCandidate(
                jpegData: Data(validJPEG.dropLast()),
                source: "truncated",
                width: 2,
                height: 2
            ),
            FeedbackScreenshotCandidate(
                jpegData: validJPEG + Data("POLYGLOT".utf8) + Data([0xff, 0xd9]),
                source: "polyglot",
                width: 2,
                height: 2
            )
        ]
        var selections = FeedbackEvidenceSelections()
        selections.includeScreenshots = true
        selections.includeMacOSDiagnostics = true

        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(
                screenshots: corruptScreenshots,
                crashReports: [symlink, oversized, hardlink, corrupt]
            ),
            selections: selections,
            directory: fixture.outputDirectory
        )

        #expect(package.manifest.omissions.filter { $0.kind == .screenshot && $0.reason == .unsupported }.count == 3)
        #expect(package.manifest.omissions.contains { $0.kind == .macOSDiagnostic && $0.reason == .unsupported })
        #expect(package.manifest.omissions.contains { $0.kind == .macOSDiagnostic && $0.reason == .oversized })
        #expect(package.manifest.omissions.filter { $0.kind == .macOSDiagnostic && $0.reason == .unsupported }.count >= 3)
        #expect(!package.manifest.artifacts.contains { $0.kind == .screenshot || $0.kind == .macOSDiagnostic })
    }

    @Test("Decoded screenshots are re-encoded without source metadata")
    func screenshotMetadataIsStripped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let metadataValue = "private-reporter@example.com"
        let screenshot = FeedbackScreenshotCandidate(
            jpegData: try makeJPEGFixture(metadataValue: metadataValue),
            source: "browser",
            width: 2,
            height: 2
        )
        var selections = FeedbackEvidenceSelections()
        selections.includeScreenshots = true

        let package = try FeedbackEvidenceBuilder().prepare(
            input: fixture.input(screenshots: [screenshot]),
            selections: selections,
            directory: fixture.outputDirectory
        )
        let artifact = try #require(package.manifest.artifacts.first { $0.kind == .screenshot })
        let bytes = try Data(contentsOf: package.directoryURL.appendingPathComponent(artifact.relativePath))
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        #expect(!String(decoding: bytes, as: UTF8.self).contains(metadataValue))
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(bytes) == artifact.sha256)
        #expect(bytes != screenshot.jpegData)
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

    @Test("Crash truncation retains the newest bounded reports in canonical order")
    func crashTruncationRetainsNewestWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reports = try (1...25).map { index in
            try fixture.crashReport(
                contents: "Process: ASTRA \(index)",
                modifiedAt: fixture.createdAt.addingTimeInterval(TimeInterval(index))
            )
        }

        let result = try FeedbackCrashEvidenceTransformer.transform(Array(reports.reversed()))
        let artifact = try #require(result.artifact)
        let object = try #require(JSONSerialization.jsonObject(with: artifact.data) as? [String: Any])
        let retained = try #require(object["reports"] as? [[String: Any]])
        let processes = retained.compactMap { report in
            (report["metadata"] as? [String: String])?["process"]
        }

        #expect(processes == (6...25).map { "ASTRA \($0)" })
        #expect(result.omissions.count == 5)
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

    @Test("Cancellation after the construction rename rolls back the unpublished package")
    func lateCancellationCleansRenamedPackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let finalPackage = fixture.outputDirectory.appendingPathComponent(
            "feedback-\(fixture.reportID.uuidString.lowercased())",
            isDirectory: true
        )
        let builder = FeedbackEvidenceBuilder(cancellationCheck: {
            if FileManager.default.fileExists(atPath: finalPackage.path) {
                throw SyntheticCancellation.requested
            }
        })

        #expect(throws: SyntheticCancellation.self) {
            try builder.prepare(
                input: fixture.input(),
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }

        #expect(!FileManager.default.fileExists(atPath: finalPackage.path))
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)
    }

    @Test("Consent disclosure mismatch fails closed and cleans construction state")
    func disclosureMismatchCleansConstructionState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reportID = fixture.reportID
        let createdAt = fixture.createdAt
        let input = fixture.input(makeReportEnvelopeData: { manifest in
            let bytes = try makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            var envelope = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: bytes)
            let index = try #require(envelope.payload.consent.evidenceSelections.firstIndex {
                $0.artifactID == "application-log"
            })
            envelope.payload.consent.evidenceSelections[index].disclosureClass = .explicitOptIn
            envelope.payload.consent.evidenceSelections[index].reviewedAt = createdAt
            envelope.payloadSHA256 = try envelope.payload.canonicalSHA256()
            envelope.canonicalDigestSHA256 = try envelope.computedCanonicalDigestSHA256()
            return try envelope.canonicalData()
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

    @Test("Construction cleanup never deletes a package it did not publish")
    func existingPackageIsNotDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let finalPackage = fixture.outputDirectory.appendingPathComponent(
            "feedback-\(fixture.reportID.uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: finalPackage, withIntermediateDirectories: true)
        let sentinel = finalPackage.appendingPathComponent("retention-owner.txt")
        try Data("owned".utf8).write(to: sentinel)

        #expect(throws: FeedbackEvidenceBuildError.self) {
            try FeedbackEvidenceBuilder().prepare(
                input: fixture.input(),
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }

        #expect(try Data(contentsOf: sentinel) == Data("owned".utf8))
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
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
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

        #expect(topLevel == ["evidence.zip", "feedback-report.json", "logs", "manifest.json"])
        #expect(reportBytes == expectedBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(reportBytes) == package.reportSHA256)
        #expect(envelope.payload.evidence == package.manifest)
        #expect(String(decoding: reportBytes, as: UTF8.self).contains("futureAdditiveMember"))
        #expect(package.manifest.artifacts.allSatisfy { artifact in
            !artifact.relativePath.hasPrefix("/") &&
                !artifact.relativePath.split(separator: "/").contains("..")
        })
        try assertAdoptionCompatibleLayout(package)
    }

    @Test("Raw canonical verifier rejects alternate spellings and accepts golden bytes")
    func rawCanonicalVerifierEnforcesCompleteEnvelopeBytes() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/contracts/feedback/v1/fixtures")
        let golden = try Data(contentsOf: fixtureRoot.appendingPathComponent("request.json"))
        let goldenText = String(decoding: golden, as: UTF8.self)
        let withoutClosingBrace = String(goldenText.dropLast())
        let nonCanonical = [
            Data((" " + goldenText).utf8),
            Data(("{\"zzFuture\":1," + String(goldenText.dropFirst())).utf8),
            Data((withoutClosingBrace + ",\"zzFuture\":1.0}").utf8),
            Data((withoutClosingBrace + ",\"zzFuture\":\"\\u0061\"}").utf8)
        ]

        #expect(FeedbackRawCanonicalJSONVerifier.isCanonicalObject(golden))
        for bytes in nonCanonical {
            #expect(!FeedbackRawCanonicalJSONVerifier.isCanonicalObject(bytes))
            #expect((try? FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: bytes)) != nil)
        }
    }

    @Test("Builder rejects noncanonical envelope bytes before publication")
    func noncanonicalEnvelopeDoesNotPublish() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reportID = fixture.reportID
        let createdAt = fixture.createdAt
        let input = fixture.input(makeReportEnvelopeData: { manifest in
            let canonical = try makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            return Data(" ".utf8) + canonical
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

    @Test("All frozen contact aliases are rejected at any JSON depth")
    func frozenContactAliasesAreRejected() throws {
        let aliases = [
            "contact", "contactAddress", "contact-email", "CONTACT.EMAIL.ADDRESS",
            "contactInfo", "contact information", "contactName", "contactPhone",
            "contact_phone_number", "email", "emailAddress", "fullName", "phone",
            "phoneNumber", "reply_to", "reporter", "reporterContact",
            "reporter-contact-address", "reporterEmail", "reporter.email.address",
            "reporterName", "reporterPhone", "reporter_phone_number", "telephone"
        ]

        for alias in aliases {
            let data = try JSONSerialization.data(
                withJSONObject: ["outer": [["nested": [alias: "private"]]]],
                options: [.sortedKeys]
            )
            #expect(FeedbackContactMemberPolicy.containsForbiddenMember(in: data), "Alias was allowed: \(alias)")
        }
    }

    @Test("Contact aliases block publication while benign additive members remain compatible")
    func contactAliasesBlockPublicationWithoutBroadPrefixMatching() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reportID = fixture.reportID
        let createdAt = fixture.createdAt
        let rejectedInput = fixture.input(makeReportEnvelopeData: { manifest in
            var object = try #require(JSONSerialization.jsonObject(
                with: makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            ) as? [String: Any])
            object["future"] = [["nested": ["RePlY_To": "reporter@example.com"]]]
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        })

        #expect(throws: FeedbackEvidenceBuildError.self) {
            try FeedbackEvidenceBuilder().prepare(
                input: rejectedInput,
                selections: FeedbackEvidenceSelections(),
                directory: fixture.outputDirectory
            )
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: fixture.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(children.isEmpty)

        let allowedOutput = fixture.root.appendingPathComponent("allowed", isDirectory: true)
        let allowedInput = fixture.input(makeReportEnvelopeData: { manifest in
            var object = try #require(JSONSerialization.jsonObject(
                with: makeEnvelopeData(reportID: reportID, createdAt: createdAt, manifest: manifest)
            ) as? [String: Any])
            object["future"] = [[
                "contactPatterns": 3,
                "emailDeliveryFailed": true,
                "reporterStatusNotification": "ready"
            ]]
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        })
        let allowedPackage = try FeedbackEvidenceBuilder().prepare(
            input: allowedInput,
            selections: FeedbackEvidenceSelections(),
            directory: allowedOutput
        )
        let allowedBytes = String(decoding: try Data(contentsOf: allowedPackage.reportURL), as: UTF8.self)

        #expect(allowedBytes.contains("contactPatterns"))
        #expect(allowedBytes.contains("emailDeliveryFailed"))
        #expect(allowedBytes.contains("reporterStatusNotification"))
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
    let reportID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-evidence-tests-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var jpegScreenshot: FeedbackScreenshotCandidate {
        FeedbackScreenshotCandidate(
            jpegData: try! makeJPEGFixture(),
            source: "browser",
            width: 2,
            height: 2
        )
    }

    func input(
        reportCreatedAt: Date? = nil,
        applicationLogEntries: [LogEntry]? = nil,
        browserRecords: [FeedbackBrowserEvidenceRecord] = [],
        screenshots: [FeedbackScreenshotCandidate] = [],
        crashReports: [CrashReportSummary] = [],
        makeReportEnvelopeData: (@Sendable (FeedbackEvidenceManifestV1) throws -> Data)? = nil
    ) -> FeedbackEvidenceInput {
        let reportID = reportID
        let createdAt = reportCreatedAt ?? createdAt
        return FeedbackEvidenceInput(
            reportID: reportID,
            reportCreatedAt: createdAt,
            applicationLogEntries: applicationLogEntries ?? [
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

    func crashReport(contents: String, modifiedAt: Date? = nil) throws -> CrashReportSummary {
        let url = root.appendingPathComponent("ASTRA-\(UUID().uuidString).ips")
        let data = Data(contents.utf8)
        try data.write(to: url)
        let timestamp = modifiedAt ?? createdAt
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        return CrashReportSummary(
            url: url,
            appName: "ASTRA Dev",
            modifiedAt: timestamp,
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

private func assertAdoptionCompatibleLayout(_ package: FeedbackPreparedEvidencePackage) throws {
    var allowedFiles: Set<String> = ["feedback-report.json", "manifest.json", "evidence.zip"]
    allowedFiles.formUnion(package.manifest.artifacts.map(\.relativePath))
    let allowedDirectories = Set(allowedFiles.flatMap { path -> [String] in
        let components = path.split(separator: "/").dropLast()
        return components.indices.map { index in
            components.prefix(index + 1).joined(separator: "/")
        }
    })

    for relativePath in try FileManager.default.subpathsOfDirectory(atPath: package.directoryURL.path) {
        let url = package.directoryURL.appendingPathComponent(relativePath)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        #expect(values.isSymbolicLink != true)
        if values.isDirectory == true {
            #expect(allowedDirectories.contains(relativePath), "Unexpected directory: \(relativePath)")
        } else {
            #expect(values.isRegularFile == true)
            #expect(allowedFiles.contains(relativePath), "Unexpected file: \(relativePath)")
        }
    }

    for artifact in package.manifest.artifacts {
        let data = try Data(contentsOf: package.directoryURL.appendingPathComponent(artifact.relativePath))
        #expect(Int64(data.count) == artifact.byteCount)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(data) == artifact.sha256)
        #expect(permissions(package.directoryURL.appendingPathComponent(artifact.relativePath)) == 0o400)
    }
}

private func makeJPEGFixture(metadataValue: String? = nil) throws -> Data {
    let pixels = Data([
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    ])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
    if let metadataValue {
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFArtist: metadataValue]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
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
