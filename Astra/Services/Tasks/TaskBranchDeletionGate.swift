import Foundation
import ASTRACore
import ASTRAPersistence

/// Branch cleanup and the Repository card's branch operations both run on the
/// main actor, so a check-and-set here can't interleave. Cleanup holds a
/// repository's gate from its last "is this branch checked out?" check until
/// the branch is deleted, and the card holds it for a checkout or worktree it
/// is starting. Neither starts while the other holds it, so the card can't
/// check out a branch cleanup is about to delete. Git commands run outside
/// ASTRA aren't covered.
@MainActor
enum TaskBranchDeletionGate {
    static let busyMessage =
        "ASTRA is removing an unused task branch in this repository. Try again in a moment."

    struct Token: Hashable {
        fileprivate let repository: String
        fileprivate let id = UUID()
    }

    private static var deleting: Set<String> = []
    private static var cardOperations: [String: Set<UUID>] = [:]

    /// The repository identity both sides agree on: its shared Git directory.
    /// A path is its own key only while it is confirmed not to be a Git
    /// checkout; a checkout whose shared directory can't be resolved has no
    /// key, so nothing starts on a key the other side might not share.
    private static func key(_ path: String) -> String? {
        if let common = GitCheckoutLayout.commonDirectory(for: path) { return WorkspacePathPresentation.resolvedPath(common) }
        let dotGit = (path as NSString).appendingPathComponent(".git")
        do {
            guard try GitService.attributesConfirmingAbsence(atPath: dotGit) == nil else { return nil }
        } catch {
            return nil
        }
        return WorkspacePathPresentation.resolvedPath(path)
    }

    /// Nil while cleanup is deleting a branch in this repository, or when
    /// the repository's identity can't be read.
    static func beginCardOperation(at path: String) -> Token? {
        guard let repository = key(path), !deleting.contains(repository) else { return nil }
        let token = Token(repository: repository)
        cardOperations[repository, default: []].insert(token.id)
        return token
    }

    static func endCardOperation(_ token: Token) {
        cardOperations[token.repository]?.remove(token.id)
        if cardOperations[token.repository]?.isEmpty == true { cardOperations[token.repository] = nil }
    }

    /// The deletion's hold on its repository, released by exactly the key it
    /// took: the repository's layout can change while it is held, as when
    /// its checkout moves, and a key recomputed then would leave this one
    /// held until the app restarts.
    struct DeletionToken {
        fileprivate let repository: String
    }

    /// Nil while a card operation is in flight here or another deletion is.
    static func beginDeletion(at path: String) -> DeletionToken? {
        guard let repository = key(path),
              cardOperations[repository]?.isEmpty != false, deleting.insert(repository).inserted else { return nil }
        return DeletionToken(repository: repository)
    }

    static func endDeletion(_ token: DeletionToken) {
        deleting.remove(token.repository)
    }
}
