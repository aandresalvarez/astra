import Foundation
import Testing

@Suite("SwiftPM validation architecture")
struct SwiftPMValidationArchitectureTests {
    @Test("Git status parsing lives behind its standalone contract package")
    func gitStatusParsingLivesBehindContractPackage() throws {
        let root = try repositoryRoot()
        let package = try fileText("Package.swift", root: root)
        let contractPackage = try fileText("ASTRAGitContracts/Package.swift", root: root)

        #expect(package.contains(#".package(path: "ASTRAGitContracts")"#))
        #expect(package.contains(#".product(name: "ASTRAGitContracts", package: "ASTRAGitContracts")"#))
        #expect(contractPackage.contains(#"name: "ASTRAGitContracts""#))
        #expect(contractPackage.contains("dependencies: []"))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "ASTRAGitContracts/Sources/ASTRAGitContracts/GitStatusContracts.swift"
            ).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "ASTRAGitContracts/Tests/ASTRAGitContractsTests/GitStatusParserContractTests.swift"
            ).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Astra/Services/Git/GitStatusParser.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ASTRAGitContracts/GitStatusContracts.swift").path
        ))
    }

    @Test("Architecture fitness checks run in a standalone test package")
    func architectureFitnessChecksRunStandalone() throws {
        let root = try repositoryRoot()
        let package = try fileText("Package.swift", root: root)
        let standalonePackage = try fileText("Tests/ArchitectureFitnessTests/Package.swift", root: root)
        let testScript = try fileText("script/test_architecture.sh", root: root)
        let testSources = try fileText("Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift", root: root)
            + (try fileText("Tests/ArchitectureFitnessTests/TaskThreadArchitectureFitnessTests.swift", root: root))
            + (try fileText("Tests/ArchitectureFitnessTests/SwiftPMValidationArchitectureTests.swift", root: root))
        let codeowners = try fileText(".github/CODEOWNERS", root: root)
        let disallowedAppImport = "@testable import " + "ASTRA"
        let disallowedSwiftDataImport = "import " + "SwiftData"

        #expect(package.contains(#"name: "ArchitectureFitnessTests""#))
        #expect(package.contains(#"exclude: ["ArchitectureFitnessTests""#))
        #expect(standalonePackage.contains(#"name: "ASTRAArchitectureFitness""#))
        #expect(standalonePackage.contains(#"name: "ArchitectureFitnessTests""#))
        #expect(testScript.contains(#"cd "$ROOT_DIR""#))
        #expect(testScript.contains(#"--package-path "$ROOT_DIR/Tests/ArchitectureFitnessTests""#))
        #expect(!testSources.contains(disallowedAppImport))
        #expect(!testSources.contains(disallowedSwiftDataImport))
        #expect(codeowners.contains("Tests/ArchitectureFitnessTests/"))
        #expect(codeowners.contains("Tests/AppSemanticFitnessTests.swift"))
    }

    @Test("Release validation always includes the root release gates")
    func releaseValidationAlwaysIncludesRootGates() throws {
        let root = try repositoryRoot()
        let releaseWorkflow = try fileText(".github/workflows/release.yml", root: root)
        let validationPlan = try fileText("script/focused_validation_plan.sh", root: root)
        let prePush = try fileText("script/prepush.sh", root: root)

        #expect(releaseWorkflow.contains(#"ASTRA_RELEASE_GATE: "1""#))
        #expect(releaseWorkflow.contains("run: script/prepush.sh"))
        #expect(validationPlan.contains(#"${ASTRA_RELEASE_GATE:-0}" == "1""#))
        #expect(prePush.contains("ReleaseBuildNumberDerivationTests"))
        #expect(prePush.contains("ReleaseUpdateScriptTests"))
        #expect(prePush.contains("AppBundlePackagingTests"))
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw CocoaError(.fileNoSuchFile)
            }
            candidate = parent
        }
    }

    private func fileText(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
