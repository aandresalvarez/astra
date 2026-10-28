import Foundation
import ASTRACore

extension AgentProcessMonitor {
    /// File tools for which a provider keeps only the path as the call's input.
    private static let pathOnlyFileToolNames: Set<String> = [
        "edit", "multiedit", "multi_edit", "write", "create", "view", "read"
    ]

    /// What the repetition breaker compares: two events are "the same" only if
    /// this matches. Starting from the readable signature, which keeps just the
    /// start of each input, it adds what tells different work apart.
    ///
    /// - A tool call carries a fingerprint of its whole input, so parallel calls
    ///   that differ only after the first characters (long paths, near-identical
    ///   commands) stay different, while a call genuinely repeated, even under
    ///   fresh provider ids, stays the same.
    /// - Tool output is an observation, not another invocation. A single call
    ///   can stream identical chunks (pytest dots, download progress) under one
    ///   id. Ignore results here without resetting invocation repetition, so
    ///   genuinely repeated calls still trip the breaker between their results.
    static func breakerSignature(_ parsed: ParsedEvent) -> String? {
        switch parsed {
        case .toolUse(let name, let id, let input):
            return toolUseBreakerSignature(name: name, id: id, input: input)
        case .toolResult:
            return nil
        default:
            return repetitionSignature(parsed)
        }
    }

    private static func toolUseBreakerSignature(name: String, id: String, input: [String: Any]?) -> String {
        var providerInput = input
        providerInput?.removeValue(forKey: ToolInputFingerprint.key)
        let readable = "tool:\(name):\(inputSignature(providerInput))"
        if let supplied = input?[ToolInputFingerprint.key] as? String {
            return "\(readable):#\(supplied)"
        }
        // A provider that kept only a path and gave no fingerprint cannot show
        // that two edits differ, so the call id stands in for the content.
        if isPathOnlyFileToolInput(name: name, input: providerInput) {
            return "\(readable):call=\(id)"
        }
        return "\(readable):#\(ToolInputFingerprint.of(providerInput))"
    }

    /// A file tool whose whole input was reduced to one summary string.
    private static func isPathOnlyFileToolInput(name: String, input: [String: Any]?) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard pathOnlyFileToolNames.contains(normalized), let input, input.count == 1 else { return false }
        return input["summary"] is String
    }
}
