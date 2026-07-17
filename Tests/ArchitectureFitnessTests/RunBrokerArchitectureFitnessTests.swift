import Foundation
import Testing

@Suite("RunBroker architecture boundaries")
struct RunBrokerArchitectureFitnessTests {
    @Test("broker is the sole application and verified-control composition root")
    func soleCompositionRoot() throws {
        let root = repositoryRoot()
        let forbiddenAppModules: Set<String> = [
            "RunBrokerService", "ASTRARunLedger", "RunBrokerKit",
        ]
        for file in swiftFiles(root.appendingPathComponent("Astra")) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let forbiddenImports = importedModules(in: text).intersection(forbiddenAppModules)
            #expect(
                forbiddenImports.isEmpty,
                "ASTRA app source imports broker authority modules: \(forbiddenImports.sorted())"
            )
        }

        let package = try text("Package.swift", root: root)
        let appTarget = try target(named: "ASTRA", in: package)
        for forbidden in forbiddenAppModules {
            #expect(!appTarget.contains("\"\(forbidden)\""))
        }
        let dependencyGraph = targetDependencyGraph(in: package)
        let reachable = transitiveDependencies(of: "ASTRA", in: dependencyGraph)
        #expect(
            reachable.isDisjoint(with: forbiddenAppModules),
            "ASTRA reaches broker authority through target dependencies: \(reachable.intersection(forbiddenAppModules).sorted())"
        )
        #expect(!package.contains("-module-alias"))

        let brokerMain = try text("Tools/AstraRunBrokerTool/main.swift", root: root)
        #expect(brokerMain.components(separatedBy: "RunLedger(configuration:").count - 1 == 1)
        #expect(brokerMain.contains("RunBrokerApplicationService("))
        #expect(brokerMain.contains("allowAuthenticatedImmediateTermination: true"))
        for forbidden in ["RunBrokerInstaller(", "RunBrokerLaunchAgentInstallation", "SwiftData"] {
            #expect(!brokerMain.contains(forbidden))
        }

        let coreText = try swiftFiles(root.appendingPathComponent("ASTRACore"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(!coreText.contains("ExternalOperationVerifiedEvidence"))
        #expect(!coreText.contains("ExternalOperationControlProvenanceAuthenticating"))
        let serviceText = try swiftFiles(root.appendingPathComponent("RunBrokerService"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(serviceText.contains("protocol RunBrokerExternalOperationProvenanceAuthenticating"))
        #expect(serviceText.contains("enum RunBrokerVerifiedExternalOperationControl"))
    }

    @Test("source-aware import scanner catches comments and access modifiers without matching prose")
    func sourceAwareImportScanner() {
        let bypasses = [
            "import/* comment */RunBrokerService",
            "@_implementationOnly import ASTRARunLedger",
            "@preconcurrency import RunBrokerService",
            "@_spiOnly import RunBrokerKit",
            "internal import RunBrokerKit",
            "package import/* multiline\ncomment */RunBrokerService",
        ]
        for source in bypasses {
            #expect(!importedModules(in: source).isDisjoint(with: [
                "RunBrokerService", "ASTRARunLedger", "RunBrokerKit",
            ]))
        }
        #expect(importedModules(in: "// import RunBrokerService").isEmpty)
        #expect(importedModules(in: "let prose = \"import ASTRARunLedger\"").isEmpty)

        let indirectPackage = """
        .target(name: "ASTRA", dependencies: ["Middle"]),
        .target(name: "Middle", dependencies: ["RunBrokerService"]),
        .target(name: "RunBrokerService", dependencies: [])
        """
        let graph = targetDependencyGraph(in: indirectPackage)
        #expect(transitiveDependencies(of: "ASTRA", in: graph).contains("RunBrokerService"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func swiftFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func target(named name: String, in package: String) throws -> String {
        var search = package.startIndex
        while let start = package.range(of: ".target(", range: search..<package.endIndex)?.lowerBound {
            var depth = 0
            var cursor = start
            var end: String.Index?
            while cursor < package.endIndex {
                switch package[cursor] {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { end = package.index(after: cursor) }
                default: break
                }
                if end != nil { break }
                cursor = package.index(after: cursor)
            }
            guard let end else { break }
            let block = String(package[start..<end])
            if block.contains("name: \"\(name)\"") { return block }
            search = end
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func targetDependencyGraph(in package: String) -> [String: Set<String>] {
        let targetPattern = #"\.(?:target|executableTarget|testTarget)\s*\("#
        guard let expression = try? NSRegularExpression(pattern: targetPattern) else { return [:] }
        let searchRange = NSRange(package.startIndex..<package.endIndex, in: package)
        let starts = expression.matches(in: package, range: searchRange).compactMap { match in
            Range(match.range, in: package)?.lowerBound
        }
        let blocks = starts.compactMap { balancedCall(startingAt: $0, in: package) }
        let names = Set(blocks.compactMap { targetName(in: $0) })
        return Dictionary(uniqueKeysWithValues: blocks.compactMap { block in
            guard let name = targetName(in: block) else { return nil }
            return (name, targetDependencies(in: block).intersection(names))
        })
    }

    private func balancedCall(startingAt start: String.Index, in source: String) -> String? {
        guard let opening = source[start...].firstIndex(of: "(") else { return nil }
        var depth = 0
        var cursor = opening
        var inString = false
        var escaped = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if inString {
                if character == "\"", !escaped { inString = false }
                escaped = character == "\\" && !escaped
            } else if character == "\"" {
                inString = true
                escaped = false
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(source[start...cursor])
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func targetName(in block: String) -> String? {
        firstCapture(#"\bname\s*:\s*\"([A-Za-z_][A-Za-z0-9_]*)\""#, in: block)
    }

    private func targetDependencies(in block: String) -> Set<String> {
        guard let marker = block.range(of: "dependencies:"),
              let opening = block[marker.upperBound...].firstIndex(of: "[") else { return [] }
        var depth = 0
        var cursor = opening
        var closing: String.Index?
        while cursor < block.endIndex {
            if block[cursor] == "[" { depth += 1 }
            if block[cursor] == "]" {
                depth -= 1
                if depth == 0 { closing = cursor; break }
            }
            cursor = block.index(after: cursor)
        }
        guard let closing else { return [] }
        let dependencyList = String(block[opening...closing])
        let pattern = #"\"([A-Za-z_][A-Za-z0-9_]*)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(dependencyList.startIndex..<dependencyList.endIndex, in: dependencyList)
        return Set(expression.matches(in: dependencyList, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: dependencyList) else { return nil }
            return String(dependencyList[range])
        })
    }

    private func transitiveDependencies(
        of root: String,
        in graph: [String: Set<String>]
    ) -> Set<String> {
        var visited: Set<String> = []
        var pending = Array(graph[root, default: []])
        while let next = pending.popLast() {
            guard visited.insert(next).inserted else { continue }
            pending.append(contentsOf: graph[next, default: []])
        }
        return visited
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private func importedModules(in source: String) -> Set<String> {
        let sanitized = sourceWithoutCommentsAndStrings(source)
        let pattern = #"(?m)^[\t ]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n)]*\))?|public|package|internal|fileprivate|private)[\t ]+)*import[\t \r\n]+(?:(?:class|struct|enum|protocol|typealias|func|var|let)[\t ]+)?([A-Za-z_][A-Za-z0-9_]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
        return Set(expression.matches(in: sanitized, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: sanitized) else { return nil }
            return String(sanitized[range])
        })
    }

    private func sourceWithoutCommentsAndStrings(_ source: String) -> String {
        enum State { case code, lineComment, blockComment(Int), string(escaped: Bool) }
        let characters = Array(source)
        var result = ""
        var index = 0
        var state = State.code
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"
            switch state {
            case .code:
                if character == "/", next == "/" {
                    result.append(" "); index += 2; state = .lineComment; continue
                }
                if character == "/", next == "*" {
                    result.append(" "); index += 2; state = .blockComment(1); continue
                }
                if character == "\"" {
                    result.append(" "); index += 1; state = .string(escaped: false); continue
                }
                result.append(character)
            case .lineComment:
                if character == "\n" { result.append("\n"); state = .code }
            case .blockComment(let depth):
                if character == "/", next == "*" {
                    index += 2; state = .blockComment(depth + 1); continue
                }
                if character == "*", next == "/" {
                    index += 2; state = depth == 1 ? .code : .blockComment(depth - 1); continue
                }
                if character == "\n" { result.append("\n") }
            case .string(let escaped):
                if character == "\n" { result.append("\n") }
                if character == "\"", !escaped { state = .code }
                else { state = .string(escaped: character == "\\" && !escaped) }
            }
            index += 1
        }
        return result
    }
}
