import CryptoKit
import Foundation

struct WorkspaceAppPackageResourceBudget: Sendable, Equatable {
    var maxPackageBytes: Int
    var maxFileBytes: Int
    var maxScannedTextFileBytes: Int
    var maxJSONLRows: Int
    var maxJSONLLineBytes: Int

    static let `default` = WorkspaceAppPackageResourceBudget(
        maxPackageBytes: 32 * 1_024 * 1_024,
        maxFileBytes: 8 * 1_024 * 1_024,
        maxScannedTextFileBytes: 2 * 1_024 * 1_024,
        maxJSONLRows: 10_000,
        maxJSONLLineBytes: 256 * 1_024
    )
}

enum WorkspaceAppPackageResourceError: LocalizedError, Equatable {
    case fileTooLarge(path: String, actual: Int, maximum: Int)
    case packageTooLarge(actual: Int, maximum: Int)
    case lineTooLarge(path: String, maximum: Int)
    case tooManyRows(path: String, maximum: Int)
    case invalidUTF8(path: String)
    case nonRegularFile(path: String)

    var path: String? {
        switch self {
        case let .fileTooLarge(path, _, _),
             let .lineTooLarge(path, _),
             let .tooManyRows(path, _),
             let .invalidUTF8(path),
             let .nonRegularFile(path):
            path
        case .packageTooLarge:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(path, actual, maximum):
            "Package resource limit exceeded for \(path): file is \(actual) bytes; maximum is \(maximum) bytes."
        case let .packageTooLarge(actual, maximum):
            "Package resource limit exceeded: package is \(actual) bytes; maximum is \(maximum) bytes."
        case let .lineTooLarge(path, maximum):
            "Package resource limit exceeded for \(path): JSONL line exceeds \(maximum) bytes."
        case let .tooManyRows(path, maximum):
            "Package resource limit exceeded for \(path): JSONL export exceeds \(maximum) rows."
        case let .invalidUTF8(path):
            "Package resource limit exceeded for \(path): file is not valid UTF-8 text."
        case let .nonRegularFile(path):
            "Package resource limit exceeded for \(path): package resources must be regular files."
        }
    }
}

struct WorkspaceAppPackageResourceReader {
    var budget: WorkspaceAppPackageResourceBudget = .default

    func validatePackageFiles(
        packageURL: URL,
        paths: [String],
        isScannedTextPath: (String) -> Bool
    ) throws {
        var totalBytes = 0
        for path in paths {
            let relativePath = "/\(path)"
            let size = try regularFileSize(
                at: packageURL.appendingPathComponent(path),
                relativePath: relativePath
            )
            totalBytes += size
            if totalBytes > budget.maxPackageBytes {
                throw WorkspaceAppPackageResourceError.packageTooLarge(
                    actual: totalBytes,
                    maximum: budget.maxPackageBytes
                )
            }
            if size > budget.maxFileBytes {
                throw WorkspaceAppPackageResourceError.fileTooLarge(
                    path: relativePath,
                    actual: size,
                    maximum: budget.maxFileBytes
                )
            }
            if isScannedTextPath(path), size > budget.maxScannedTextFileBytes {
                throw WorkspaceAppPackageResourceError.fileTooLarge(
                    path: relativePath,
                    actual: size,
                    maximum: budget.maxScannedTextFileBytes
                )
            }
        }
    }

    func data(at url: URL, relativePath: String) throws -> Data {
        let size = try regularFileSize(at: url, relativePath: relativePath)
        guard size <= budget.maxFileBytes else {
            throw WorkspaceAppPackageResourceError.fileTooLarge(
                path: relativePath,
                actual: size,
                maximum: budget.maxFileBytes
            )
        }
        return try Data(contentsOf: url)
    }

    func scannedText(at url: URL, relativePath: String) throws -> String {
        let size = try regularFileSize(at: url, relativePath: relativePath)
        guard size <= budget.maxScannedTextFileBytes else {
            throw WorkspaceAppPackageResourceError.fileTooLarge(
                path: relativePath,
                actual: size,
                maximum: budget.maxScannedTextFileBytes
            )
        }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw WorkspaceAppPackageResourceError.invalidUTF8(path: relativePath)
        }
        return text
    }

    func digest(at url: URL, relativePath: String) throws -> String {
        let size = try regularFileSize(at: url, relativePath: relativePath)
        guard size <= budget.maxFileBytes else {
            throw WorkspaceAppPackageResourceError.fileTooLarge(
                path: relativePath,
                actual: size,
                maximum: budget.maxFileBytes
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func countJSONLines<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        relativePath: String
    ) throws -> Int {
        let decoder = JSONDecoder()
        var count = 0
        try readJSONLines(at: url, relativePath: relativePath) { line in
            _ = try decoder.decode(type, from: line)
            count += 1
        }
        return count
    }

    func decodeJSONLines<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        relativePath: String,
        handleRow: (Value) throws -> Void
    ) throws {
        let decoder = JSONDecoder()
        try readJSONLines(at: url, relativePath: relativePath) { line in
            try handleRow(decoder.decode(type, from: line))
        }
    }

    private func readJSONLines(
        at url: URL,
        relativePath: String,
        handleLine: (Data) throws -> Void
    ) throws {
        let size = try regularFileSize(at: url, relativePath: relativePath)
        guard size <= budget.maxFileBytes else {
            throw WorkspaceAppPackageResourceError.fileTooLarge(
                path: relativePath,
                actual: size,
                maximum: budget.maxFileBytes
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var pending = Data()
        var rowCount = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            try processCompleteLines(
                pending: &pending,
                rowCount: &rowCount,
                relativePath: relativePath,
                handleLine: handleLine
            )
            if pending.count > budget.maxJSONLLineBytes {
                throw WorkspaceAppPackageResourceError.lineTooLarge(
                    path: relativePath,
                    maximum: budget.maxJSONLLineBytes
                )
            }
        }
        try processPendingLine(
            pending,
            rowCount: &rowCount,
            relativePath: relativePath,
            handleLine: handleLine
        )
    }

    private func processCompleteLines(
        pending: inout Data,
        rowCount: inout Int,
        relativePath: String,
        handleLine: (Data) throws -> Void
    ) throws {
        let newline = Data([0x0A])
        while let range = pending.firstRange(of: newline) {
            let line = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            try processPendingLine(
                line,
                rowCount: &rowCount,
                relativePath: relativePath,
                handleLine: handleLine
            )
        }
    }

    private func processPendingLine(
        _ rawLine: Data,
        rowCount: inout Int,
        relativePath: String,
        handleLine: (Data) throws -> Void
    ) throws {
        let line = rawLine.trimmingTrailingCarriageReturn()
        guard !line.isEmpty else { return }
        guard line.count <= budget.maxJSONLLineBytes else {
            throw WorkspaceAppPackageResourceError.lineTooLarge(
                path: relativePath,
                maximum: budget.maxJSONLLineBytes
            )
        }
        rowCount += 1
        guard rowCount <= budget.maxJSONLRows else {
            throw WorkspaceAppPackageResourceError.tooManyRows(
                path: relativePath,
                maximum: budget.maxJSONLRows
            )
        }
        try handleLine(line)
    }

    private func regularFileSize(at url: URL, relativePath: String) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw WorkspaceAppPackageResourceError.nonRegularFile(path: relativePath)
        }
        return values.fileSize ?? 0
    }
}

private extension Data {
    func trimmingTrailingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return subdata(in: startIndex..<index(before: endIndex))
    }
}
