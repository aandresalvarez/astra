import CryptoKit
import Foundation
import ASTRACore

struct CapabilityApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    var packageID: String
    var packageVersion: String
    var status: CapabilityApprovalStatus
    var approvedBy: String
    var approvedAt: Date
    var reviewNotes: String
    var sourceDigest: String

    var id: String {
        "\(packageID):\(packageVersion):\(sourceDigest)"
    }
}

enum CapabilityApprovalDigest {
    static func digest(for package: PluginPackage) throws -> String {
        try digest(for: CapabilityPackageSource(
            package: package,
            manifestURL: package.sourceMetadata?.url,
            assetRootURL: assetRootURL(for: package)
        ))
    }

    static func digest(for source: CapabilityPackageSource) throws -> String {
        var canonicalSource = source
        canonicalSource.package.sourceMetadata?.lastRefreshedAt = nil
        canonicalSource.package.sourceMetadata?.url = nil
        let canonical = canonicalSource.package
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        var hasher = SHA256()
        hasher.update(data: data)
        if let assetDigestData = try iconAssetDigestData(for: source) {
            hasher.update(data: Data("\nicon-asset\n".utf8))
            hasher.update(data: assetDigestData)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func assetRootURL(for package: PluginPackage) -> URL? {
        guard package.iconDescriptor.kind == .asset else { return nil }
        guard let url = package.sourceMetadata?.url else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func iconAssetDigestData(for source: CapabilityPackageSource) throws -> Data? {
        guard let relativePath = source.declaredIconAssetPath,
              let rootURL = source.assetRootURL else {
            return nil
        }
        let assetURL = try CapabilityIconAssetPolicy.validatedAssetURL(
            relativePath: relativePath,
            rootURL: rootURL
        )
        let digest = try CapabilityIconAssetPolicy.sha256Hex(for: assetURL)
        return Data("\(relativePath):\(digest)".utf8)
    }
}

struct CapabilityApprovalStore {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL = Self.approvalsDirectory(), fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func approvalsDirectory(for channel: AppChannel = .current) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(channel.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("CapabilityApprovals", isDirectory: true)
    }

    func records() -> [CapabilityApprovalRecord] {
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: directory)
        guard let files = try? hostFileAccess.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            intent: accessIntent
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? hostFileAccess.readData(at: url, intent: accessIntent) else { return nil }
                return try? decoder.decode(CapabilityApprovalRecord.self, from: data)
            }
            .sorted {
                if $0.packageID != $1.packageID { return $0.packageID < $1.packageID }
                if $0.packageVersion != $1.packageVersion { return $0.packageVersion < $1.packageVersion }
                return $0.approvedAt < $1.approvedAt
            }
    }

    func record(for package: PluginPackage) -> CapabilityApprovalRecord? {
        guard let digest = try? CapabilityApprovalDigest.digest(for: package) else { return nil }
        return records().last {
            $0.packageID == package.id &&
            $0.packageVersion == package.version &&
            $0.sourceDigest == digest
        }
    }

    @discardableResult
    func save(
        package: PluginPackage,
        status: CapabilityApprovalStatus,
        approvedBy: String,
        reviewNotes: String = "",
        approvedAt: Date = Date()
    ) throws -> CapabilityApprovalRecord {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = try CapabilityApprovalDigest.digest(for: package)
        let record = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: status,
            approvedBy: approvedBy,
            approvedAt: approvedAt,
            reviewNotes: reviewNotes,
            sourceDigest: digest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: recordURL(for: record), options: [.atomic])
        return record
    }

    func recordURL(for record: CapabilityApprovalRecord) -> URL {
        let digestPrefix = String(record.sourceDigest.prefix(16))
        let fileName = [
            CapabilityLibrary.safeFileName(for: record.packageID),
            CapabilityLibrary.safeFileName(for: record.packageVersion),
            digestPrefix
        ].joined(separator: "-")
        return directory.appendingPathComponent(fileName).appendingPathExtension("json")
    }
}
