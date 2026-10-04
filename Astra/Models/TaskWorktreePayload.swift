import Foundation

public struct TaskWorktreePayload: Codable, Equatable, Sendable {
    public let repositoryPath: String
    public let worktreePath: String
    public let branch: String

    public init(repositoryPath: String, worktreePath: String, branch: String) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
    }
}
