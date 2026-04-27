import Foundation
import ASTRACore

final class MockSecretStore: SecretStore {
    private var storage: [String: [String: String]] = [:]

    func load(key: String, entityID: String) -> String? {
        storage[entityID]?[key]
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
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
