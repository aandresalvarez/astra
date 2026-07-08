import Foundation
import Testing
import ASTRACore
@testable import ASTRA

private final class FakeFileManager: FileManager {
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

@Suite("Applications Folder Mover")
struct ApplicationsFolderMoverTests {
    private let systemApplications = URL(fileURLWithPath: "/Applications")
    private let userApplications = URL(fileURLWithPath: "/Users/test/Applications")

    private func writableEmptyFileManager() -> FakeFileManager {
        let fileManager = FakeFileManager()
        fileManager.directoryPaths = ["/Applications", "/Users/test/Applications"]
        fileManager.writableDirectoryPaths = ["/Applications", "/Users/test/Applications"]
        return fileManager
    }

    @Test("development channel never offers to move, even with a valid destination")
    func developmentChannelNeverOffers() {
        let decision = ApplicationsFolderMover.decide(
            channel: .development,
            currentBundlePath: "/private/var/folders/xyz/T/AppTranslocation/uuid/d/ASTRA Dev.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .doNothing)
    }

    @Test("a prior decline suppresses the prompt on later launches")
    func priorDeclineSuppressesPrompt() {
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Downloads/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: true,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .doNothing)
    }

    @Test("already running from /Applications does nothing")
    func alreadyInSystemApplicationsDoesNothing() {
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Applications/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .doNothing)
    }

    @Test("already running from ~/Applications does nothing")
    func alreadyInUserApplicationsDoesNothing() {
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Applications/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .doNothing)
    }

    @Test("running from Downloads with a writable, empty /Applications offers to move there")
    func offersSystemApplicationsWhenWritableAndEmpty() {
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Downloads/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .offerMove(destination: systemApplications.appendingPathComponent("ASTRA.app")))
    }

    @Test("a translocated launch path is treated the same as any other non-Applications path")
    func translocatedPathOffersMove() {
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/private/var/folders/xyz/T/AppTranslocation/uuid/d/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .offerMove(destination: systemApplications.appendingPathComponent("ASTRA.app")))
    }

    @Test("beta channel offers to move using the beta bundle name, not the production one")
    func betaChannelUsesBetaBundleName() {
        let decision = ApplicationsFolderMover.decide(
            channel: .beta,
            currentBundlePath: "/Users/test/Downloads/ASTRA Beta.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: writableEmptyFileManager()
        )
        #expect(decision.action == .offerMove(destination: systemApplications.appendingPathComponent("ASTRA Beta.app")))
    }

    @Test("a bundle already present at /Applications is never clobbered; falls through to ~/Applications")
    func existingSystemApplicationsBundleFallsThroughToUserApplications() {
        let fileManager = writableEmptyFileManager()
        fileManager.existingFilePaths.insert("/Applications/ASTRA.app")
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Downloads/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: fileManager
        )
        #expect(decision.action == .offerMove(destination: userApplications.appendingPathComponent("ASTRA.app")))
    }

    @Test("a non-writable /Applications (standard, non-admin user) falls through to ~/Applications")
    func nonWritableSystemApplicationsFallsThroughToUserApplications() {
        let fileManager = writableEmptyFileManager()
        fileManager.writableDirectoryPaths.remove("/Applications")
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Downloads/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: fileManager
        )
        #expect(decision.action == .offerMove(destination: userApplications.appendingPathComponent("ASTRA.app")))
    }

    @Test("no writable, empty destination anywhere does nothing rather than forcing a clobber")
    func noViableDestinationDoesNothing() {
        let fileManager = writableEmptyFileManager()
        fileManager.existingFilePaths.insert("/Applications/ASTRA.app")
        fileManager.existingFilePaths.insert("/Users/test/Applications/ASTRA.app")
        let decision = ApplicationsFolderMover.decide(
            channel: .production,
            currentBundlePath: "/Users/test/Downloads/ASTRA.app",
            applicationsDirectories: [systemApplications, userApplications],
            hasDeclinedBefore: false,
            fileManager: fileManager
        )
        #expect(decision.action == .doNothing)
    }
}
