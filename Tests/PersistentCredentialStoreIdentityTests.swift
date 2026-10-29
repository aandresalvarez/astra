import Darwin
import Foundation
import Testing
@testable import ASTRAPersistence

@Suite("Persistent credential store identity")
struct PersistentCredentialStoreIdentityTests {
    @Test("Mount device reassignment preserves identity; volume and file replacements do not")
    func identitySurvivesDeviceReassignment() throws {
        let url = URL(fileURLWithPath: "/synthetic/default.store")
        let volume = UUID().uuidString
        var metadata = stat()
        metadata.st_mode = S_IFREG | 0o600
        metadata.st_ino = 42
        metadata.st_dev = 10
        metadata.st_birthtimespec = timespec(tv_sec: 1_700_000_000, tv_nsec: 123)
        let first = try #require(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: volume, metadata: metadata))
        metadata.st_dev = 20
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: volume, metadata: metadata) == first)
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: UUID().uuidString, metadata: metadata) != first)
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url.appendingPathExtension("other"), volumeUUID: volume, metadata: metadata) != first)
        metadata.st_ino += 1
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: volume, metadata: metadata) != first)
        metadata.st_ino -= 1
        metadata.st_birthtimespec.tv_nsec += 1
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: volume, metadata: metadata) != first)
    }

    @Test("An atomic replacement at the same path changes the durable identity")
    func actualReplacementChangesIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-identity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        try Data("synthetic first store".utf8).write(to: store)
        let first = try #require(PersistentStoreIdentity.credentialJournal(forStoreAt: store))
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: store) == first)
        try Data("synthetic replacement".utf8).write(to: store, options: .atomic)
        let second = try #require(PersistentStoreIdentity.credentialJournal(forStoreAt: store))
        #expect(first != second)
        try FileManager.default.removeItem(at: store)
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: store) == nil)
    }

    @Test("Missing persistent volume metadata cannot authorize a credential journal")
    func incompleteMetadataFailsClosed() {
        let url = URL(fileURLWithPath: "/synthetic/default.store")
        let metadata = stat()
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: nil, metadata: metadata) == nil)
        #expect(PersistentStoreIdentity.credentialJournal(forStoreAt: url, volumeUUID: "invalid", metadata: metadata) == nil)
    }
}
