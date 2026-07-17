import Foundation
import Testing
import ASTRACore
@testable import ASTRA

private final class InstallerFakeFileManager: FileManager {
    var existingFilePaths: Set<String> = []
    var directoryPaths: Set<String> = []
    var writableDirectoryPaths: Set<String> = []

    override func fileExists(atPath path: String) -> Bool {
        existingFilePaths.contains(path) || directoryPaths.contains(path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let isDir = directoryPaths.contains(path)
        isDirectory?.pointee = ObjCBool(isDir)
        return isDir || existingFilePaths.contains(path)
    }

    override func isWritableFile(atPath path: String) -> Bool {
        writableDirectoryPaths.contains(path)
    }
}

@Suite("Guided Application Installation")
struct ApplicationsFolderMoverTests {
    private let systemApplications = URL(fileURLWithPath: "/Applications")
    private let userApplications = URL(fileURLWithPath: "/Users/test/Applications")
    private let source = URL(fileURLWithPath: "/Volumes/ASTRA/Install ASTRA.app")
    private let metadata = ApplicationBundleMetadata(
        displayName: "ASTRA",
        version: "0.1.29",
        bundleIdentifier: "com.coral.ASTRA"
    )

    private func writableEmptyFileManager() -> InstallerFakeFileManager {
        let fileManager = InstallerFakeFileManager()
        fileManager.directoryPaths = ["/Applications", "/Users/test/Applications"]
        fileManager.writableDirectoryPaths = ["/Applications", "/Users/test/Applications"]
        return fileManager
    }

    @Test("development channel never presents the installer")
    func developmentChannelNeverPresentsInstaller() {
        let decision = ApplicationInstallationPlanner.decide(
            channel: .development,
            currentBundleURL: source,
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: writableEmptyFileManager()
        )

        #expect(decision == .doNothing)
    }

