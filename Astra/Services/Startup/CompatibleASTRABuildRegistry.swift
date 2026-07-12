import Foundation
import ASTRACore
import ASTRAPersistence

struct CompatibleASTRABuildRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String { bundlePath }
    let bundlePath: String
    let bundleIdentifier: String
    let channel: String
    let schemaVersion: Int
    let version: String
    let build: String
    let gitCommit: String
    let lastSuccessfulStoreOpenAt: Date
}

enum CompatibleASTRABuildRegistry {
    private struct Payload: Codable {
        var builds: [CompatibleASTRABuildRecord]
    }

    static var registryURL: URL {
        WorkspaceRecoveryService.storeGenerationDirectory
            .appendingPathComponent("compatible-builds.json")
    }

    static func registerCurrentBuild(
        appInfo: AppBuildInfo,
        bundle: Bundle = .main,
        registryURL: URL = registryURL,
        now: Date = Date()
    ) throws {
        guard let bundleIdentifier = bundle.bundleIdentifier else { return }
        let record = CompatibleASTRABuildRecord(
            bundlePath: bundle.bundleURL.standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier,
            channel: appInfo.channelRawValue,
            schemaVersion: appInfo.schemaVersion,
            version: appInfo.version,
            build: appInfo.build,
            gitCommit: appInfo.gitCommit,
            lastSuccessfulStoreOpenAt: now
        )
        var records = load(registryURL: registryURL)
        records.removeAll { $0.bundlePath == record.bundlePath }
        records.append(record)
        records.sort { $0.lastSuccessfulStoreOpenAt > $1.lastSuccessfulStoreOpenAt }
        let data = try JSONEncoder().encode(Payload(builds: Array(records.prefix(24))))
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: registryURL, options: .atomic)
    }

    static func compatibleBuild(
        requiredSchemaVersion: Int,
        channel: String,
        excludingBundlePath: String,
        registryURL: URL = registryURL,
        fileManager: FileManager = .default
    ) -> CompatibleASTRABuildRecord? {
        load(registryURL: registryURL)
            .filter {
                $0.channel == channel &&
                    $0.schemaVersion >= requiredSchemaVersion &&
                    $0.bundlePath != excludingBundlePath
            }
            .compactMap { validated($0, fileManager: fileManager) }
            .sorted {
                if $0.schemaVersion != $1.schemaVersion { return $0.schemaVersion < $1.schemaVersion }
                return $0.lastSuccessfulStoreOpenAt > $1.lastSuccessfulStoreOpenAt
            }
            .first
    }

    static func load(registryURL: URL = registryURL) -> [CompatibleASTRABuildRecord] {
        guard let data = try? Data(contentsOf: registryURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.builds
    }

    static func compatibleBuild(
        at bundleURL: URL,
        requiredSchemaVersion: Int,
        channel: String,
        fileManager: FileManager = .default
    ) -> CompatibleASTRABuildRecord? {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              let info = bundle.infoDictionary,
              let schemaVersion = (info["ASTRASchemaVersion"] as? NSNumber)?.intValue else {
            return nil
        }
        let record = CompatibleASTRABuildRecord(
            bundlePath: bundleURL.standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier,
            channel: info["ASTRAChannel"] as? String ?? "",
            schemaVersion: schemaVersion,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            gitCommit: info["ASTRAGitCommit"] as? String ?? "unknown",
            lastSuccessfulStoreOpenAt: .distantPast
        )
        guard record.channel == channel,
              record.schemaVersion >= requiredSchemaVersion else { return nil }
        return validated(record, fileManager: fileManager)
    }

    private static func validated(
        _ record: CompatibleASTRABuildRecord,
        fileManager: FileManager
    ) -> CompatibleASTRABuildRecord? {
        let lexicalURL = URL(fileURLWithPath: record.bundlePath).standardizedFileURL
        let resolvedURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedBundleIdentifier: String
        switch record.channel {
        case "dev": expectedBundleIdentifier = "com.coral.ASTRA.dev"
        case "beta": expectedBundleIdentifier = "com.coral.ASTRA.beta"
        case "prod": expectedBundleIdentifier = "com.coral.ASTRA"
        default: return nil
        }
        guard record.bundlePath.hasPrefix("/"),
              record.bundleIdentifier == expectedBundleIdentifier,
              lexicalURL.pathExtension == "app",
              lexicalURL.path == resolvedURL.path,
              fileManager.fileExists(atPath: lexicalURL.path),
              let bundle = Bundle(url: lexicalURL),
              bundle.bundleIdentifier == record.bundleIdentifier,
              let info = bundle.infoDictionary,
              (info["ASTRAChannel"] as? String) == record.channel,
              let schemaVersion = (info["ASTRASchemaVersion"] as? NSNumber)?.intValue,
              schemaVersion == record.schemaVersion,
              bundle.executableURL.map({ fileManager.isExecutableFile(atPath: $0.path) }) == true else {
            return nil
        }
        return record
    }
}
