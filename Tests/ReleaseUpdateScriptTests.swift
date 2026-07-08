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

    @Test("the DMG container is signed with a real Developer ID identity when one is provided, using the same hardened identity resolution as app signing")
    func dmgIsSignedWhenIdentityProvided() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        // This repo already spent three PRs (#234-#236) root-causing "no
        // identity found" in CI to (a) codesign relying on the ambient
        // keychain search list instead of an explicit --keychain pointer,
        // and (b) stray whitespace in the raw ASTRA_SIGN_IDENTITY secret
        // defeating codesign's literal substring match. Both fixes have to
        // be reapplied for the DMG's own codesign call, which is a
        // separate invocation from build_and_run.sh's (already-hardened)
        // app-signing path.
        let signCheck = #"if [[ -n "$SIGN_IDENTITY" ]]; then"#
        let trimIdentity = #"DMG_SIGN_IDENTITY="${SIGN_IDENTITY#"${SIGN_IDENTITY%%[![:space:]]*}"}""#
        let keychainArgs = #"DMG_SIGN_KEYCHAIN_ARGS=(--keychain "$ASTRA_RELEASE_KEYCHAIN")"#
        let signCommand = #"codesign --force --timestamp "${DMG_SIGN_KEYCHAIN_ARGS[@]+"${DMG_SIGN_KEYCHAIN_ARGS[@]}"}" --sign "$DMG_SIGN_IDENTITY" "$DMG_BUILD_PATH""#
        let verifyCommand = #"codesign --verify --verbose=2 "$DMG_BUILD_PATH""#

        #expect(script.contains(signCheck))
        #expect(script.contains(trimIdentity))
        #expect(script.contains(keychainArgs))
        #expect(script.contains(signCommand))
        #expect(script.contains(verifyCommand))
        #expect(try index(of: signCheck, in: script) < index(of: signCommand, in: script))
    }

    @Test("the DMG is notarized and stapled, not just signed, when notarization isn't skipped")
    func dmgIsNotarizedAndStapled() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        // Apple's own DTS guidance for DMG distribution: sign the app, put
        // it in the disk image, sign the disk image, and notarize that
        // outermost container too -- the inner .app being separately
        // notarized+stapled isn't enough, since the DMG itself is the
        // first thing Gatekeeper evaluates when a user downloads and opens
        // it.
        let notarizeCall = #"xcrun notarytool submit "$DMG_BUILD_PATH" --keychain-profile "$ASTRA_NOTARY_PROFILE" --wait"#
        let stapleCall = #"xcrun stapler staple "$DMG_BUILD_PATH""#
        let validateCall = #"xcrun stapler validate "$DMG_BUILD_PATH""#
        let skipCheck = #"if [[ "$SKIP_NOTARIZATION" != "1" ]]; then"#

        #expect(script.contains(notarizeCall))
        #expect(script.contains(stapleCall))
        #expect(script.contains(validateCall))
        #expect(try index(of: notarizeCall, in: script) < index(of: stapleCall, in: script))

        // The notarize/staple block for the DMG must itself be gated on
        // SKIP_NOTARIZATION, not run unconditionally whenever a sign
        // identity exists (a skip_notarization=true dry run must never
        // attempt a real Apple notarization submission).
        let dmgSignBlockStart = try index(of: #"if [[ -n "$SIGN_IDENTITY" ]]; then"#, in: script)
        let notarizeCallIndex = try index(of: notarizeCall, in: script)
        let nestedSkipCheckRange = script.range(of: skipCheck, range: dmgSignBlockStart..<notarizeCallIndex)
        #expect(nestedSkipCheckRange != nil)
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
