import CryptoKit
import Foundation
import ASTRACore
import ASTRAPersistence

/// App-owned provenance for the worktrees this install created. Task events
/// can arrive through workspace import, so a worktree binding alone never
/// authorizes removing a checkout or deleting its branch: automatic cleanup
/// also needs the record written when ASTRA itself ran `git worktree add`.
struct TaskWorktreeOwnershipStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let repositoryPath: String
        let worktreePath: String
        let branch: String
        let baseCommit: String
        /// The incarnation this install created; absent on older records.
        let identity: String?

        init(repositoryPath: String, worktreePath: String, branch: String, baseCommit: String, identity: String? = nil) {
            self.repositoryPath = WorkspacePathPresentation.standardizedPath(repositoryPath)
            self.worktreePath = WorkspacePathPresentation.standardizedPath(worktreePath)
            self.branch = branch
            self.baseCommit = baseCommit
            self.identity = identity
        }

        init(_ discard: TaskWorktreeDiscard) {
            self.init(
                repositoryPath: discard.repositoryPath,
                worktreePath: discard.worktreePath,
                branch: discard.branch,
                baseCommit: discard.baseCommit,
                identity: discard.identity
            )
        }
    }

    let directory: URL

    init(directory: URL = AppChannelStoragePaths.applicationSupportDirectory()
        .appendingPathComponent("WorktreeOwnership", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
    }

    /// Records a worktree `git worktree add` just created. A new creation at
    /// the same path replaces any earlier record.
    func record(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = recordURL(forWorktree: record.worktreePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    enum OwnershipState { case owned, notOwned, unreadable }

    /// Whether this install created exactly this worktree, branch, and base.
    /// A missing, mismatched, or corrupt record is not owned, which waiting
    /// won't change; one that can't be read for the moment, as behind an
    /// ACL or an I/O error, is unknown, so a cleanup keeps its record.
    func ownershipState(_ discard: TaskWorktreeDiscard) -> OwnershipState {
        let expected = Record(discard)
        do {
            return try read(forWorktree: expected.worktreePath) == expected ? .owned : .notOwned
        } catch is DecodingError {
            return .notOwned
        } catch {
            return .unreadable
        }
    }

    /// True only when this install created exactly this worktree, branch, and
    /// base. A missing, unreadable, or mismatched record means not owned.
    func owns(_ discard: TaskWorktreeDiscard) -> Bool {
        ownershipState(discard) == .owned
    }

    /// Drops the record once its worktree is gone, so a later checkout at the
    /// same path can't inherit it.
    func forget(_ discard: TaskWorktreeDiscard) {
        guard owns(discard) else { return }
        try? FileManager.default.removeItem(at: recordURL(forWorktree: discard.worktreePath))
        try? FileManager.default.removeItem(at: removalMarkerURL(forWorktree: discard.worktreePath))
    }

    /// Marks that cleanup verified this worktree's identity and is removing
    /// it. Once it's gone, nothing ties the branch to it any more, so a
    /// resumed cleanup finishes the branch only after this mark; without it,
    /// a branch someone may have recreated at the same commit is kept.
    func markRemoving(_ discard: TaskWorktreeDiscard) throws {
        guard let identity = discard.identity else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try Data((identity + "\n").utf8).write(to: removalMarkerURL(forWorktree: discard.worktreePath), options: .atomic)
    }

    /// Takes the mark back when Git didn't remove the worktree after all.
    /// Only a mark confirmed missing is already clear; any other failure
    /// throws, since a mark left behind would vouch for a removal later.
    func clearRemoving(_ discard: TaskWorktreeDiscard) throws {
        do {
            try FileManager.default.removeItem(at: removalMarkerURL(forWorktree: discard.worktreePath))
        } catch where WorkspaceFileLayout.isMissingFile(error) {}
    }

    enum RemovalMark { case marked, notMarked, unreadable }

    /// Whether this cleanup marked the worktree's removal. A mark confirmed
    /// missing, or naming another identity, isn't this one's; one that can't
    /// be read for now is unknown, so cleanup retries rather than settling.
    func removalState(_ discard: TaskWorktreeDiscard) -> RemovalMark {
        guard let identity = discard.identity else { return .notMarked }
        do {
            let raw = try String(contentsOf: removalMarkerURL(forWorktree: discard.worktreePath), encoding: .utf8)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines) == identity ? .marked : .notMarked
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            return .notMarked
        } catch {
            return .unreadable
        }
    }

    func isRemoving(_ discard: TaskWorktreeDiscard) -> Bool {
        removalState(discard) == .marked
    }

    private func removalMarkerURL(forWorktree path: String) -> URL {
        recordURL(forWorktree: path).deletingPathExtension().appendingPathExtension("removing")
    }

    func recordURL(forWorktree path: String) -> URL {
        let key = WorkspacePathPresentation.standardizedPath(path)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private func read(forWorktree path: String) throws -> Record? {
        let url = recordURL(forWorktree: path)
        // A record that can't even be checked throws, never reads as absent.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            return nil
        }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            return nil
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
}
