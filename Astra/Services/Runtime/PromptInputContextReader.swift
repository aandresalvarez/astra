import Foundation
import ASTRACore
import ASTRAModels

enum PromptInputContextReader {
    static func contextParts(for task: AgentTask) -> [String] {
        task.acceptedResourceScope.map { contextParts(for: $0) } ?? contextParts(for: task.inputs)
    }

    static func contextParts(for scope: TaskExecutionResourceScope) -> [String] {
        scope.promptInputs.map { input in
            switch input.kind {
            case .text: return "Context: \(input.value)"
            case .path:
                guard scope.isValid, scope.coversRead(to: input.value) else {
                    AppLogger.audit(.workerBlocked, category: "Worker",
                        fields: ["reason": "accepted_input_identity_changed"], level: .error)
                    return "Input access changed after acceptance. Submit a new turn to authorize this input."
                }
                return contextPart(for: input.value, hostFileAccess: HostFileAccessBroker())
            case .unavailablePath:
                return "Input unavailable when this request was accepted: \(input.value). Submit a new turn to include it."
            }
        }
    }

    static func contextParts(
        for inputs: [String],
        hostFileAccess: HostFileAccessBroker = HostFileAccessBroker()
    ) -> [String] {
        inputs.map { input in
            contextPart(for: input, hostFileAccess: hostFileAccess)
        }
    }

    private static func contextPart(
        for input: String,
        hostFileAccess: HostFileAccessBroker
    ) -> String {
        guard input.hasPrefix("/") || input.hasPrefix("~") else {
            return "Context: \(input)"
        }

        let path = (input as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if hostFileAccess.fileExists(at: url, isDirectory: &isDirectory, intent: .explicitUserSelection),
           isDirectory.boolValue {
            return "Folder: \(path)\nUse this folder as routine context when needed."
        }

        if let content = try? hostFileAccess.readString(
            at: url,
            encoding: .utf8,
            intent: .explicitUserSelection
        ) {
            let truncated = content.count > 5000 ? String(content.prefix(5000)) + "\n... (truncated)" : content
            return "File: \(input)\n```\n\(truncated)\n```"
        }

        return "Context: \(input)"
    }
}
