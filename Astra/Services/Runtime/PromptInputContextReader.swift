import Foundation

enum PromptInputContextReader {
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
