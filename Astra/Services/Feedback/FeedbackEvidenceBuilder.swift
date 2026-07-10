import Foundation
import ASTRACore

private struct FeedbackLogEvidenceRecord: Codable {
    let timestamp: Date
    let level: String
    let category: String
    let taskID: String?
    let message: String
}

struct FeedbackEvidenceBuilder {
    private let fileManager: FileManager
    private let cancellationCheck: @Sendable () throws -> Void
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let processEnvironment: @Sendable () -> [String: String]

    init(
        fileManager: FileManager = .default,
        cancellationCheck: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() },
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        processEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.fileManager = fileManager
        self.cancellationCheck = cancellationCheck
        self.writeData = writeData
        self.processEnvironment = processEnvironment
    }

    func prepare(
        input: FeedbackEvidenceInput,
        selections: FeedbackEvidenceSelections,
        directory: URL
    ) throws -> FeedbackPreparedEvidencePackage {
        try cancellationCheck()
        if fileManager.fileExists(atPath: directory.path),
           (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FeedbackEvidenceBuildError.unsafeDestination(directory.path)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let packageName = "feedback-\(input.reportID.uuidString.lowercased())"
        let finalPackage = directory.appendingPathComponent(packageName, isDirectory: true)
        guard !fileManager.fileExists(atPath: finalPackage.path) else {
            throw FeedbackEvidenceBuildError.packageAlreadyExists(finalPackage.path)
        }

        let stagingPackage = directory.appendingPathComponent(
            ".feedback-staging-\(input.reportID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        // Manifest paths are package-root relative because the outbox validates
        // and adopts these exact loose files alongside the optional archive.
        let contentsDirectory = stagingPackage
        var published = false
        var movedToFinal = false
        defer {
            if !published {
                removeConstructionPackage(at: stagingPackage)
                if movedToFinal {
                    removeConstructionPackage(at: finalPackage)
                }
            }
        }

        do {
            try fileManager.createDirectory(
                at: contentsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var artifacts: [FeedbackEvidenceArtifactV1] = []
            var omissions: [FeedbackEvidenceOmissionV1] = []
            var warnings: [FeedbackEvidenceWarningV1] = []

            try appendLogArtifact(
                entries: input.applicationLogEntries,
                artifactID: "application-log",
                rule: FeedbackEvidencePolicy.applicationLog,
                selected: selections.includeApplicationLogs,
                contentsDirectory: contentsDirectory,
                createdAt: input.reportCreatedAt,
                artifacts: &artifacts,
                omissions: &omissions,
                warnings: &warnings
            )
            try cancellationCheck()
            try appendLogArtifact(
                entries: input.taskLogEntries,
                artifactID: "task-log",
                rule: FeedbackEvidencePolicy.taskLog,
                selected: selections.includeTaskLogs,
                contentsDirectory: contentsDirectory,
                createdAt: input.reportCreatedAt,
                artifacts: &artifacts,
                omissions: &omissions,
                warnings: &warnings
            )
            try cancellationCheck()
            try appendBrowserArtifact(
                input.browserRecords,
                selected: selections.includeBrowserEvidence,
                contentsDirectory: contentsDirectory,
                createdAt: input.reportCreatedAt,
                artifacts: &artifacts,
                omissions: &omissions,
                warnings: &warnings
            )
            try cancellationCheck()
            try appendScreenshots(
                input.screenshots,
                selected: selections.includeScreenshots,
                contentsDirectory: contentsDirectory,
                createdAt: input.reportCreatedAt,
                artifacts: &artifacts,
                omissions: &omissions
            )
            try cancellationCheck()
            try appendCrashArtifact(
                input.crashReports,
                selected: selections.includeMacOSDiagnostics,
                contentsDirectory: contentsDirectory,
                createdAt: input.reportCreatedAt,
                artifacts: &artifacts,
                omissions: &omissions,
                warnings: &warnings
            )
            try cancellationCheck()

            artifacts.sort { lhs, rhs in
                if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
                return lhs.artifactID < rhs.artifactID
            }
            try cancellationCheck()
            let archiveURL = stagingPackage.appendingPathComponent(FeedbackEvidencePolicy.archiveFileName)
            try createDeterministicArchive(
                from: contentsDirectory,
                relativePaths: artifacts.map(\.relativePath),
                at: archiveURL,
                createdAt: input.reportCreatedAt
            )
            try cancellationCheck()
            let archiveData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            let archiveSHA256 = FeedbackCanonicalJSONV1.sha256Hex(archiveData)

            let totalBytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
            let manifest = FeedbackEvidenceManifestV1(
                artifacts: artifacts,
                omissions: omissions,
                warnings: warnings,
                redactionPolicyVersion: FeedbackEvidencePolicy.redactionPolicyVersion,
                totalByteCount: totalBytes,
                archiveSHA256: archiveSHA256
            ).canonicalized()
            let manifestData = try FeedbackCanonicalJSONV1.encodeValidated(manifest)
            let manifestSHA256 = FeedbackCanonicalJSONV1.sha256Hex(manifestData)
            let manifestURL = stagingPackage.appendingPathComponent(FeedbackEvidencePolicy.manifestFileName)
            try writeFinalBytes(manifestData, to: manifestURL, createdAt: input.reportCreatedAt)

            try cancellationCheck()
            let reportData = try input.makeReportEnvelopeData(manifest)
            try cancellationCheck()
            guard FeedbackRawCanonicalJSONVerifier.isCanonicalObject(reportData) else {
                throw FeedbackEvidenceBuildError.invalidReportEnvelope("report bytes are not canonical V1 JSON")
            }
            let reportEnvelope = try FeedbackCanonicalJSONV1.decode(
                FeedbackReportEnvelopeV1.self,
                from: reportData
            )
            guard !FeedbackContactMemberPolicy.containsForbiddenMember(in: reportData) else {
                throw FeedbackEvidenceBuildError.invalidReportEnvelope("reporter contact members are not permitted")
            }
            guard reportEnvelope.payload.reportID.uuid == input.reportID else {
                throw FeedbackEvidenceBuildError.invalidReportEnvelope("report ID mismatch")
            }
            guard reportEnvelope.payload.createdAt == input.reportCreatedAt else {
                throw FeedbackEvidenceBuildError.invalidReportEnvelope("stable report timestamp mismatch")
            }
            guard reportEnvelope.payload.evidence.canonicalized() == manifest else {
                throw FeedbackEvidenceBuildError.invalidReportEnvelope("manifest mismatch")
            }
            let reportSHA256 = FeedbackCanonicalJSONV1.sha256Hex(reportData)
            let reportURL = stagingPackage.appendingPathComponent(FeedbackEvidencePolicy.reportFileName)
            try writeFinalBytes(reportData, to: reportURL, createdAt: input.reportCreatedAt)

            try cancellationCheck()
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: archiveURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: manifestURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: reportURL.path)
            try closeArtifactTree(artifacts, in: stagingPackage)
            try cancellationCheck()
            // Keep the directory owner-only and writable so the outbox can perform
            // its same-volume adoption rename. All closed package files are read-only.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingPackage.path)
            try cancellationCheck()
            try fileManager.moveItem(at: stagingPackage, to: finalPackage)
            movedToFinal = true
            try cancellationCheck()
            published = true

            let result = FeedbackPreparedEvidencePackage(
                reportID: input.reportID,
                reportCreatedAt: input.reportCreatedAt,
                directoryURL: finalPackage,
                reportURL: finalPackage.appendingPathComponent(FeedbackEvidencePolicy.reportFileName),
                archiveURL: finalPackage.appendingPathComponent(FeedbackEvidencePolicy.archiveFileName),
                manifestURL: finalPackage.appendingPathComponent(FeedbackEvidencePolicy.manifestFileName),
                manifest: manifest,
                manifestSHA256: manifestSHA256,
                reportSHA256: reportSHA256,
                archiveSHA256: archiveSHA256
            )
            AppLogger.info(
                "Prepared feedback evidence package artifacts=\(manifest.artifacts.count) omissions=\(manifest.omissions.count)",
                category: "Diagnostics"
            )
            return result
        } catch {
            let sanitizedError = FeedbackEvidenceSanitizer.sanitize(
                error.localizedDescription,
                maximumBytes: 500
            ).text
            AppLogger.error(
                "Feedback evidence preparation failed: \(sanitizedError)",
                category: "Diagnostics"
            )
            throw error
        }
    }

    private func appendLogArtifact(
        entries: [LogEntry],
        artifactID: String,
        rule: FeedbackEvidencePolicy.Rule,
        selected: Bool,
        contentsDirectory: URL,
        createdAt: Date,
        artifacts: inout [FeedbackEvidenceArtifactV1],
        omissions: inout [FeedbackEvidenceOmissionV1],
        warnings: inout [FeedbackEvidenceWarningV1]
    ) throws {
        guard !entries.isEmpty else { return }
        guard selected else {
            omissions.append(FeedbackEvidenceOmissionV1(
                artifactID: artifactID,
                kind: rule.kind,
                reason: .notSelected,
                detail: "This evidence type was not selected."
            ))
            return
        }

        let transformed = try transformLogEntries(entries, artifactID: artifactID, maximumBytes: rule.maximumBytes)
        appendWarnings(for: transformed, artifactID: artifactID, to: &warnings)
        try appendArtifact(
            transformed,
            artifactID: artifactID,
            rule: rule,
            contentsDirectory: contentsDirectory,
            createdAt: createdAt,
            artifacts: &artifacts,
            omissions: &omissions
        )
    }

    private func transformLogEntries(
        _ entries: [LogEntry],
        artifactID: String,
        maximumBytes: Int
    ) throws -> FeedbackTransformedArtifact {
        let ordered = entries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.level != rhs.level { return lhs.level < rhs.level }
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            if lhs.taskID != rhs.taskID { return (lhs.taskID?.uuidString ?? "") < (rhs.taskID?.uuidString ?? "") }
            return lhs.message < rhs.message
        }
        var output = Data()
        var redaction = FeedbackRedactionAccumulator()
        var includedCount = 0

        for entry in ordered {
            var entryRedaction = FeedbackRedactionAccumulator()
            let record = FeedbackLogEvidenceRecord(
                timestamp: entry.timestamp,
                level: entryRedaction.sanitize(entry.level, maximumBytes: 32),
                category: entryRedaction.sanitize(entry.category, maximumBytes: 120),
                taskID: entry.taskID?.uuidString.lowercased(),
                message: entryRedaction.sanitize(entry.message, maximumBytes: 4_000)
            )
            var line = try FeedbackCanonicalJSONV1.encode(record)
            line.append(0x0a)
            guard output.count + line.count <= maximumBytes else { break }
            output.append(line)
            redaction.add(entryRedaction.summary)
            includedCount += 1
        }

        let warnings = includedCount < ordered.count
            ? [FeedbackEvidenceWarningV1(
                code: "log_entries_truncated",
                artifactID: artifactID,
                message: "Log evidence retained \(includedCount) of \(ordered.count) sanitized entries within the artifact limit."
            )]
            : []
        return FeedbackTransformedArtifact(data: output, redaction: redaction.summary, warnings: warnings)
    }

    private func appendBrowserArtifact(
        _ records: [FeedbackBrowserEvidenceRecord],
        selected: Bool,
        contentsDirectory: URL,
        createdAt: Date,
        artifacts: inout [FeedbackEvidenceArtifactV1],
        omissions: inout [FeedbackEvidenceOmissionV1],
        warnings: inout [FeedbackEvidenceWarningV1]
    ) throws {
        guard !records.isEmpty else { return }
        let rule = FeedbackEvidencePolicy.browserEvidence
        guard selected else {
            omissions.append(FeedbackEvidenceOmissionV1(
                artifactID: "browser-evidence",
                kind: rule.kind,
                reason: .notSelected,
                detail: "Browser evidence requires explicit opt-in."
            ))
            return
        }
        guard let transformed = try FeedbackBrowserEvidenceTransformer.transform(records) else { return }
        appendWarnings(for: transformed, artifactID: "browser-evidence", to: &warnings)
        try appendArtifact(
            transformed,
            artifactID: "browser-evidence",
            rule: rule,
            contentsDirectory: contentsDirectory,
            createdAt: createdAt,
            artifacts: &artifacts,
            omissions: &omissions
        )
    }

    private func appendScreenshots(
        _ screenshots: [FeedbackScreenshotCandidate],
        selected: Bool,
        contentsDirectory: URL,
        createdAt: Date,
        artifacts: inout [FeedbackEvidenceArtifactV1],
        omissions: inout [FeedbackEvidenceOmissionV1]
    ) throws {
        guard !screenshots.isEmpty else { return }
        let ordered = screenshots.sorted { lhs, rhs in
            let leftHash = FeedbackCanonicalJSONV1.sha256Hex(lhs.jpegData)
            let rightHash = FeedbackCanonicalJSONV1.sha256Hex(rhs.jpegData)
            if leftHash != rightHash { return leftHash < rightHash }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            return lhs.source < rhs.source
        }
        guard selected else {
            for index in ordered.indices {
                omissions.append(FeedbackEvidenceOmissionV1(
                    artifactID: String(format: "browser-screenshot-%03d", index + 1),
                    kind: .screenshot,
                    reason: .notSelected,
                    detail: "Screenshots require a separate explicit opt-in."
                ))
            }
            return
        }

        for (index, screenshot) in ordered.enumerated() {
            let artifactID = String(format: "browser-screenshot-%03d", index + 1)
            guard index < FeedbackEvidencePolicy.maximumScreenshots else {
                omissions.append(FeedbackEvidenceOmissionV1(
                    artifactID: artifactID,
                    kind: .screenshot,
                    reason: .oversized,
                    detail: "Screenshot count exceeds the V1 collection limit."
                ))
                continue
            }
            let rule = FeedbackEvidencePolicy.screenshotRule(index: index)
            guard let transformed = FeedbackScreenshotEvidenceTransformer.transform(screenshot) else {
                omissions.append(FeedbackEvidenceOmissionV1(
                    artifactID: artifactID,
                    kind: .screenshot,
                    reason: .unsupported,
                    detail: "Screenshot is not a valid JPEG thumbnail."
                ))
                continue
            }
            try appendArtifact(
                transformed,
                artifactID: artifactID,
                rule: rule,
                contentsDirectory: contentsDirectory,
                createdAt: createdAt,
                artifacts: &artifacts,
                omissions: &omissions
            )
        }
    }

    private func appendCrashArtifact(
        _ reports: [CrashReportSummary],
        selected: Bool,
        contentsDirectory: URL,
        createdAt: Date,
        artifacts: inout [FeedbackEvidenceArtifactV1],
        omissions: inout [FeedbackEvidenceOmissionV1],
        warnings: inout [FeedbackEvidenceWarningV1]
    ) throws {
        guard !reports.isEmpty else { return }
        let rule = FeedbackEvidencePolicy.macOSDiagnostic
        guard selected else {
            for index in reports.indices {
                omissions.append(FeedbackEvidenceOmissionV1(
                    artifactID: String(format: "macos-diagnostic-%03d", index + 1),
                    kind: rule.kind,
                    reason: .notSelected,
                    detail: "macOS diagnostics require explicit opt-in."
                ))
            }
            return
        }
        let result = try FeedbackCrashEvidenceTransformer.transform(reports, fileManager: fileManager)
        omissions.append(contentsOf: result.omissions)
        guard let transformed = result.artifact else { return }
        appendWarnings(for: transformed, artifactID: "macos-diagnostics", to: &warnings)
        try appendArtifact(
            transformed,
            artifactID: "macos-diagnostics",
            rule: rule,
            contentsDirectory: contentsDirectory,
            createdAt: createdAt,
            artifacts: &artifacts,
            omissions: &omissions
        )
    }

    private func appendArtifact(
        _ transformed: FeedbackTransformedArtifact,
        artifactID: String,
        rule: FeedbackEvidencePolicy.Rule,
        contentsDirectory: URL,
        createdAt: Date,
        artifacts: inout [FeedbackEvidenceArtifactV1],
        omissions: inout [FeedbackEvidenceOmissionV1]
    ) throws {
        guard transformed.data.count <= rule.maximumBytes,
              transformed.data.count <= FeedbackContractLimitsV1.maximumArtifactBytes else {
            omissions.append(FeedbackEvidenceOmissionV1(
                artifactID: artifactID,
                kind: rule.kind,
                reason: .oversized,
                detail: "Sanitized artifact exceeds the V1 artifact limit."
            ))
            return
        }
        let retainedBytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
        guard retainedBytes + Int64(transformed.data.count) <= FeedbackContractLimitsV1.maximumEvidenceBytes else {
            omissions.append(FeedbackEvidenceOmissionV1(
                artifactID: artifactID,
                kind: rule.kind,
                reason: .oversized,
                detail: "Sanitized evidence exceeds the V1 package limit."
            ))
            return
        }
        let destination = contentsDirectory.appendingPathComponent(rule.relativePath)
        try assertContained(destination, by: contentsDirectory)
        try writeFinalBytes(transformed.data, to: destination, createdAt: createdAt)
        artifacts.append(FeedbackEvidenceArtifactV1(
            artifactID: artifactID,
            kind: rule.kind,
            disclosureClass: rule.disclosureClass,
            relativePath: rule.relativePath,
            mediaType: rule.mediaType,
            byteCount: Int64(transformed.data.count),
            sha256: FeedbackCanonicalJSONV1.sha256Hex(transformed.data),
            redaction: transformed.redaction
        ))
    }

    private func appendWarnings(
        for transformed: FeedbackTransformedArtifact,
        artifactID: String,
        to warnings: inout [FeedbackEvidenceWarningV1]
    ) {
        warnings.append(contentsOf: transformed.warnings)
        guard transformed.redaction.replacements > 0 else { return }
        warnings.append(FeedbackEvidenceWarningV1(
            code: "artifact_redacted",
            artifactID: artifactID,
            message: "Sensitive values were removed from this artifact by the feedback privacy policy."
        ))
    }

    private func writeFinalBytes(_ data: Data, to url: URL, createdAt: Date) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writeData(data, url)
        try fileManager.setAttributes([
            .posixPermissions: 0o600,
            .modificationDate: createdAt,
            .creationDate: createdAt
        ], ofItemAtPath: url.path)
    }

    private func createDeterministicArchive(
        from contentsDirectory: URL,
        relativePaths: [String],
        at archiveURL: URL,
        createdAt: Date
    ) throws {
        if relativePaths.isEmpty {
            let emptyZip = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18))
            try writeFinalBytes(emptyZip, to: archiveURL, createdAt: createdAt)
            return
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw FeedbackEvidenceBuildError.noArchiveTool
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = contentsDirectory
        process.arguments = ["-X", "-q", archiveURL.path] + relativePaths.sorted()
        var environment = processEnvironment()
        environment["TZ"] = "UTC"
        environment["LC_ALL"] = "C"
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FeedbackEvidenceBuildError.archiveCreationFailed(
                FeedbackEvidenceSanitizer.sanitize(message, maximumBytes: 500).text
            )
        }
        try fileManager.setAttributes([
            .posixPermissions: 0o600,
            .modificationDate: createdAt,
            .creationDate: createdAt
        ], ofItemAtPath: archiveURL.path)
    }

    private func closeArtifactTree(
        _ artifacts: [FeedbackEvidenceArtifactV1],
        in packageDirectory: URL
    ) throws {
        var directories: Set<URL> = []
        for artifact in artifacts {
            let artifactURL = packageDirectory.appendingPathComponent(artifact.relativePath)
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: artifactURL.path)

            var directory = artifactURL.deletingLastPathComponent()
            while directory != packageDirectory {
                directories.insert(directory)
                directory.deleteLastPathComponent()
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
    }

    private func removeConstructionPackage(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if let subpaths = try? fileManager.subpathsOfDirectory(atPath: url.path) {
            for relativePath in subpaths {
                let child = url.appendingPathComponent(relativePath)
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
                }
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? fileManager.removeItem(at: url)
    }

    private func assertContained(_ url: URL, by root: URL) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(rootPath) else {
            throw FeedbackEvidenceBuildError.unsafeDestination(candidate)
        }
    }

}
