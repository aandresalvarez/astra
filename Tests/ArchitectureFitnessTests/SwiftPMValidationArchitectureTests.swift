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

    @Test("CI compiles the root package once without dropping a lane")
    func ciCompilesRootPackageOnceWithoutDroppingLanes() throws {
        let root = try repositoryRoot()
        let ciWorkflow = try fileText(".github/workflows/ci.yml", root: root)
        let prePush = try fileText("script/prepush.sh", root: root)

        // The focused job may skip the pre-push root lanes only while the test
        // shards run the whole suite and the strict one-worker step.
        #expect(ciWorkflow.contains(#"ASTRA_PREPUSH_SKIP_ROOT_TESTS: "1""#))
        #expect(ciWorkflow.contains("script/swift_test.sh --no-parallel --skip-build $shard_arguments\n"))
        #expect(ciWorkflow.contains(#"LIBDISPATCH_COOPERATIVE_POOL_STRICT: "1""#))
        // The switch works only inside GitHub Actions, never for the local
        // hook, and the release gate keeps its root lanes even if it is set.
        #expect(prePush.contains(#"if [[ "${GITHUB_ACTIONS:-}" == "true" && "${ASTRA_PREPUSH_SKIP_ROOT_TESTS:-0}" == "1" \"#))
        #expect(prePush.contains(#"  && "${ASTRA_RELEASE_GATE:-0}" != "1" ]]; then"#))
        #expect(prePush.components(separatedBy: "ASTRA_PREPUSH_SKIP_ROOT_TESTS:-").count == 2)
        // Every run saves its build, so the shards and the next push reuse it.
        #expect(ciWorkflow.contains("if: steps.restore.outputs.cache-hit != 'true'\n        uses: actions/cache/save@v5"))
        #expect(ciWorkflow.contains("python3 script/ci_source_mtimes.py sync .build/ci-source-mtimes.json"))
    }

    @Test("CI test shards cover the whole suite behind one required check")
    func ciTestShardsCoverTheWholeSuite() throws {
        let root = try repositoryRoot()
        let ciWorkflow = try fileText(".github/workflows/ci.yml", root: root)
        let shardScript = try fileText("script/ci_test_shards.py", root: root)
        let plan = try #require(
            JSONSerialization.jsonObject(
                with: Data(try fileText("script/ci_test_shards.json", root: root).utf8)
            ) as? [String: Any]
        )
        let listedShards = try #require(plan["shards"] as? [[String]])
        let shardCount = listedShards.count + 1
        let shardNumbers = (1...shardCount).map(String.init).joined(separator: ", ")

        // One job per shard of the plan, each with arguments from the script.
        #expect(ciWorkflow.contains("        shard: [\(shardNumbers)]\n"))
        #expect(ciWorkflow.contains("name: Swift tests (shard ${{ matrix.shard }} of \(shardCount))\n"))
        #expect(ciWorkflow.contains(#"shard_arguments="$(python3 script/ci_test_shards.py arguments "$SHARD")""#))
        // The last shard skips exactly what the others filter on, so a suite
        // nobody listed still runs.
        #expect(shardScript.contains("return ['--filter', '|'.join(shards[shard - 1])]"))
        #expect(shardScript.contains("return ['--skip', '|'.join(name for listed in shards for name in listed)]"))
        // The required check runs even when a job it needs failed or was
        // cancelled: GitHub counts a skipped required check as passed.
        #expect(ciWorkflow.contains(
            "name: Full Swift test suite\n"
        ))
        #expect(ciWorkflow.contains(
            "    needs: [build-app-and-tests, swift-test-shards]\n    if: always()\n"
        ))
        #expect(ciWorkflow.contains(#"[[ "$BUILD_RESULT" == "success" ]] || exit 1"#))
        #expect(ciWorkflow.contains(
            #"[[ "$SHARDS_RESULT" == "skipped" && "$GITHUB_EVENT_NAME" == "push" && "$ALREADY_TESTED" == "true" ]]"#
        ))
        // No job of this workflow gets a token that can write: superseded
        // builds are left to GitHub's own cache eviction.
        #expect(!ciWorkflow.contains(": write"))
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
