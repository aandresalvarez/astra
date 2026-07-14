import Foundation

public struct GitStatusFile: Identifiable, Hashable, Sendable {
    public let relativePath: String
    public let originalPath: String?
    public let status: String
    public let isStaged: Bool

    public init(relativePath: String, status: String, isStaged: Bool, originalPath: String? = nil) {
        self.relativePath = relativePath
        self.originalPath = originalPath
        self.status = status
        self.isStaged = isStaged
    }

    public var id: String {
        [
            isStaged ? "staged" : "unstaged",
            status,
            originalPath ?? "",
            relativePath
        ].joined(separator: "|")
    }

    public var displayPath: String {
        guard let originalPath, !originalPath.isEmpty, originalPath != relativePath else {
            return relativePath
        }
        return "\(originalPath) -> \(relativePath)"
    }

    public var pathspecs: [String] {
        var paths: [String] = []
        if let originalPath, !originalPath.isEmpty {
            paths.append(originalPath)
        }
        paths.append(relativePath)
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    public var isUntracked: Bool { status == "?" }
    public var isDeleted: Bool { status == "D" }
    public var isRenamed: Bool { status == "R" }
    public var isCopied: Bool { status == "C" }
    public var isConflict: Bool {
        status == "U"
            || status.contains("U")
            || ["AA", "DD"].contains(status)
    }
}

public enum GitStatusParser {
    public static func parsePorcelain(_ output: String) -> [GitStatusFile] {
        var files: [GitStatusFile] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            guard line.count >= 3 else { continue }
            let xIndex = line.index(line.startIndex, offsetBy: 0)
            let yIndex = line.index(line.startIndex, offsetBy: 1)
            let x = String(line[xIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let y = String(line[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

            let fileStartIndex = line.index(line.startIndex, offsetBy: 3)
            let rawPath = String(line[fileStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rename = splitPorcelainRenamePath(rawPath, stagedStatus: x, unstagedStatus: y)
            let relativePath = rename.current

            if x == "?" && y == "?" {
                files.append(GitStatusFile(relativePath: relativePath, status: "?", isStaged: false))
            } else if isConflictStatus(index: x, worktree: y) {
                files.append(GitStatusFile(
                    relativePath: relativePath,
                    status: "\(x)\(y)",
                    isStaged: false,
                    originalPath: rename.original
                ))
            } else {
                if !x.isEmpty {
                    files.append(GitStatusFile(
                        relativePath: relativePath,
                        status: x,
                        isStaged: true,
                        originalPath: rename.original
                    ))
                }
                if !y.isEmpty {
                    files.append(GitStatusFile(
                        relativePath: relativePath,
                        status: y,
                        isStaged: false,
                        originalPath: rename.original
                    ))
                }
            }
        }
        return files
    }

    /// Parses `git status --porcelain=v1 -z`. The NUL-delimited form avoids
    /// quoting ambiguity and reports rename/copy entries as `XY newPath\0oldPath`.
    public static func parsePorcelainZ(_ output: String) -> [GitStatusFile] {
        var files: [GitStatusFile] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let x = String(record[record.startIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let yIndex = record.index(after: record.startIndex)
            let y = String(record[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let relativePath = String(record[pathStart...])
            let originalPath: String? = (x == "R" || x == "C" || y == "R" || y == "C")
                && index + 1 < records.count
                ? records[index + 1]
                : nil

            if x == "?" && y == "?" {
                files.append(GitStatusFile(relativePath: relativePath, status: "?", isStaged: false))
            } else if isConflictStatus(index: x, worktree: y) {
                files.append(GitStatusFile(
                    relativePath: relativePath,
                    status: "\(x)\(y)",
                    isStaged: false,
                    originalPath: originalPath
                ))
            } else {
                if !x.isEmpty {
                    files.append(GitStatusFile(
                        relativePath: relativePath,
                        status: x,
                        isStaged: true,
                        originalPath: originalPath
                    ))
                }
                if !y.isEmpty {
                    files.append(GitStatusFile(
                        relativePath: relativePath,
                        status: y,
                        isStaged: false,
                        originalPath: originalPath
                    ))
                }
            }

            if x == "R" || x == "C" || y == "R" || y == "C" {
                index += 1
            }
            index += 1
        }
        return files
    }

    private static func splitPorcelainRenamePath(
        _ rawPath: String,
        stagedStatus: String,
        unstagedStatus: String
    ) -> (current: String, original: String?) {
        guard stagedStatus == "R" || stagedStatus == "C" || unstagedStatus == "R" || unstagedStatus == "C",
              let range = rawPath.range(of: " -> ", options: .backwards) else {
            return (rawPath, nil)
        }
        return (String(rawPath[range.upperBound...]), String(rawPath[..<range.lowerBound]))
    }

    private static func isConflictStatus(index: String, worktree: String) -> Bool {
        let combined = "\(index)\(worktree)"
        return combined.contains("U")
            || ["AA", "DD"].contains(combined)
    }
}
