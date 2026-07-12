import Foundation
import ASTRACore

struct FeedbackManualExportReceipt: Equatable, Sendable {
    let url: URL
    let byteCount: Int64
    let sha256: String
    let fileCount: Int
}

enum FeedbackManualExportError: Error, Equatable {
    case invalidDestination
    case archiveToolUnavailable
    case archiveCreationFailed
    case archiveContentsMismatch
}

extension FeedbackManualExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "Choose a normal ZIP file outside ASTRA's private feedback storage."
        case .archiveToolUnavailable:
            "This Mac could not start the system ZIP tool."
        case .archiveCreationFailed:
            "ASTRA could not create the feedback ZIP. The reviewed package was not changed."
        case .archiveContentsMismatch:
            "The exported ZIP did not contain the exact reviewed feedback files."
        }
    }
}

/// Creates one deterministic, email-ready ZIP from an already validated
/// feedback package. This service does not read raw logs or rebuild evidence;
/// it only packages the exact bytes that passed the review boundary.
enum FeedbackManualExportService {
    static func suggestedFileName(reportID: UUID) -> String {
        "astra-feedback-\(reportID.uuidString.lowercased()).zip"
    }

    static func export(
        packageDirectory: URL,
        relativePaths: [String],
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> FeedbackManualExportReceipt {
        let source = packageDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL
        guard destination.pathExtension.lowercased() == "zip",
              !relativePaths.isEmpty,
              relativePaths == Array(Set(relativePaths)).sorted()
        else { throw FeedbackManualExportError.invalidDestination }

        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw FeedbackManualExportError.invalidDestination
        }
        let resolvedDestination = parent.resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
            .standardizedFileURL
        let sourcePath = source.path
        guard resolvedDestination.path != sourcePath,
              !resolvedDestination.path.hasPrefix(sourcePath + "/") else {
            throw FeedbackManualExportError.invalidDestination
        }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FeedbackManualExportError.invalidDestination
            }
        }

        let temporary = parent.appendingPathComponent(
            ".astra-feedback-export-\(UUID().uuidString.lowercased()).zip"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        try createArchive(
            packageDirectory: source,
            relativePaths: relativePaths,
            destinationURL: temporary
        )
        guard try archiveEntries(at: temporary) == relativePaths else {
            throw FeedbackManualExportError.archiveContentsMismatch
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
        return FeedbackManualExportReceipt(
            url: destination,
            byteCount: Int64(data.count),
            sha256: FeedbackCanonicalJSONV1.sha256Hex(data),
            fileCount: relativePaths.count
        )
    }

    private static func createArchive(
        packageDirectory: URL,
        relativePaths: [String],
        destinationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = packageDirectory
        process.arguments = ["-X", "-q", destinationURL.path] + relativePaths
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "TZ": "UTC",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw FeedbackManualExportError.archiveToolUnavailable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FeedbackManualExportError.archiveCreationFailed
        }
    }

    private static func archiveEntries(at archiveURL: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archiveURL.path]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "TZ": "UTC",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw FeedbackManualExportError.archiveToolUnavailable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FeedbackManualExportError.archiveCreationFailed
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .sorted()
    }
}
