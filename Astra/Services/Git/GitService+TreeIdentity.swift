import Foundation

/// Immutable tree identities used by typed publication to prove that the
/// reviewed index and the resulting commit contain exactly the same content.
extension GitService {
    func getIndexTreeSHA(at repoPath: String) async -> String? {
        do {
            let output = try await runGit(at: repoPath, arguments: ["write-tree"])
            let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        } catch {
            AppLogger.error(
                "Failed to resolve Git index tree: \(error.localizedDescription)",
                category: "Git"
            )
            return nil
        }
    }

    func getCommitTreeSHA(_ commit: String, at repoPath: String) async -> String? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-parse", "--verify", "\(commit)^{tree}"]
            )
            let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        } catch {
            AppLogger.error(
                "Failed to resolve Git commit tree: \(error.localizedDescription)",
                category: "Git"
            )
            return nil
        }
    }

    func restoreIndexTreeSHA(_ treeSHA: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["read-tree", treeSHA])
    }

    func getWorkingTreeContentDigest(
        relativePath: String,
        at repoPath: String
    ) async -> String? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["hash-object", "--no-filters", "--", relativePath]
            )
            let digest = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return digest.isEmpty ? nil : digest
        } catch {
            AppLogger.error(
                "Failed to hash selected working-tree content: \(error.localizedDescription)",
                category: "Git"
            )
            return nil
        }
    }
}
