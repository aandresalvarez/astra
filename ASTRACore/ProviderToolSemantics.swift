import Foundation

/// Canonical provider-tool semantics shared by event normalization, policy
/// enforcement, and permission brokerage. Provider-specific event names must
/// be classified here so those layers cannot disagree about the same action.
public enum ProviderToolSemantics {
    public static func normalizedName(_ tool: String) -> String {
        let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("shell(") || lower.hasPrefix("bash(") {
            return "bash"
        }
        switch lower {
        case "shell", "command_execution":
            return "bash"
        case "view":
            return "read"
        case "create", "apply_patch":
            return "write"
        case "multi_edit":
            return "multiedit"
        default:
            return lower
        }
    }

    public static func isShellTool(_ tool: String) -> Bool {
        normalizedName(tool) == "bash"
    }
}
