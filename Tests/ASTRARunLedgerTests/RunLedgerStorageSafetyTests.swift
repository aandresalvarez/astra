@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger storage refusal safety")
struct RunLedgerStorageSafetyTests {
    @Test("A symlink in the parent path is rejected without creating through it")
    func parentSymlinkIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let configuration = RunLedgerConfiguration(
            ledgerDirectoryURL: link.appendingPathComponent("ledger", isDirectory: true),
            installationID: installationID(200)
        )

        guard case .unsafeStorage = ledgerError({ _ = try RunLedger(configuration: configuration) }) else {
            Issue.record("Expected unsafe parent symlink rejection")
            return
        }
        #expect(!FileManager.default.fileExists(
            atPath: real.appendingPathComponent("ledger").path
        ))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    }

    @Test("An insecure preexisting dedicated directory is refused and never chmodded")
    func insecureDirectoryIsNotMutated() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let configuration = RunLedgerConfiguration(
            ledgerDirectoryURL: directory,
            installationID: installationID(201)
        )

        #expect(RunLedger.inspect(configuration).status == .unsafeStorage)
        guard case .unsafeStorage = ledgerError({ _ = try RunLedger(configuration: configuration) }) else {
            Issue.record("Expected insecure directory rejection")
            return
        }
        #expect(permissions(directory) == 0o755)
        #expect(!FileManager.default.fileExists(atPath: configuration.databaseURL.path))
    }

    @Test("An orphan sidecar symlink is not mistaken for a missing ledger")
    func orphanSidecarSymlinkIsRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = root.appendingPathComponent("target")
        let targetBytes = Data("leave me alone".utf8)
        try targetBytes.write(to: target)
        let configuration = RunLedgerConfiguration(
            ledgerDirectoryURL: directory,
            installationID: installationID(202)
        )
        let sidecar = URL(fileURLWithPath: configuration.databaseURL.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)

        #expect(RunLedger.inspect(configuration).status == .unsafeStorage)
        guard case .unsafeStorage = ledgerError({ _ = try RunLedger(configuration: configuration) }) else {
            Issue.record("Expected orphan sidecar symlink rejection")
            return
        }
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(!FileManager.default.fileExists(atPath: configuration.databaseURL.path))
    }

    @Test("A regular orphan sidecar is reported as corruption, not absence")
    func regularOrphanSidecarIsCorrupt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let configuration = RunLedgerConfiguration(
            ledgerDirectoryURL: directory,
            installationID: installationID(203)
        )
        let sidecar = URL(fileURLWithPath: configuration.databaseURL.path + "-shm")
        try Data("orphan".utf8).write(to: sidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)

        #expect(RunLedger.inspect(configuration).status == .corrupt)
        guard case .corrupt = ledgerError({ _ = try RunLedger(configuration: configuration) }) else {
            Issue.record("Expected orphan sidecar corruption")
            return
        }
        #expect(try Data(contentsOf: sidecar) == Data("orphan".utf8))
    }
}
