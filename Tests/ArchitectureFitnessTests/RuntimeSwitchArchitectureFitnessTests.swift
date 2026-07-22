import Foundation
import Testing

@Suite("Runtime switch architecture fitness")
struct RuntimeSwitchArchitectureFitnessTests {
    @Test("RunBroker client is authority-free and runtime backend injection is broker-internal")
    func clientAndBackendCapabilityBoundaries() throws {
        let root = try repositoryRoot()
        let packageText = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let targets = try SwiftPMTargetParser.parse(packageText)
        let client = try #require(targets.first { $0.name == "RunBrokerClient" })
        #expect(client.dependencies == ["AstraObjCSupport", "ASTRACore"])
        #expect(client.path == "RunBrokerKit")
        #expect(!client.dependencies.contains("ASTRARunLedger"))
        #expect(!client.dependencies.contains("RunBrokerPolicy"))
        #expect(!client.dependencies.contains("RunBrokerService"))

        let service = try String(
            contentsOf: root.appendingPathComponent(
                "RunBrokerService/RunBrokerRuntimeSwitchService.swift"
            ),
            encoding: .utf8
        )
        #expect(!service.contains("public protocol RunBrokerRuntimeSwitchBackend"))
        #expect(!service.contains("public struct RunBrokerCheckpointEvidence"))
        #expect(!service.contains("public final class RunBrokerRuntimeSwitchService"))

        let application = try String(
            contentsOf: root.appendingPathComponent(
                "RunBrokerService/RunBrokerApplicationService.swift"
            ),
            encoding: .utf8
        )
        #expect(!application.contains(
            "public init(\n        ledger: RunLedger,\n        orchestrator: RunBrokerOrchestrator,\n        vault: any RunBrokerCapabilityVaulting,\n        runtimeSwitchBackend:"
        ))

        let bootstrap = try String(
            contentsOf: root.appendingPathComponent(
                "RunBrokerKit/RunBrokerClientBootstrap.swift"
            ),
            encoding: .utf8
        )
        #expect(bootstrap.contains("public init(expectedUserID: UInt32 = getuid())"))
        #expect(!bootstrap.contains("public init(installationID:"))
        #expect(!bootstrap.contains("public init(expectedUserID: UInt32, testingHomeDirectoryURL:"))
        #expect(!bootstrap.contains("public func load(homeDirectoryURL:"))
        #expect(!bootstrap.contains("public func load(supportDirectoryURL:"))
        #expect(!bootstrap.contains("public func create"))
        #expect(!bootstrap.contains("public func write"))
    }

    @Test("Verified runtime-switch policy stays in the broker-only target")
    func policyTargetHasAnIsolatedDependencyTopology() throws {
        let root = try repositoryRoot()
        let packageText = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let targets = try SwiftPMTargetParser.parse(packageText)
        let policy = try #require(targets.first { $0.name == "RunBrokerPolicy" })

        #expect(policy.dependencies == ["ASTRACore"])
        #expect(policy.path == "RunBrokerPolicy")

        let allowedConsumers: Set<String> = [
            // The canonical ledger persists and replays the policy state and
            // performs its optimistic CAS; it does not mint attestations.
            "ASTRARunLedger",
            "ASTRARunLedgerTests",
            "RunBrokerPolicyTests",
            // Reserved broker service targets. Broker executables compose
            // through RunBrokerService; they never mint policy evidence.
            "RunBrokerService",
            "RunBrokerServiceTests"
        ]
        let forbiddenConsumers = targets
            .filter { $0.dependencies.contains("RunBrokerPolicy") }
            .map(\.name)
            .filter { !allowedConsumers.contains($0) }
            .sorted()

        #expect(
            forbiddenConsumers.isEmpty,
            "Only the broker service and dedicated policy/service tests may depend on RunBrokerPolicy: \(forbiddenConsumers)"
        )
        let executableConsumers = targets
            .filter { $0.kind == .executable && $0.dependencies.contains("RunBrokerPolicy") }
            .map(\.name)
            .sorted()
        #expect(
            executableConsumers.isEmpty,
            "Executable and tool targets must compose through RunBrokerService: \(executableConsumers)"
        )

        let tests = try #require(targets.first { $0.name == "RunBrokerPolicyTests" })
        #expect(tests.dependencies.contains("RunBrokerPolicy"))
        #expect(tests.path == "Tests/RunBrokerPolicyTests")

        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("RunBrokerPolicy/RuntimeSwitchPolicy.swift").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("RunBrokerPolicy/RuntimeSwitchTrustedAttestations.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ASTRACore/RuntimeSwitchPolicy.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ASTRACore/RuntimeSwitchTrustedAttestations.swift").path
        ))

        let allowedImportPrefixes = [
            "ASTRARunLedger/",
            "Tests/ASTRARunLedgerTests/",
            "RunBrokerService/",
            "Tests/RunBrokerPolicyTests/",
            "Tests/RunBrokerServiceTests/"
        ]
        let forbiddenImports = try swiftFiles(under: root).compactMap { file -> String? in
            let relative = relativePath(for: file, root: root)
            guard !allowedImportPrefixes.contains(where: relative.hasPrefix) else { return nil }
            let source = try String(contentsOf: file, encoding: .utf8)
            return RunBrokerPolicyImportScanner.importsPolicy(source) ? relative : nil
        }.sorted()
        #expect(
            forbiddenImports.isEmpty,
            "Only broker service and dedicated tests may import RunBrokerPolicy: \(forbiddenImports)"
        )
    }

    @Test("SwiftPM target parser safely ignores a short trailing remainder")
    func parserHandlesShortTrailingText() throws {
        let targets = try SwiftPMTargetParser.parse(#".target(name: "One", dependencies: [])"# + "\nx")
        #expect(targets.map(\.name) == ["One"])
    }

    @Test("Policy import scanner recognizes only actual authority-module imports")
    func importScannerRecognizesForbiddenImports() {
        #expect(RunBrokerPolicyImportScanner.importsPolicy("import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("@testable import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("@_implementationOnly import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("@_exported import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("public import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("package import RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("import\nRunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy("import /*\n*/ RunBrokerPolicy\n"))
        #expect(RunBrokerPolicyImportScanner.importsPolicy(
            "import struct RunBrokerPolicy.RuntimeSwitchPolicy\n"
        ))
        #expect(RunBrokerPolicyImportScanner.importsPolicy(
            "import\nstruct /* trusted source */\nRunBrokerPolicy.RuntimeSwitchPolicy\n"
        ))
        #expect(!RunBrokerPolicyImportScanner.importsPolicy("// import RunBrokerPolicy\n"))
        #expect(!RunBrokerPolicyImportScanner.importsPolicy("/* import RunBrokerPolicy */\n"))
        #expect(!RunBrokerPolicyImportScanner.importsPolicy("let value = \"import RunBrokerPolicy\"\n"))
        #expect(!RunBrokerPolicyImportScanner.importsPolicy("import ASTRACore\n"))
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw RuntimeSwitchArchitectureError.repositoryRootNotFound
            }
            candidate = parent
        }
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private enum SwiftPMTargetKind: Equatable {
    case regular
    case executable
    case test
}

