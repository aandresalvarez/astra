import Foundation
import ASTRACore

enum PromptInputContextReader {
    private static let previewCharacterLimit = 5_000
    private static let previewByteLimit = previewCharacterLimit * 4
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

        if let data = try? hostFileAccess.readData(
            at: url,
            maxBytes: previewByteLimit,
            keeping: .prefix,
            intent: .explicitUserSelection
        ), let content = utf8Preview(data) {
            let truncated = content.count > previewCharacterLimit || data.count == previewByteLimit
                ? String(content.prefix(previewCharacterLimit)) + "\n... (truncated)" : content
            return "File: \(input)\n```\n\(truncated)\n```"
        }

        return "Context: \(input)"
    }

    private static func utf8Preview(_ data: Data) -> String? {
        // Only repair a split code point at a bounded read's edge. A small
        // binary document must not become fake text by dropping invalid bytes.
        let trimLimit = data.count == previewByteLimit ? 3 : 0
        return (0...trimLimit).lazy.compactMap {
            String(data: data.dropLast($0), encoding: .utf8)
        }.first
    }
}
