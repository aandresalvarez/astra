import Foundation

struct WorkspaceAppStudioLaunchRequest: Equatable {
    let initialPrompt: String?

    init(initialPrompt: String?) {
        self.initialPrompt = Self.normalizedPrompt(initialPrompt)
    }

    static func normalizedPrompt(_ prompt: String?) -> String? {
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `/app` is only a chat affordance for launching the real App Studio owner.
/// Generation, validation, and publishing stay inside `WorkspaceAppStudioSession`
/// plus the Publish callback owned by `ContentView`.
enum WorkspaceAppChatCommand {
    static func launchRequest(input: String) -> WorkspaceAppStudioLaunchRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower == "/app" || lower.hasPrefix("/app ") else { return nil }

        let promptStart = trimmed.index(trimmed.startIndex, offsetBy: 4)
        return WorkspaceAppStudioLaunchRequest(initialPrompt: String(trimmed[promptStart...]))
    }
}
