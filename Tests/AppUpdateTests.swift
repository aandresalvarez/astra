import Foundation
import Testing
@testable import ASTRA

@Suite("App Update Safety")
struct AppUpdateSafetyTests {
    @Test("validates Sparkle public EdDSA key format")
    func validatesSparklePublicEDKeyFormat() {
        let validKey = Data(repeating: 0, count: 32).base64EncodedString()

        #expect(AppUpdateController.isValidSparklePublicEDKey(validKey))
        #expect(!AppUpdateController.isValidSparklePublicEDKey(""))
        #expect(!AppUpdateController.isValidSparklePublicEDKey("test"))
        #expect(!AppUpdateController.isValidSparklePublicEDKey(Data(repeating: 0, count: 31).base64EncodedString()))
        #expect(!AppUpdateController.isValidSparklePublicEDKey(Data(repeating: 0, count: 33).base64EncodedString()))
    }

    @Test("idle queue allows install")
    func idleQueueAllowsInstall() {
        #expect(!AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: 0
        ))
    }

    @Test("running or processing work blocks install")
    func runningWorkBlocksInstall() {
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: true,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: 0
        ))
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 1,
            activeTaskCount: 0,
            runningTaskCount: 0
        ))
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 1,
            runningTaskCount: 0
        ))
        #expect(AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: 1
        ))
    }

    @Test("queued but idle work does not block install")
    func queuedButIdleWorkDoesNotBlockInstall() {
        #expect(!AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: false,
            activeWorkerCount: 0,
            activeTaskCount: 0,
            runningTaskCount: 0
        ))
    }
}

@Suite("App Channels")
struct AppChannelTests {
    @Test("production keeps stable storage and keychain names")
    func productionKeepsStableNames() {
        #expect(AppChannel.production.displayName == "ASTRA")
        #expect(AppChannel.production.appSupportDirectoryName == "Astra")
        #expect(AppChannel.production.keychainConnectorPrefix == "astra")
        #expect(AppChannel.production.keychainSkillPrefix == "astra-skill")
    }

    @Test("development uses isolated names")
    func developmentUsesIsolatedNames() {
        #expect(AppChannel.development.displayName == "ASTRA Dev")
        #expect(AppChannel.development.appSupportDirectoryName == "AstraDev")
        #expect(AppChannel.development.keychainConnectorPrefix == "astra-dev")
        #expect(AppChannel.development.defaultWorkspacesRoot.contains("Astra Dev"))
    }

    @Test("channel identities do not overlap")
    func channelIdentitiesDoNotOverlap() {
        let channels: [AppChannel] = [.production, .development, .beta]

        #expect(Set(channels.map(\.displayName)).count == channels.count)
        #expect(Set(channels.map(\.appSupportDirectoryName)).count == channels.count)
        #expect(Set(channels.map(\.defaultWorkspacesRoot)).count == channels.count)
        #expect(Set(channels.map(\.keychainConnectorPrefix)).count == channels.count)
        #expect(Set(channels.map(\.keychainSkillPrefix)).count == channels.count)
        #expect(AppChannel.production.defaultWorkspacesRoot.contains("Astra/Workspaces"))
        #expect(!AppChannel.production.defaultWorkspacesRoot.contains("Astra Dev"))
    }
}

@Suite("Pre-update Store Backup")
struct AppUpdateBackupTests {
    @Test("copy backup preserves store files without moving originals")
    func copyBackupPreservesStoreFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-update-backup-\(UUID().uuidString)", isDirectory: true)
        let store = root.appendingPathComponent("default.store")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))

        let copied = try WorkspaceRecoveryService.copyStoreBackup(
            at: store,
            backupRoot: backupRoot,
            label: "test-pre-update"
        )

        #expect(copied.count == 3)
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(FileManager.default.fileExists(atPath: store.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: store.path + "-shm"))
        #expect(try String(contentsOf: store, encoding: .utf8) == "store")

        let copiedNames = Set(copied.map(\.lastPathComponent))
        #expect(copiedNames == ["default.store", "default.store-wal", "default.store-shm"])

        for url in copied {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
