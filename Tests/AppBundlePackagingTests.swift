import Foundation
import Testing

@Suite("App Bundle Packaging")
struct AppBundlePackagingTests {
    private let swiftMailTools = [
        "astra-browser": "AstraBrowserTool",
        "stanford-mail": "StanfordMailTool",
        "stanford-apple-mail": "StanfordAppleMailTool",
        "stanford-graph-mail": "StanfordGraphMailTool"
    ]

    @Test("build script stages SwiftPM resources inside Contents/Resources before signing")
    func swiftPMResourcesAreStagedInSignedResourcesDirectory() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let resourceCopy = #"cp -R "$BUILD_DIR/ASTRA_ASTRA.bundle" "$APP_RESOURCES/""#
        let toolCopy = #"cp "$BUILD_DIR/$tool_product" "$BUNDLED_TOOLS_DIR/$tool_product""#
        let invalidRootCopy = #"cp -R "$BUILD_DIR/ASTRA_ASTRA.bundle" "$APP_BUNDLE/""#
        let signingCommand = #"/usr/bin/codesign --force --deep"#

        #expect(script.contains(resourceCopy))
        #expect(script.contains(toolCopy))
        #expect(!script.contains(invalidRootCopy))
        #expect(try index(of: resourceCopy, in: script) < index(of: signingCommand, in: script))
        #expect(try index(of: toolCopy, in: script) < index(of: signingCommand, in: script))
    }

    @Test("Bundled agent tools are compiled Swift products, not resource scripts")
    func bundledAgentToolsAreCompiledSwiftProducts() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let resourceToolsURL = repoRoot.appendingPathComponent("Astra/Resources/Tools", isDirectory: true)

        for (command, target) in swiftMailTools {
            #expect(package.contains(".executable(name: \"\(command)\", targets: [\"\(target)\"])"))
            #expect(package.contains("name: \"\(target)\""))
            #expect(package.contains("dependencies: [\"MailToolSupport\"]"))
            #expect(package.contains("path: \"Tools/\(target)\""))
            #expect(script.contains("\"\(command)\""))

            let legacyPythonScript = resourceToolsURL.appendingPathComponent(command)
            #expect(!FileManager.default.fileExists(atPath: legacyPythonScript.path))

            let swiftEntrypoint = repoRoot
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent("main.swift")
            #expect(FileManager.default.fileExists(atPath: swiftEntrypoint.path))

            let source = try String(contentsOf: swiftEntrypoint, encoding: .utf8)
            #expect(!source.contains("#!/usr/bin/env python3"))
        }

        let resourceToolFiles = try FileManager.default.contentsOfDirectory(atPath: resourceToolsURL.path)
        #expect(resourceToolFiles == [".gitkeep"])
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        try #require(haystack.range(of: needle)?.lowerBound)
    }
}
