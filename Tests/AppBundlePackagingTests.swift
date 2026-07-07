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
        let validation = #"if [[ -n "$GOOGLE_MANAGED_OAUTH_CLIENT_ID" ]] && ! validate_google_managed_oauth_client_id "$GOOGLE_MANAGED_OAUTH_CLIENT_ID"; then"#
        let plistWrite = #"<string>$GOOGLE_MANAGED_OAUTH_CLIENT_ID</string>"#

        #expect(script.contains("ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"))
        #expect(script.contains("validate_google_managed_oauth_client_id()"))
        #expect(script.contains("Invalid ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"))
        #expect(script.contains("<key>ASTRAGoogleOAuthClientID</key>"))
        #expect(script.contains(plistWrite))
        #expect(try index(of: validation, in: script) < index(of: plistWrite, in: script))
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

    @Test("developer-id builds sign nested tools and Sparkle helpers before the outer app, without --deep")
    func developerIdBuildsSignInsideOutWithoutDeepEntitlementSmear() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let signTools = #"sign_bundled_tools_for_notarization"#
        let signSparkle = #"sign_sparkle_framework_for_notarization"#
        let outerSign = #"/usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE""#

        #expect(script.contains(signTools))
        #expect(script.contains(signSparkle))
        #expect(script.contains(outerSign))
        #expect(try index(of: signTools, in: script) < index(of: outerSign, in: script))
        #expect(try index(of: signSparkle, in: script) < index(of: outerSign, in: script))

        // `--deep` on the distributed-channel branch would stamp this app's
        // own entitlements onto every nested Mach-O, including Sparkle's XPC
        // services and helper app, invalidating their own signatures.
        let deepDistributedSign = #"/usr/bin/codesign --force --deep --timestamp --options runtime"#
        #expect(!script.contains(deepDistributedSign))
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
