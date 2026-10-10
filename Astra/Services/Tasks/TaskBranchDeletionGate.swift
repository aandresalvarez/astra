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
    private static func key(_ path: String) -> String {
        WorkspacePathPresentation.resolvedPath(GitCheckoutLayout.commonDirectory(for: path) ?? path)
    }

    /// Nil while cleanup is deleting a branch in this repository.
    static func beginCardOperation(at path: String) -> Token? {
        let repository = key(path)
        guard !deleting.contains(repository) else { return nil }
        let token = Token(repository: repository)
        cardOperations[repository, default: []].insert(token.id)
        return token
    }

    static func endCardOperation(_ token: Token) {
        cardOperations[token.repository]?.remove(token.id)
        if cardOperations[token.repository]?.isEmpty == true { cardOperations[token.repository] = nil }
    }

    /// False while a card operation is in flight here or another deletion is.
    static func beginDeletion(at path: String) -> Bool {
        let repository = key(path)
        guard cardOperations[repository]?.isEmpty != false else { return false }
        return deleting.insert(repository).inserted
    }

    static func endDeletion(at path: String) {
        deleting.remove(key(path))
    }
}
