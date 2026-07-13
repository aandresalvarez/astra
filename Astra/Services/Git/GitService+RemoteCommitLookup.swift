import Foundation

extension GitService {
    /// Resolves a branch directly from the configured remote. Unlike
    /// `rev-parse <remote>/<branch>`, `ls-remote` cannot return a stale local
    /// remote-tracking ref after another process or host updates GitHub.
    func lookupRemoteCommitSHA(
        remote: String,
        branch: String,
        at repoPath: String
    ) async -> GitRemoteCommitLookupResult {
        let fullRef = "refs/heads/\(branch)"
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["ls-remote", "--heads", remote, fullRef],
                timeout: Self.networkGitTimeout
            )
            for line in output.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2, String(fields[1]) == fullRef else { continue }
                let sha = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sha.isEmpty { return .found(sha) }
            }
            return .missing
        } catch {
            return .unavailable(String(error.localizedDescription.prefix(500)))
        }
    }
}
