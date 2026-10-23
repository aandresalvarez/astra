import Foundation

public enum SecretReadOutcome: Equatable, Sendable {
    case value(String)
    case missing
    case unavailable
}

public protocol SecretStore {
    func read(key: String, entityID: String) -> SecretReadOutcome
    func load(key: String, entityID: String) -> String?
    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool
    @discardableResult
    func delete(key: String, entityID: String) -> Bool
    func deleteAll(entityID: String)
    func exists(key: String, entityID: String) -> Bool
}

public extension SecretStore {
    /// Optional-only stores retain their historical missing-value contract.
    /// Vault implementations must distinguish unreadable storage from absence.
    func read(key: String, entityID: String) -> SecretReadOutcome {
        load(key: key, entityID: entityID).map(SecretReadOutcome.value) ?? .missing
    }

    func loadAll(keys: [String], entityID: String) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = load(key: key, entityID: entityID) {
                result[key] = value
            }
        }
        return result
    }

    func saveAll(credentials: [String: String], entityID: String, label: String? = nil) {
        for (key, value) in credentials {
            save(key: key, value: value, entityID: entityID, label: label)
        }
    }
}

public protocol FileSystem {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL]
}

public extension FileSystem {
    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        isDirectory = false
        return fileExists(atPath: path)
    }

    func directoryExists(atPath path: String) -> Bool {
        var isDirectory = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory
    }
}
