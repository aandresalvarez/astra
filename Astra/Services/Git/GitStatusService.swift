import Foundation
import ASTRAGitContracts

struct GitStatusService {
    typealias GitRunner = (_ repoPath: String, _ arguments: [String]) async throws -> String

    private let runGit: GitRunner

    init(runGit: @escaping GitRunner) {
        self.runGit = runGit
    }

    func getStatusFiles(at repoPath: String) async -> [GitStatusFile] {
        do {
            let output = try await runGit(repoPath, ["--no-optional-locks", "status", "--porcelain=v1", "-z"])
            return GitStatusParser.parsePorcelainZ(output)
        } catch {
            return []
        }
    }

    func getStagedDiff(at repoPath: String, limit: Int = 8 * 1024) async -> String {
        do {
            let output = try await runGit(repoPath, ["--no-optional-locks", "diff", "--cached"])
            return GitService.limitedContext(output, maxBytes: limit)
        } catch {
            return ""
        }
    }

    func getFileDiff(at repoPath: String, file: GitStatusFile, limit: Int = 48 * 1024) async -> GitFileDiff {
        if file.isUntracked && !file.isStaged {
            return await untrackedFileDiff(at: repoPath, file: file, limit: limit)
        }

        let args = file.isStaged
            ? ["--no-optional-locks", "diff", "--cached", "--"] + file.pathspecs
            : ["--no-optional-locks", "diff", "--"] + file.pathspecs
        do {
            let output = try await runGit(repoPath, args)
            let limited = GitService.limitedContext(output, maxBytes: limit)
            let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitFileDiff(
                id: file.id,
                file: file,
                kind: file.isStaged ? .staged : .unstaged,
                diff: limited,
                isTruncated: trimmed.hasSuffix("...[truncated]"),
                message: trimmed.isEmpty ? "No textual diff is available for this file." : nil
            )
        } catch {
            return GitFileDiff(
                id: file.id,
                file: file,
                kind: .unavailable,
                diff: "",
                isTruncated: false,
                message: error.localizedDescription
            )
        }
    }

    func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) {
        do {
            let unstagedOutput = try await runGit(repoPath, ["--no-optional-locks", "diff", "--numstat"])
            let stagedOutput = try await runGit(repoPath, ["--no-optional-locks", "diff", "--cached", "--numstat"])
            return Self.parseNumstat(unstaged: unstagedOutput, staged: stagedOutput)
        } catch {
            return (additions: 0, deletions: 0)
        }
    }

    static func parseNumstat(unstaged: String, staged: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        let allLines = unstaged.split(separator: "\n") + staged.split(separator: "\n")
        for line in allLines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }

            guard parts.count >= 2 else { continue }
            if let add = Int(parts[0]) {
                additions += add
            }
            if let del = Int(parts[1]) {
                deletions += del
            }
        }
        return (additions, deletions)
    }

    private func untrackedFileDiff(at repoPath: String, file: GitStatusFile, limit: Int) async -> GitFileDiff {
        let url = URL(fileURLWithPath: repoPath, isDirectory: true)
            .appendingPathComponent(file.relativePath)
            .standardizedFileURL
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return GitFileDiff(
                id: file.id,
                file: file,
                kind: .unavailable,
                diff: "",
                isTruncated: false,
                message: "The untracked file is no longer readable."
            )
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: max(1, limit))) ?? Data()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? data.count
        guard let text = String(data: data, encoding: .utf8) else {
            return GitFileDiff(
                id: file.id,
                file: file,
                kind: .untracked,
                diff: "",
                isTruncated: fileSize > data.count,
                message: "Binary or non-UTF-8 untracked file. Stage it to inspect the binary diff metadata."
            )
        }

        let prefixed = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+\($0)" }
            .joined(separator: "\n")
        let header = """
        diff --git a/\(file.relativePath) b/\(file.relativePath)
        new file mode 100644
        --- /dev/null
        +++ b/\(file.relativePath)
        @@
        """
        let diff = header + "\n" + prefixed
        let isTruncated = fileSize > data.count
        return GitFileDiff(
            id: file.id,
            file: file,
            kind: .untracked,
            diff: isTruncated ? diff + "\n...[truncated]" : diff,
            isTruncated: isTruncated,
            message: nil
        )
    }
}
