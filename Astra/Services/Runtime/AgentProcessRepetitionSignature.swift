import Foundation
import ASTRACore

extension AgentProcessMonitor {
    /// File tools for which a provider keeps only the path as the call's input.
    private static let pathOnlyFileToolNames: Set<String> = [
        "edit", "multiedit", "multi_edit", "write", "create", "view", "read"
    ]

    /// The repetition signature, made specific to the call where it cannot tell
    /// two calls apart. Copilot's edit, view and create tools reach the monitor
    /// with a path as their whole input, so a parallel batch of different edits
    /// to one file, and the "File ... updated" result each one returns, would
    /// look identical and nine of them stopped a healthy run. Provider call ids
    /// stay ignored everywhere else, so a model repeating one command under
    /// fresh ids is still caught, and one call re-emitted under a single id
    /// still repeats.
    ///
    /// `toolNameForResult` names the tool a result belongs to, by call id.
    static func repetitionSignature(
        _ parsed: ParsedEvent,
        toolNameForResult: (String) -> String?
    ) -> String? {
        guard let signature = repetitionSignature(parsed) else { return nil }
        switch parsed {
        case .toolUse(let name, let id, let input):
            guard isPathOnlyFileToolInput(name: name, input: input) else { return signature }
            return "\(signature):call=\(id)"
        case .toolResult(let id, _, _):
            guard let name = toolNameForResult(id), isPathOnlyFileTool(name) else { return signature }
            return "\(signature):call=\(id)"
        default:
            return signature
        }
    }

    private static func isPathOnlyFileTool(_ name: String) -> Bool {
        pathOnlyFileToolNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// A file tool whose whole input was reduced to one summary string.
    private static func isPathOnlyFileToolInput(name: String, input: [String: Any]?) -> Bool {
        guard isPathOnlyFileTool(name), let input, input.count == 1 else { return false }
        return input["summary"] is String
    }
}
