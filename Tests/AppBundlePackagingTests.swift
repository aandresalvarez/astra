import Foundation
import Testing

@Suite("App Bundle Packaging")
struct AppBundlePackagingTests {
    private let swiftMailTools = [
        "astra-browser": "AstraBrowserTool",
        "astra-workspace": "AstraWorkspaceTool",
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

    @Test("build script can provision managed Google OAuth client in Info.plist")
    func buildScriptCanProvisionManagedGoogleOAuthClient() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        #expect(script.contains("ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"))
        #expect(script.contains("<key>ASTRAGoogleOAuthClientID</key>"))
        #expect(script.contains("<string>$GOOGLE_MANAGED_OAUTH_CLIENT_ID</string>"))
    }

    @Test("Host app sandbox entitlement stays disabled while runtime Seatbelt wrapping is active")
    func hostAppSandboxEntitlementStaysDisabledWhileRuntimeSeatbeltWrappingIsActive() throws {
        let entitlementsURL = repoRoot.appendingPathComponent("script/ASTRA.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(plist["com.apple.security.app-sandbox"] == nil)

        let sandboxSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/ExecutionSandbox.swift"),
            encoding: .utf8
        )
        let securityPlan = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/security/host-app-sandbox-assessment.md"),
            encoding: .utf8
        )
        #expect(sandboxSource.contains("sandboxExecPath = \"/usr/bin/sandbox-exec\""))
        #expect(securityPlan.contains("Do not enable `com.apple.security.app-sandbox`"))
    }

    @Test("Bundled agent tools are compiled Swift products, not resource scripts")
    func bundledAgentToolsAreCompiledSwiftProducts() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let resourceToolsURL = repoRoot.appendingPathComponent("Astra/Resources/Tools", isDirectory: true)

        for (command, target) in swiftMailTools {
            #expect(package.contains(".executable(name: \"\(command)\", targets: [\"\(target)\"])"))
            #expect(package.contains("name: \"\(target)\""))
            if command == "astra-browser" {
                #expect(package.contains("dependencies: [\"ASTRACore\"]"))
            } else if command == "astra-workspace" {
                #expect(package.contains("dependencies: [\"WorkspaceToolSupport\"]"))
            } else {
                #expect(package.contains("dependencies: [\"MailToolSupport\"]"))
            }
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
