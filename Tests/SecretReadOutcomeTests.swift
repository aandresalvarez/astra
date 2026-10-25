import Foundation
import AstraObjCSupport
import Testing
import ASTRACore
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Credential reads distinguish missing from unavailable")
struct SecretReadOutcomeTests {
    @Test("An unlocked private test vault distinguishes a value from an absent item")
    func realReadOutcomes() throws {
        let path = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-read-result-\(UUID())"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: path, bootstrapService: bootstrap, services: ["read-result"]) }
        AstraSecureKeychainStore.$keychainPathOverride.withValue(path) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                #expect(AstraSecureKeychainStore.save(service: "read-result", account: "present", value: "fixture-value", label: nil))
                #expect(AstraSecureKeychainStore.read(service: "read-result", account: "present") == .value("fixture-value"))
                #expect(AstraSecureKeychainStore.read(service: "read-result", account: "absent") == .missing)
            }
        }
    }

    @Test("An unavailable vault is not a missing credential")
    func unavailableIsNotMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-unavailable-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("occupied")
        try Data("Not a folder".utf8).write(to: blocked)
        let bootstrap = "astra-unavailable-read-\(UUID())"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: blocked.appendingPathComponent("vault.keychain-db").path,
            bootstrapService: bootstrap, services: []) }
        AstraSecureKeychainStore.$keychainPathOverride.withValue(blocked.appendingPathComponent("vault.keychain-db").path) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                #expect(AstraSecureKeychainStore.read(service: "unavailable", account: "any") == .unavailable)
            }
        }
    }
    @Test("A missing bootstrap for an existing vault is unavailable, never a missing credential")
    func bootstrapAbsenceIsNotItemAbsence() throws {
        let source = AstraSecureKeychainTestSupport.tempKeychainPath()
        let copy = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-read-bootstrap-\(UUID())"
        let orphaned = "astra-read-orphaned-\(UUID())"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: source, bootstrapService: bootstrap, services: ["source"])
            AstraSecureKeychainTestSupport.cleanup(keychainPath: copy, bootstrapService: orphaned, services: [])
            _ = AstraSecureKeychain.takeLastFailureReport()
        }
        AstraSecureKeychainStore.$keychainPathOverride.withValue(source) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                #expect(AstraSecureKeychainStore.save(service: "source", account: "token", value: "preserved", label: nil))
            }
        }
        try FileManager.default.copyItem(atPath: source, toPath: copy)
        AstraSecureKeychainStore.$keychainPathOverride.withValue(copy) {
            AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(orphaned) {
                #expect(AstraSecureKeychainStore.read(service: "source", account: "token") == .unavailable)
            }
        }
        #expect(FileManager.default.fileExists(atPath: copy))
    }

}
