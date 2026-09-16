import Foundation
import ASTRACore

final class MockSecretStore: SecretStore {
    private var storage: [String: [String: String]] = [:]

    /// Makes every write fail, for the paths that have to tell the difference
    /// between "refused before the Keychain" and "the Keychain would not take
    /// it" — a distinction that decides whether a value the user had is gone.
    var failsWrites = false

    func load(key: String, entityID: String) -> String? {
        storage[entityID]?[key]
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        guard !failsWrites else { return false }
        storage[entityID, default: [:]][key] = value
        return true
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] = nil
        return true
    }

    func deleteAll(entityID: String) {
        storage[entityID] = nil
    }

    func exists(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] != nil
    }
}
