import Foundation
import Testing

@Suite("ASTRAGitContracts Architecture")
struct ASTRAGitContractsArchitectureTests {
    @Test("Git contracts remain independent of app UI and data layers")
    func contractsRemainIndependent() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/ASTRAGitContracts")
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let forbiddenImports = ["AppKit", "SwiftData", "SwiftUI", "ASTRA", "ASTRAModels", "ASTRAPersistence"]
        let sources = try swiftSources(under: sourceRoot)

        #expect(manifest.contains("dependencies: []"))
        #expect(!sources.isEmpty)
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            let imports = Set(text.split(separator: "\n").compactMap { line -> String? in
                let components = line.split(whereSeparator: { $0.isWhitespace })
                guard components.count == 2, components[0] == "import" else { return nil }
                return String(components[1])
            })
            for module in forbiddenImports {
                #expect(!imports.contains(module), "\(source.lastPathComponent) imports \(module)")
            }
        }
    }

    private func swiftSources(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}
