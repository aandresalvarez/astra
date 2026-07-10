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

    @Test("build launcher serializes process replacement immediately before opening the verified bundle")
    func launcherDoesNotCreateParallelAppInstances() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let build = #"swift build "${SWIFT_BUILD_ARGS[@]}""#
        let launch = #"/usr/bin/open "$APP_BUNDLE""#
        let preReplacementSequence = #"""
        stop_existing_app

        rm -rf "$APP_BUNDLE"
        """#
        let launchSequence = #"""
        open_app() {
          stop_existing_app
          /usr/bin/open "$APP_BUNDLE"
        }
        """#

        #expect(script.contains(preReplacementSequence))
        #expect(script.contains(#"pkill -x "$APP_NAME""#))
        #expect(script.contains(launch))
        #expect(script.contains(launchSequence))
        #expect(!script.contains(#"/usr/bin/open -n "$APP_BUNDLE""#))
        #expect(try index(of: build, in: script) < index(of: preReplacementSequence, in: script))
    }

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
        let outerSign = #"/usr/bin/codesign --force --timestamp --options runtime "${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE""#

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

    @Test("release script validates the quarantined Sparkle zip before building the human DMG")
    func releaseScriptValidatesQuarantinedZipBeforeHumanDmg() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        let shippedZip = #"ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP""#
        let firstLaunchCheck = #"verify_first_launch_experience "$FINAL_ZIP""#
        let humanDmg = #"FINAL_DMG="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg""#
        let quarantineExtraction = #"ditto -x -k "$zip_path" "$verify_dir""#
        let quarantineStamp = #"find "$extracted_app" -exec xattr -w com.apple.quarantine "$quarantine_value" {} +"#
        let gatekeeperAssessment = #"syspolicy_check distribution "$extracted_app" --verbose"#

        #expect(script.contains("verify_first_launch_experience()"))
        #expect(script.contains(quarantineExtraction))
        #expect(script.contains(quarantineStamp))
        #expect(script.contains(gatekeeperAssessment))
        #expect(try index(of: shippedZip, in: script) < index(of: firstLaunchCheck, in: script))
        #expect(try index(of: firstLaunchCheck, in: script) < index(of: humanDmg, in: script))
    }

    @Test("release script keeps the human DMG out of Sparkle appcast generation")
    func releaseScriptKeepsHumanDmgOutOfSparkleAppcastGeneration() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        let dmgOutsideReleaseDirectory = #"DMG_BUILD_PATH="$DIST_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg""#
        let createDmg = #"hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -format UDZO -ov "$DMG_BUILD_PATH" >/dev/null"#
        let generateAppcast = #""$GENERATE_APPCAST" "${GENERATE_APPCAST_ARGS[@]}" "$RELEASE_DIR""#
        let publishDmg = #"mv "$DMG_BUILD_PATH" "$FINAL_DMG""#

        #expect(script.contains(dmgOutsideReleaseDirectory))
        #expect(script.contains(createDmg))
        #expect(script.contains(generateAppcast))
        #expect(script.contains(publishDmg))
        #expect(try index(of: createDmg, in: script) < index(of: generateAppcast, in: script))
        #expect(try index(of: generateAppcast, in: script) < index(of: publishDmg, in: script))
    }

    @Test("release workflow publishes the human DMG with Sparkle release assets")
    func releaseWorkflowPublishesHumanDmgWithSparkleReleaseAssets() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        let stableHumanDmg = #"HUMAN_DMG="dist/release/ASTRA.dmg""#
        let versionedHumanDmg = #"VERSIONED_DMG="dist/release/ASTRA-${VERSION}.dmg""#
        let stableHumanDmgCopy = #"cp "$VERSIONED_DMG" "$HUMAN_DMG""#
        let humanDmgAsset = #""$HUMAN_DMG#Download this for first install""#
        let sparkleZipAsset = #""$SPARKLE_ZIP#Sparkle updater payload""#
        let releaseCreate = #"gh release create "$TAG" "${ASSETS[@]}""#

        #expect(workflow.contains(stableHumanDmg))
        #expect(workflow.contains(versionedHumanDmg))
        #expect(workflow.contains(stableHumanDmgCopy))
        #expect(workflow.contains(humanDmgAsset))
        #expect(workflow.contains(sparkleZipAsset))
        #expect(workflow.contains(releaseCreate))
        #expect(try index(of: stableHumanDmgCopy, in: workflow) < index(of: humanDmgAsset, in: workflow))
        #expect(try index(of: humanDmgAsset, in: workflow) < index(of: releaseCreate, in: workflow))
    }

    @Test("release workflow prepends human install guidance before generated notes")
    func releaseWorkflowPrependsHumanInstallGuidanceBeforeGeneratedNotes() throws {
        let workflow = try String(contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        let notes = #"RELEASE_DOWNLOAD_NOTES=$'## Download ASTRA\n\n'"#
        let firstInstall = #"For a first install, download **ASTRA.dmg**"#
        let zipWarning = #"Do not use \`ASTRA-${VERSION}.zip\` for a first install."#
        let notesFlag = #"--notes "$RELEASE_DOWNLOAD_NOTES""#
        let generatedNotesFlag = #"--generate-notes"#

        #expect(workflow.contains(notes))
        #expect(workflow.contains(firstInstall))
        #expect(workflow.contains(zipWarning))
        #expect(workflow.contains(notesFlag))
        #expect(workflow.contains(generatedNotesFlag))
        #expect(try index(of: notes, in: workflow) < index(of: notesFlag, in: workflow))
        #expect(try index(of: notesFlag, in: workflow) < index(of: generatedNotesFlag, in: workflow))
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
