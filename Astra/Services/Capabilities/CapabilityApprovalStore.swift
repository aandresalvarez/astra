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
        var canonical = package
        canonical.sourceMetadata?.lastRefreshedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(canonical)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
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
