import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Feedback Manual Export")
struct FeedbackManualExportTests {
    @Test("Manual export contains the exact reviewed package and does not queue it")
    @MainActor
    func exactReviewedPackageExportsWithoutStateMutation() async throws {
        let fixture = try ManualExportFixture()
        defer { fixture.remove() }
        let launch = FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
        let form = validManualExportForm(launch: launch)
        let service = fixture.service(evidenceSource: FeedbackReportEvidenceSource(
            applicationLogEntries: [
                LogEntry(
                    level: .info,
                    category: "FeedbackExportTest",
                    message: "A safe deterministic log line",
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ],
            taskLogEntries: [],
            browserRecords: [],
            screenshots: [],
            crashReports: []
        ))
        let preview = try await service.preparePreview(launch: launch, form: form)
        let exports = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let firstURL = exports.appendingPathComponent("first.zip")
        let secondURL = exports.appendingPathComponent("second.zip")

        let first = try service.exportForManualDelivery(
            preview,
            launch: launch,
            form: form,
            destinationURL: firstURL
        )
        let second = try service.exportForManualDelivery(
            preview,
            launch: launch,
            form: form,
            destinationURL: secondURL
        )

        let expected = ([
            FeedbackEvidencePolicy.reportFileName,
            FeedbackEvidencePolicy.manifestFileName,
            FeedbackEvidencePolicy.archiveFileName,
        ] + preview.manifest.artifacts.map(\.relativePath)).sorted()
        #expect(try manualExportArchiveEntries(firstURL) == expected)
        #expect(first.fileCount == expected.count)
        #expect(first.byteCount > 0)
        #expect(first.sha256 == FeedbackCanonicalJSONV1.sha256Hex(try Data(contentsOf: firstURL)))
        #expect(try Data(contentsOf: firstURL) == Data(contentsOf: secondURL))
        #expect(first.sha256 == second.sha256)
        for relativePath in expected {
            #expect(
                try manualExportArchiveEntry(relativePath, archive: firstURL)
                    == Data(contentsOf: preview.package.directoryURL.appendingPathComponent(relativePath))
            )
        }

        let report = try fetchManualExportReport(fixture.container, id: launch.id)
        #expect(report?.localStatus == .draft)
        #expect(report?.packageRelativePath == nil)
        #expect(FileManager.default.fileExists(atPath: preview.package.directoryURL.path))
        #expect(!FeedbackReportAccessibilityID.manualExport.isEmpty)
    }

    @Test("Changed reviewed bytes fail closed without creating an export")
    @MainActor
    func changedPackageDoesNotExport() async throws {
        let fixture = try ManualExportFixture()
        defer { fixture.remove() }
        let launch = FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
        let form = validManualExportForm(launch: launch)
        let service = fixture.service(evidenceSource: .empty)
        let preview = try await service.preparePreview(launch: launch, form: form)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: preview.package.manifestURL.path
        )
        try Data("changed manifest".utf8).write(to: preview.package.manifestURL)
        let destination = fixture.root.appendingPathComponent("must-not-exist.zip")

        #expect(throws: (any Error).self) {
            _ = try service.exportForManualDelivery(
                preview,
                launch: launch,
                form: form,
                destinationURL: destination
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fetchManualExportReport(fixture.container, id: launch.id)?.localStatus == .draft)
    }

    @Test("A locally queued report remains available for manual export")
    @MainActor
    func queuedReportCanStillExport() async throws {
        let fixture = try ManualExportFixture()
        defer { fixture.remove() }
        let launch = FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
        let form = validManualExportForm(launch: launch)
        let service = fixture.service(evidenceSource: .empty)
        let reviewed = try await service.preparePreview(launch: launch, form: form)
        let immediateQueuedPreview = try service.confirmQueueAndRestoreManualExport(
            reviewed,
            launch: launch,
            form: form
        )
        #expect(immediateQueuedPreview.ownership == .adoptedOutbox)
        let restoredForm = try service.restoredManualExportForm(
            reportID: launch.id,
            launch: launch
        )
        let restored = try service.restoredManualExportPreview(
            reportID: launch.id,
            launch: launch,
            form: restoredForm
        )
        let destination = fixture.root.appendingPathComponent("queued-feedback.zip")

        let receipt = try service.exportForManualDelivery(
            restored,
            launch: launch,
            form: restoredForm,
            destinationURL: destination
        )

        #expect(restored.ownership == .adoptedOutbox)
        #expect(receipt.url == destination)
        #expect(try fetchManualExportReport(fixture.container, id: launch.id)?.localStatus == .queued)
        #expect(try manualExportArchiveEntries(destination).contains(FeedbackEvidencePolicy.reportFileName))
    }

    @Test("Export destination cannot modify private package storage")
    @MainActor
    func destinationInsidePackageFailsClosed() async throws {
        let fixture = try ManualExportFixture()
        defer { fixture.remove() }
        let launch = FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)
        let form = validManualExportForm(launch: launch)
        let service = fixture.service(evidenceSource: .empty)
        let preview = try await service.preparePreview(launch: launch, form: form)
        let destination = preview.package.directoryURL.appendingPathComponent("manual-export.zip")

        #expect(throws: FeedbackManualExportError.invalidDestination) {
            _ = try service.exportForManualDelivery(
                preview,
                launch: launch,
                form: form,
                destinationURL: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: preview.package.directoryURL.path))

        let alias = fixture.root.appendingPathComponent("package-parent-alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: preview.package.directoryURL.deletingLastPathComponent()
        )
        let aliasedDestination = alias
            .appendingPathComponent(preview.package.directoryURL.lastPathComponent, isDirectory: true)
            .appendingPathComponent("aliased-export.zip")
        #expect(throws: FeedbackManualExportError.invalidDestination) {
            _ = try service.exportForManualDelivery(
                preview,
                launch: launch,
                form: form,
                destinationURL: aliasedDestination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: aliasedDestination.path))
    }
}

@MainActor
private struct ManualExportFixture {
    let root: URL
    let container: ModelContainer
    let defaults: UserDefaults
    let crashService: FeedbackCrashOfferService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "feedback-manual-export-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try makeFeedbackOutboxContainer()
        let suite = "feedback-manual-export-\(UUID().uuidString.lowercased())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "manualExportSuite")
        crashService = FeedbackCrashOfferService(defaults: defaults)
    }

    func service(evidenceSource: FeedbackReportEvidenceSource) -> FeedbackReportPreparationService {
        FeedbackReportPreparationService(
            modelContainer: container,
            crashOfferService: crashService,
            storageRoot: root,
            defaults: defaults,
            evidenceSourceProvider: { _, _, _ in evidenceSource }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        if let suite = defaults.string(forKey: "manualExportSuite") {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private func validManualExportForm(launch: FeedbackReportLaunch) -> FeedbackReportFormState {
    var form = FeedbackReportFormState(
        launch: launch,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    form.intendedOutcome = "Send useful feedback"
    form.actualResult = "Remote delivery is not available"
    form.expectedResult = "Export a sanitized bundle"
    return form
}

@MainActor
private func fetchManualExportReport(_ container: ModelContainer, id: UUID) throws -> FeedbackReport? {
    let context = ModelContext(container)
    let reportID = id
    return try context.fetch(FetchDescriptor<FeedbackReport>(
        predicate: #Predicate<FeedbackReport> { $0.id == reportID }
    )).first
}

private func manualExportArchiveEntries(_ archiveURL: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", archiveURL.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
        .sorted()
}

private func manualExportArchiveEntry(_ path: String, archive: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return output.fileHandleForReading.readDataToEndOfFile()
}
