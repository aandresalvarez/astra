import Testing
import Foundation
@testable import ASTRA

private struct BaseEvent: Decodable { let type: String }
private struct ContentBlock: Decodable { let type: String; let text: String?; let name: String? }
private struct Message: Decodable { let content: [ContentBlock]? }
private struct AssistantEvent: Decodable { let type: String; let message: Message? }
private struct ModelUsageEntry: Decodable {
    let inputTokens: Int?; let outputTokens: Int?
    let cacheReadInputTokens: Int?; let cacheCreationInputTokens: Int?; let costUSD: Double?
}
private struct ResultEvent: Decodable {
    let type: String; let result: String?; let total_cost_usd: Double?
    let duration_ms: Int?; let num_turns: Int?; let is_error: Bool?
    let modelUsage: [String: ModelUsageEntry]?
}

private func findClaude() -> String? {
    let candidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.npm-global/bin/claude"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func runClaude(prompt: String) throws -> (lines: [String], exitCode: Int) {
    guard let claudePath = findClaude() else {
        throw CLIError.notFound
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claudePath)
    p.arguments = ["-p", prompt, "--model", "claude-sonnet-4-6", "--output-format", "stream-json", "--verbose"]
    p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()

    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
    return (lines, Int(p.terminationStatus))
}

private enum CLIError: Error { case notFound }

extension Tag {
    @Tag static var integration: Self
}

@Suite("Claude CLI Integration", .tags(.integration))
struct IntegrationTests {

    @Test("Simple prompt returns system + assistant + result events")
    func simplePrompt() throws {
        let (lines, exitCode) = try runClaude(prompt: "Reply with only the word 'pong'.")
        #expect(exitCode == 0)

        var types: Set<String> = []
        var resultText: String?
        var cost: Double?
        var tokens = 0

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let base = try? JSONDecoder().decode(BaseEvent.self, from: data) else { continue }
            types.insert(base.type)

            if base.type == "result", let r = try? JSONDecoder().decode(ResultEvent.self, from: data) {
                resultText = r.result
                cost = r.total_cost_usd
                if let mu = r.modelUsage {
                    for (_, e) in mu {
                        tokens += (e.inputTokens ?? 0) + (e.outputTokens ?? 0)
                            + (e.cacheReadInputTokens ?? 0) + (e.cacheCreationInputTokens ?? 0)
                    }
                }
            }
        }

        #expect(types.contains("system"))
        #expect(types.contains("assistant"))
        #expect(types.contains("result"))
        #expect(resultText != nil && !resultText!.isEmpty)
        #expect(cost != nil && cost! > 0)
        #expect(tokens > 0)
    }

    @Test("Prompt with tool use produces multiple turns")
    func toolUsePrompt() throws {
        let (lines, exitCode) = try runClaude(prompt: "What files are in /tmp? Just list 3.")
        #expect(exitCode == 0)

        var hasToolUse = false
        var hasToolResult = false
        var numTurns: Int?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let base = try? JSONDecoder().decode(BaseEvent.self, from: data) else { continue }

            if base.type == "assistant",
               let ae = try? JSONDecoder().decode(AssistantEvent.self, from: data),
               let content = ae.message?.content {
                for block in content where block.type == "tool_use" {
                    hasToolUse = true
                }
            }
            if base.type == "user" { hasToolResult = true }
            if base.type == "result",
               let r = try? JSONDecoder().decode(ResultEvent.self, from: data) {
                numTurns = r.num_turns
            }
        }

        #expect(hasToolUse)
        #expect(hasToolResult)
        #expect(numTurns != nil && numTurns! >= 2)
    }

    @Test("Spec extraction via Claude CLI")
    func specExtraction() throws {
        guard let claudePath = findClaude() else {
            throw CLIError.notFound
        }

        let prompt = """
        Given the following user request, extract a structured task specification for an AI coding agent.
        User request: "Add a dark mode toggle to the settings page"
        Working directory: "/tmp"
        Return ONLY valid JSON with: title, goal, inputs, constraints, acceptanceCriteria, estimatedComplexity.
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", prompt, "--model", "claude-sonnet-4-6"]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()

        #expect(p.terminationStatus == 0)

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Strip markdown fences if present
        var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let start = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: start)...])
            }
            if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let spec = try JSONDecoder().decode(TaskSpec.self, from: cleaned.data(using: .utf8)!)
        #expect(!spec.title.isEmpty)
        #expect(!spec.goal.isEmpty)
        #expect(["low", "medium", "high"].contains(spec.estimatedComplexity))
    }
}
