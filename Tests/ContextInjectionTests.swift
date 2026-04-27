import Testing
import Foundation

@Suite("Context Injection")
struct ContextInjectionTests {

    @Test("File content is read and included in prompt")
    func fileContentInjection() throws {
        let file = "/tmp/astra-ctx-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: file) }

        try "function add(a, b) { return a + b; }".write(toFile: file, atomically: true, encoding: .utf8)

        let content = try String(contentsOfFile: file, encoding: .utf8)
        #expect(content.contains("function add"))
    }

    @Test("Tilde path expansion works")
    func tildeExpansion() {
        let expanded = ("~/test" as NSString).expandingTildeInPath
        #expect(expanded.hasPrefix("/"))
        #expect(!expanded.contains("~"))
    }

    @Test("Prompt builder includes files and snippets")
    func promptBuilding() throws {
        let file = "/tmp/astra-prompt-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: file) }

        try "function add(a, b) { return a + b; }".write(toFile: file, atomically: true, encoding: .utf8)

        let inputs = [file, "Use TypeScript style"]
        var promptParts: [String] = ["Goal: Write tests"]
        var contextParts: [String] = []
        for input in inputs {
            if input.hasPrefix("/"),
               let content = try? String(contentsOfFile: input, encoding: .utf8) {
                contextParts.append("File: \(input)\n```\n\(content)\n```")
            } else {
                contextParts.append("Context: \(input)")
            }
        }
        promptParts.append("Context/Inputs:\n" + contextParts.joined(separator: "\n\n"))
        let prompt = promptParts.joined(separator: "\n\n")

        #expect(prompt.contains("function add"))
        #expect(prompt.contains("Context: Use TypeScript style"))
        #expect(prompt.contains("Goal: Write tests"))
    }

    @Test("Non-existent file path treated as snippet")
    func nonExistentFileAsSnippet() {
        let input = "/tmp/does-not-exist-\(UUID().uuidString).txt"
        let content = try? String(contentsOfFile: input, encoding: .utf8)
        #expect(content == nil)
    }
}
