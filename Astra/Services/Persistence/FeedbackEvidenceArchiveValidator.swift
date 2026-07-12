import Foundation
import ASTRACore

enum FeedbackEvidenceArchiveValidator {
    private static let unzipURL = URL(fileURLWithPath: "/usr/bin/unzip")

    static func validate(
        archiveURL: URL,
        artifacts: [(artifact: FeedbackEvidenceArtifactV1, relativePath: String, data: Data)],
        fileManager: FileManager
    ) throws {
        if artifacts.isEmpty {
            let canonicalEmptyArchive = Data(
                [0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18)
            )
            guard try Data(contentsOf: archiveURL, options: [.mappedIfSafe]) == canonicalEmptyArchive else {
                throw FeedbackPackageValidationError.archiveContentsMismatch("inventory")
            }
            return
        }
        guard fileManager.isExecutableFile(atPath: unzipURL.path) else {
            throw FeedbackPackageValidationError.archiveToolUnavailable
        }
        let expectedPaths = artifacts.map(\.relativePath)
        let maximumListingBytes = expectedPaths.reduce(1_024) { partial, path in
            partial + path.utf8.count + 1
        }
        let listing = try runUnzip(
            arguments: ["-Z1", archiveURL.path],
            maximumOutputBytes: maximumListingBytes
        )
        guard let listingText = String(data: listing, encoding: .utf8) else {
            throw FeedbackPackageValidationError.archiveContentsMismatch("inventory")
        }
        var actualPaths = listingText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if actualPaths.last == "" { actualPaths.removeLast() }
        guard actualPaths.count == expectedPaths.count,
              Set(actualPaths).count == actualPaths.count,
              Set(actualPaths) == Set(expectedPaths)
        else {
            throw FeedbackPackageValidationError.archiveContentsMismatch("inventory")
        }

        for item in artifacts {
            let archivedData = try runUnzip(
                arguments: ["-p", archiveURL.path, item.relativePath],
                maximumOutputBytes: Int(item.artifact.byteCount)
            )
            guard archivedData == item.data,
                  archivedData.count == Int(item.artifact.byteCount),
                  FeedbackCanonicalJSONV1.sha256Hex(archivedData) == item.artifact.sha256
            else {
                throw FeedbackPackageValidationError.archiveContentsMismatch(item.relativePath)
            }
        }
    }

    private static func runUnzip(
        arguments: [String],
        maximumOutputBytes: Int
    ) throws -> Data {
        let process = Process()
        process.executableURL = unzipURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "UNZIP")
        environment.removeValue(forKey: "UNZIPOPT")
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        var data = Data()
        while true {
            let remaining = maximumOutputBytes + 1 - data.count
            if remaining <= 0 {
                process.terminate()
                process.waitUntilExit()
                throw FeedbackPackageValidationError.archiveContentsMismatch("bounded output")
            }
            let chunk = try output.fileHandleForReading.read(
                upToCount: min(64 * 1_024, remaining)
            ) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maximumOutputBytes {
                process.terminate()
                process.waitUntilExit()
                throw FeedbackPackageValidationError.archiveContentsMismatch("bounded output")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FeedbackPackageValidationError.archiveContentsMismatch("unreadable archive")
        }
        return data
    }
}
