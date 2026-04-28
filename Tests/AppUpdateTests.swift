import Foundation
import Testing
@testable import ASTRA

@Suite("App Update Safety")
struct AppUpdateSafetyTests {
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