private struct SwiftPMTargetDeclaration: Equatable {
    let name: String
    let kind: SwiftPMTargetKind
    let dependencies: Set<String>
    let path: String?
}

/// Small structural parser for the target declarations in Package.swift.
/// It balances delimiters and ignores delimiters inside string literals, so
/// this check is tied to dependency arrays rather than arbitrary source tokens.
private enum SwiftPMTargetParser {
    private static let targetIntroducers: [(text: String, kind: SwiftPMTargetKind)] = [
        (".target(", .regular),
        (".executableTarget(", .executable),
        (".testTarget(", .test)
    ]

    static func parse(_ source: String) throws -> [SwiftPMTargetDeclaration] {
        let scalars = Array(source.unicodeScalars)
        var declarations: [SwiftPMTargetDeclaration] = []
        var cursor = 0

        while cursor < scalars.count {
            guard let match = nextIntroducer(in: scalars, from: cursor) else { break }
            let openParenthesis = match.offset + match.length - 1
            let closeParenthesis = try matchingDelimiter(
                in: scalars,
                openingAt: openParenthesis,
                open: "(",
                close: ")"
            )
            let block = String(String.UnicodeScalarView(scalars[match.offset...closeParenthesis]))
            declarations.append(try declaration(from: block, kind: match.kind))
            cursor = closeParenthesis + 1
        }

        return declarations
    }

