import Foundation
import Testing

@Suite("Release Update Script")
struct ReleaseUpdateScriptTests {
    @Test("the release DMG is built outside $RELEASE_DIR and only moved in after generate_appcast runs")
    func dmgStaysOutOfReleaseDirUntilAfterAppcastGeneration() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        // generate_appcast treats every archive it finds in its target
        // directory as an update for its own bundle version and errors out
        // ("Duplicate updates are not supported") if a .zip and a .dmg both
        // exist there for the same version -- confirmed live. The DMG must
        // be built somewhere generate_appcast's directory scan won't see it,
        // and only copied into $RELEASE_DIR afterward.
        let dmgBuildPath = #"DMG_BUILD_PATH="$DIST_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg""#
        let hdiutilCreate = #"hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -format UDZO -ov "$DMG_BUILD_PATH""#
        let generateAppcastCall = #""$GENERATE_APPCAST" "${GENERATE_APPCAST_ARGS[@]}" "$RELEASE_DIR""#
        let moveDmgIntoReleaseDir = #"mv "$DMG_BUILD_PATH" "$FINAL_DMG""#

        #expect(script.contains(dmgBuildPath))
        #expect(script.contains(hdiutilCreate))
        #expect(script.contains(generateAppcastCall))
        #expect(script.contains(moveDmgIntoReleaseDir))
        #expect(try index(of: hdiutilCreate, in: script) < index(of: generateAppcastCall, in: script))
        #expect(try index(of: generateAppcastCall, in: script) < index(of: moveDmgIntoReleaseDir, in: script))
    }

    @Test("the DMG container is signed with a real Developer ID identity when one is provided")
    func dmgIsSignedWhenIdentityProvided() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        let signCheck = #"if [[ -n "$SIGN_IDENTITY" ]]; then"#
        let signCommand = #"codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_BUILD_PATH""#
        let verifyCommand = #"codesign --verify --verbose=2 "$DMG_BUILD_PATH""#

        #expect(script.contains(signCheck))
        #expect(script.contains(signCommand))
        #expect(script.contains(verifyCommand))
        #expect(try index(of: signCheck, in: script) < index(of: signCommand, in: script))
    }

    @Test("the DMG is listed as a release asset")
    func dmgIsListedAsReleaseAsset() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)
        #expect(script.contains(#"echo "  $FINAL_DMG""#))
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