    @Test("a production disk-image launch is installer-only before persistent startup")
    func diskImageLaunchRequiresInstallerOnlyMode() {
        #expect(ApplicationInstallationPlanner.requiresInstallation(
            channel: .production,
            currentBundleURL: source,
            applicationsDirectories: [systemApplications, userApplications]
        ))
        #expect(!ApplicationInstallationPlanner.requiresInstallation(
            channel: .production,
            currentBundleURL: URL(fileURLWithPath: "/Applications/ASTRA.app"),
            applicationsDirectories: [systemApplications, userApplications]
        ))
    }

    @Test("an application already running from Applications skips installation")
    func installedApplicationDoesNothing() {
        let decision = ApplicationInstallationPlanner.decide(
            channel: .production,
            currentBundleURL: URL(fileURLWithPath: "/Applications/ASTRA.app"),
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: writableEmptyFileManager()
        )

        #expect(decision == .doNothing)
    }

    @Test("a first install chooses the system Applications folder")
    func firstInstallChoosesSystemApplications() {
        let decision = ApplicationInstallationPlanner.decide(
            channel: .production,
            currentBundleURL: source,
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: writableEmptyFileManager()
        )

        guard case .present(let plan) = decision else {
            Issue.record("Expected an installation plan")
            return
        }
        #expect(plan.destination.path == "/Applications/ASTRA.app")
        #expect(plan.replacesExistingCopy == false)
        #expect(plan.existingVersion == nil)
    }

    @Test("an existing system copy becomes an explicit replacement instead of a second user-level install")
    func existingCopyBecomesReplacementPlan() {
        let fileManager = writableEmptyFileManager()
        fileManager.existingFilePaths.insert("/Applications/ASTRA.app")

        let decision = ApplicationInstallationPlanner.decide(
            channel: .production,
            currentBundleURL: source,
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: fileManager,
            metadataReader: { url in
                guard url.path == "/Applications/ASTRA.app" else { return nil }
                return ApplicationBundleMetadata(
                    displayName: "ASTRA",
                    version: "0.1.28",
                    bundleIdentifier: "com.coral.ASTRA"
                )
            }
        )

        guard case .present(let plan) = decision else {
            Issue.record("Expected a replacement plan")
            return
        }
        #expect(plan.destination.path == "/Applications/ASTRA.app")
        #expect(plan.replacesExistingCopy)
        #expect(plan.existingVersion == "0.1.28")
    }

    @Test("a standard user falls back to their writable Applications folder")
    func nonWritableSystemApplicationsFallsBackToUserApplications() {
        let fileManager = writableEmptyFileManager()
        fileManager.writableDirectoryPaths.remove("/Applications")

        let decision = ApplicationInstallationPlanner.decide(
            channel: .production,
            currentBundleURL: source,
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: fileManager
        )

        guard case .present(let plan) = decision else {
            Issue.record("Expected a user Applications installation plan")
            return
        }
        #expect(plan.destination.path == "/Users/test/Applications/ASTRA.app")
    }

    @Test("no writable Applications directory is surfaced as unavailable")
    func noWritableDestinationIsUnavailable() {
        let fileManager = writableEmptyFileManager()
        fileManager.writableDirectoryPaths = []

        let decision = ApplicationInstallationPlanner.decide(
            channel: .production,
            currentBundleURL: source,
            sourceMetadata: metadata,
            applicationsDirectories: [systemApplications, userApplications],
            fileManager: fileManager
        )

        #expect(decision == .unavailable)
    }

    @Test("replacement presentation states the versions before the user acts")
    func replacementPresentationIsExplicit() {
        let plan = ApplicationInstallationPlan(
            source: source,
            destination: URL(fileURLWithPath: "/Applications/ASTRA.app"),
            sourceMetadata: metadata,
            replacesExistingCopy: true,
            existingVersion: "0.1.28"
        )

        let presentation = ApplicationInstallerPresentation(plan: plan)

        #expect(presentation.title == "Install ASTRA")
        #expect(presentation.statusTitle == "Existing copy found")
        #expect(presentation.statusDetail == "Version 0.1.28 will be replaced by 0.1.29.")
        #expect(presentation.primaryActionTitle == "Install and Open ASTRA")
    }

    @Test("the installer window cannot close while the application copy is in progress")
    func installationCannotBeInterruptedByClosingTheWindow() {
        #expect(ApplicationInstallerModalClosePolicy.allowsClose(phase: .ready))
        #expect(!ApplicationInstallerModalClosePolicy.allowsClose(phase: .installing))
        #expect(ApplicationInstallerModalClosePolicy.allowsClose(phase: .completed))
        #expect(ApplicationInstallerModalClosePolicy.allowsClose(phase: .failed("copy failed")))
    }

    @Test("the installer copies and verifies a new application bundle")
    func installsNewBundle() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Install ASTRA.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/ASTRA.app", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeApplication(at: source, version: "0.1.29", marker: "new")
        let metadata = try ApplicationBundleMetadata.read(from: source)
        let plan = ApplicationInstallationPlan(
            source: source,
            destination: destination,
            sourceMetadata: metadata,
            replacesExistingCopy: false,
            existingVersion: nil
        )

        try ApplicationInstallationService.install(plan, stagingIdentifier: "new-install")

        #expect(try ApplicationBundleMetadata.read(from: destination).version == "0.1.29")
        #expect(try marker(at: destination) == "new")
    }

    @Test("replacement removes the stale bundle and leaves the verified new version")
    func replacesExistingBundle() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Install ASTRA.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/ASTRA.app", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeApplication(at: source, version: "0.1.29", marker: "new")
        try writeApplication(at: destination, version: "0.1.28", marker: "old")
        let metadata = try ApplicationBundleMetadata.read(from: source)
        let plan = ApplicationInstallationPlan(
            source: source,
            destination: destination,
            sourceMetadata: metadata,
            replacesExistingCopy: true,
            existingVersion: "0.1.28"
        )

        try ApplicationInstallationService.install(plan, stagingIdentifier: "replacement")

        #expect(try ApplicationBundleMetadata.read(from: destination).version == "0.1.29")
        #expect(try marker(at: destination) == "new")
    }

    @Test("a failed source validation leaves the existing installed copy untouched")
    func failurePreservesExistingBundle() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Missing ASTRA.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/ASTRA.app", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeApplication(at: destination, version: "0.1.28", marker: "old")
        let plan = ApplicationInstallationPlan(
            source: source,
            destination: destination,
            sourceMetadata: metadata,
            replacesExistingCopy: true,
            existingVersion: "0.1.28"
        )

        #expect(throws: (any Error).self) {
            try ApplicationInstallationService.install(plan, stagingIdentifier: "failed")
        }
        #expect(try ApplicationBundleMetadata.read(from: destination).version == "0.1.28")
        #expect(try marker(at: destination) == "old")
    }

    @Test("relaunch waits for the installer process to exit before opening the installed app")
    func relaunchWaitsForInstallerExit() {
        let destination = URL(fileURLWithPath: "/Applications/ASTRA.app")
        let command = ApplicationRelauncher.command(processID: 42, destination: destination)

        #expect(command.executableURL.path == "/bin/sh")
        #expect(command.arguments[1].contains("while kill -0 \"$1\""))
        #expect(command.arguments[1].contains("exec /usr/bin/open \"$2\""))
        #expect(command.arguments[3] == "42")
        #expect(command.arguments[4] == destination.path)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-guided-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeApplication(at url: URL, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleDisplayName": "ASTRA",
            "CFBundleName": "ASTRA",
            "CFBundleShortVersionString": version,
            "CFBundleIdentifier": "com.coral.ASTRA"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"), options: .atomic)
    }

    private func marker(at applicationURL: URL) throws -> String {
        let data = try Data(contentsOf: applicationURL.appendingPathComponent("Contents/marker.txt"))
        return String(decoding: data, as: UTF8.self)
    }
}
