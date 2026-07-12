import CoreData
import Foundation

/// Durable, non-SwiftData compatibility information written beside each store.
/// Startup reads this before constructing a writable ModelContainer so an older
/// binary never has to infer compatibility from SwiftData's lossy error wrapper.
public struct PersistentStoreCompatibilityMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let minimumReaderSchemaVersion: Int
    public let channel: String
    public let appVersion: String
    public let appBuild: String
    public let gitCommit: String
    public let bundlePath: String
    public let recordedAt: Date

    public init(
        schemaVersion: Int,
        minimumReaderSchemaVersion: Int,
        channel: String,
        appVersion: String,
        appBuild: String,
        gitCommit: String,
        bundlePath: String,
        recordedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.minimumReaderSchemaVersion = minimumReaderSchemaVersion
        self.channel = channel
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.gitCommit = gitCommit
        self.bundlePath = bundlePath
        self.recordedAt = recordedAt
    }
}

public enum PersistentStoreCompatibilityAssessment: Equatable, Sendable {
    case compatible(storeSchemaVersion: Int?)
    case requiresNewerReader(requiredSchemaVersion: Int)
    case unknown
}

public enum PersistentStoreCompatibilityService {
    public static func metadataURL(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + ".astra-compatibility.json")
    }

    public static func readMetadata(
        for storeURL: URL,
        fileManager: FileManager = .default
    ) -> PersistentStoreCompatibilityMetadata? {
        let url = metadataURL(for: storeURL)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistentStoreCompatibilityMetadata.self, from: data)
    }

    public static func writeMetadata(
        _ metadata: PersistentStoreCompatibilityMetadata,
        for storeURL: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: storeURL), options: .atomic)
    }

    public static func assess(
        storeURL: URL,
        latestSupportedSchemaVersion: Int,
        fileManager: FileManager = .default,
        persistentStoreMetadata: ([String: Any])? = nil
    ) -> PersistentStoreCompatibilityAssessment {
        if let metadata = readMetadata(for: storeURL, fileManager: fileManager) {
            if metadata.minimumReaderSchemaVersion > latestSupportedSchemaVersion {
                return .requiresNewerReader(requiredSchemaVersion: metadata.minimumReaderSchemaVersion)
            }
            return .compatible(storeSchemaVersion: metadata.schemaVersion)
        }

        // Older stores predate ASTRA's sidecar. Core Data exposes the versioned
        // schema identifier read-only, without attaching a writable store.
        let rawMetadata: [String: Any]
        if let persistentStoreMetadata {
            rawMetadata = persistentStoreMetadata
        } else {
            do {
                rawMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    type: .sqlite,
                    at: storeURL
                )
            } catch {
                return .unknown
            }
        }

        guard let storeVersion = schemaVersion(from: rawMetadata) else {
            return .unknown
        }
        if storeVersion > latestSupportedSchemaVersion {
            return .requiresNewerReader(requiredSchemaVersion: storeVersion)
        }
        return .compatible(storeSchemaVersion: storeVersion)
    }

    public static func schemaVersion(from persistentStoreMetadata: [String: Any]) -> Int? {
        let value = persistentStoreMetadata[NSStoreModelVersionIdentifiersKey]
        let identifiers: [String]
        if let strings = value as? [String] {
            identifiers = strings
        } else if let set = value as? Set<String> {
            identifiers = Array(set)
        } else if let string = value as? String {
            identifiers = [string]
        } else {
            return nil
        }

        return identifiers.compactMap { identifier in
            let major = identifier.split(separator: ".", maxSplits: 1).first
            return major.flatMap { Int($0) }
        }.max()
    }
}
