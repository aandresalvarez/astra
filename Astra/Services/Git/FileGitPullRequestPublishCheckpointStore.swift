import Foundation
import ASTRAModels

/// Task-folder-backed recovery for the irreversible commit/push boundary. A
/// process restart after `gh pr create` fails can resume without creating a
/// second branch, commit, or push.
actor FileGitPullRequestPublishCheckpointStore: GitPullRequestPublishCheckpointStoring {
    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func checkpoint(for proposalID: String) -> GitPullRequestPublishCheckpoint? {
        guard let fileURL = checkpointURL(for: proposalID) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try TaskEventPayloadCodec.makeDecoder().decode(
                GitPullRequestPublishCheckpoint.self,
                from: data
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logFailure(operation: "read", proposalID: proposalID, error: error)
            return nil
        }
    }

    func save(_ checkpoint: GitPullRequestPublishCheckpoint) {
        guard let fileURL = checkpointURL(for: checkpoint.proposalID) else {
            logFailure(
                operation: "save",
                proposalID: checkpoint.proposalID,
                error: CheckpointStoreError.invalidProposalID
            )
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try TaskEventPayloadCodec.makeEncoder().encode(checkpoint)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logFailure(operation: "save", proposalID: checkpoint.proposalID, error: error)
        }
    }

    func removeCheckpoint(for proposalID: String) {
        guard let fileURL = checkpointURL(for: proposalID) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            logFailure(operation: "remove", proposalID: proposalID, error: error)
        }
    }

    private func checkpointURL(for proposalID: String) -> URL? {
        guard proposalID.count == 64, proposalID.allSatisfy(\.isHexDigit) else { return nil }
        return directoryURL.appendingPathComponent("\(proposalID.lowercased()).json", isDirectory: false)
    }

    private func logFailure(operation: String, proposalID: String, error: Error) {
        AppLogger.audit(.gitAuthoringFailed, category: "Git", fields: [
            "operation": "publish_checkpoint_\(operation)",
            "proposal_id": String(proposalID.prefix(64)),
            "error": String(error.localizedDescription.prefix(500))
        ], level: .error)
    }

    private enum CheckpointStoreError: LocalizedError {
        case invalidProposalID

        var errorDescription: String? {
            "The checkpoint proposal identifier is invalid."
        }
    }
}
