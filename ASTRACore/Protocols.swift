import Foundation

public protocol SecretStore {
    func load(key: String, entityID: String) -> String?
    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool
    @discardableResult
    func delete(key: String, entityID: String) -> Bool
    func deleteAll(entityID: String)
    func exists(key: String, entityID: String) -> Bool
}

public extension SecretStore {
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
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL]
}