    private static func declaration(
        from block: String,
        kind: SwiftPMTargetKind
    ) throws -> SwiftPMTargetDeclaration {
        guard let name = firstCapture(#"\bname\s*:\s*\"([^\"]+)\""#, in: block) else {
            throw RuntimeSwitchArchitectureError.invalidTargetDeclaration
        }
        let path = firstCapture(#"\bpath\s*:\s*\"([^\"]+)\""#, in: block)
        let dependencies = try dependencyNames(in: block)
        return .init(name: name, kind: kind, dependencies: dependencies, path: path)
    }

    private static func dependencyNames(in block: String) throws -> Set<String> {
        guard let labelRange = block.range(of: "dependencies:") else { return [] }
        let suffix = block[labelRange.upperBound...]
        guard let bracket = suffix.firstIndex(of: "[") else {
            throw RuntimeSwitchArchitectureError.invalidTargetDeclaration
        }
        let scalars = Array(block.unicodeScalars)
        let openingOffset = block.unicodeScalars.distance(
            from: block.unicodeScalars.startIndex,
            to: bracket.samePosition(in: block.unicodeScalars)!
        )
        let closingOffset = try matchingDelimiter(
            in: scalars,
            openingAt: openingOffset,
            open: "[",
            close: "]"
        )
        let dependencyText = String(String.UnicodeScalarView(scalars[openingOffset...closingOffset]))
        let expression = try NSRegularExpression(pattern: #"\"([^\"]+)\""#)
        let range = NSRange(dependencyText.startIndex..., in: dependencyText)
        return Set(expression.matches(in: dependencyText, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: dependencyText) else { return nil }
            return String(dependencyText[capture])
        })
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private static func nextIntroducer(
        in scalars: [UnicodeScalar],
        from cursor: Int
    ) -> (offset: Int, length: Int, kind: SwiftPMTargetKind)? {
        var best: (offset: Int, length: Int, kind: SwiftPMTargetKind)?
        for introducer in targetIntroducers {
            let needle = Array(introducer.text.unicodeScalars)
            guard needle.count <= scalars.count else { continue }
            let lastStart = scalars.count - needle.count
            guard cursor <= lastStart else { continue }
            for offset in cursor...lastStart where scalars[offset..<(offset + needle.count)].elementsEqual(needle) {
                if best == nil || offset < best!.offset {
                    best = (offset, needle.count, introducer.kind)
                }
                break
            }
        }
        return best
    }

    private static func matchingDelimiter(
        in scalars: [UnicodeScalar],
        openingAt openingOffset: Int,
        open: UnicodeScalar,
        close: UnicodeScalar
    ) throws -> Int {
        var depth = 0
        var inString = false
        var escaped = false
        for offset in openingOffset..<scalars.count {
            let scalar = scalars[offset]
            if inString {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            if scalar == "\"" {
                inString = true
            } else if scalar == open {
                depth += 1
            } else if scalar == close {
                depth -= 1
                if depth == 0 { return offset }
            }
        }
        throw RuntimeSwitchArchitectureError.invalidTargetDeclaration
    }
}

private enum RunBrokerPolicyImportScanner {
    private enum Token: Equatable {
        case identifier(String)
        case boundary
    }

    private static let selectiveImportKinds: Set<String> = [
        "typealias", "struct", "class", "enum", "protocol", "let", "var", "func"
    ]

    static func importsPolicy(_ source: String) -> Bool {
        let tokens = tokenize(source)
        for index in tokens.indices where tokens[index] == .identifier("import") {
            var moduleIndex = tokens.index(after: index)
            guard moduleIndex < tokens.endIndex, tokens[moduleIndex] != .boundary else { continue }
            if case .identifier(let candidate) = tokens[moduleIndex], selectiveImportKinds.contains(candidate) {
                moduleIndex = tokens.index(after: moduleIndex)
            }
            guard moduleIndex < tokens.endIndex,
                  tokens[moduleIndex] == .identifier("RunBrokerPolicy") else { continue }
            return true
        }
        return false
    }

    /// Tokenizes only identifiers and statement boundaries while discarding
    /// nested comments and string literals. This prevents import-looking text
    /// in documentation or fixtures from weakening the module-boundary gate.
    private static func tokenize(_ source: String) -> [Token] {
        let scalars = Array(source.unicodeScalars)
        var tokens: [Token] = []
        var cursor = 0

        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == "/", cursor + 1 < scalars.count, scalars[cursor + 1] == "/" {
                cursor += 2
                while cursor < scalars.count, scalars[cursor] != "\n" { cursor += 1 }
                continue
            }
            if scalar == "/", cursor + 1 < scalars.count, scalars[cursor + 1] == "*" {
                cursor += 2
                var depth = 1
                while cursor < scalars.count, depth > 0 {
                    if cursor + 1 < scalars.count, scalars[cursor] == "/", scalars[cursor + 1] == "*" {
                        depth += 1
                        cursor += 2
                    } else if cursor + 1 < scalars.count, scalars[cursor] == "*", scalars[cursor + 1] == "/" {
                        depth -= 1
                        cursor += 2
                    } else {
                        cursor += 1
                    }
                }
                continue
            }
            if scalar == "\"" {
                cursor = skipString(in: scalars, openingAt: cursor)
                continue
            }
            if scalar == ";" {
                tokens.append(.boundary)
                cursor += 1
                continue
            }
            if isIdentifierHead(scalar) {
                let start = cursor
                cursor += 1
                while cursor < scalars.count, isIdentifierContinuation(scalars[cursor]) { cursor += 1 }
                tokens.append(.identifier(String(String.UnicodeScalarView(scalars[start..<cursor]))))
                continue
            }
            cursor += 1
        }
        return tokens
    }

    private static func skipString(in scalars: [UnicodeScalar], openingAt opening: Int) -> Int {
        let multiline = opening + 2 < scalars.count
            && scalars[opening + 1] == "\""
            && scalars[opening + 2] == "\""
        var cursor = opening + (multiline ? 3 : 1)
        var escaped = false
        while cursor < scalars.count {
            if multiline,
               cursor + 2 < scalars.count,
               scalars[cursor] == "\"",
               scalars[cursor + 1] == "\"",
               scalars[cursor + 2] == "\"" {
                return cursor + 3
            }
            if !multiline {
                if escaped {
                    escaped = false
                } else if scalars[cursor] == "\\" {
                    escaped = true
                } else if scalars[cursor] == "\"" {
                    return cursor + 1
                }
            }
            cursor += 1
        }
        return cursor
    }

    private static func isIdentifierHead(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isIdentifierContinuation(_ scalar: UnicodeScalar) -> Bool {
        isIdentifierHead(scalar) || ("0"..."9").contains(scalar)
    }
}

private enum RuntimeSwitchArchitectureError: Error {
    case repositoryRootNotFound
    case invalidTargetDeclaration
}
