# Code signing

How ASTRA is code-signed, why it matters for the macOS Keychain, and how to set
up each signing mode. For the Sparkle update / release packaging flow, see
**Internal Test Releases** in the [README](../README.md).

## Why this matters: signing ↔ Keychain

ASTRA stores connector and skill secrets as generic passwords in the **legacy
file-based login Keychain** (`Astra/Services/Persistence/KeychainService.swift`,
`KeychainSecretStore.swift` — `kSecClassGenericPassword`, no
`kSecUseDataProtectionKeychain`, no access group). When an item is created, its
ACL is bound to the **Designated Requirement (DR)** of the app that created it.

- An **ad-hoc** signature (`codesign --sign -`) has a DR that is *just the cdhash*
  of the binary. The cdhash changes on **every rebuild**, so after any rebuild
  macOS sees a different app and the prior item's ACL no longer matches. Symptom:
  repeated "wants to use the Keychain" prompts, save/read failures, or the
  "Keychain 'login' cannot be found / Reset To Defaults" panel while configuring
  a credential.
- A **stable** signature (self-signed cert or Developer ID) has a DR anchored to
  the signing certificate, which is **constant across rebuilds**, so the Keychain
  ACL persists.

> `keychain-access-groups` does **not** fix this. Access groups govern the
> *data-protection* keychain (and need a Team ID); they are irrelevant to the
> file-based keychain ASTRA uses. The fix is a stable signing identity, not an
> entitlement. The dev/prod channel name is irrelevant — only the signing mode
> matters.

**Validated 2026-07-07.** `codesign -d -r-` on two independently rebuilt
`beta`-channel bundles, both signed with the same Developer ID identity:

```
# Build 1, CDHash=29ed75d5...
designated => identifier "com.coral.ASTRA.beta" and anchor apple generic and
  certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate
  leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate
  leaf[subject.OU] = "2BKAYYACN9"

# Build 2 (rebuilt ~68 min later), CDHash=0d47963b...
designated => identifier "com.coral.ASTRA.beta" and anchor apple generic and
  certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate
  leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate
  leaf[subject.OU] = "2BKAYYACN9"
```

The CDHash differs (genuinely different builds), but the DR string is
byte-identical — anchored to Team ID `2BKAYYACN9`, no cdhash term at all. For
contrast, the ad-hoc dev build's DR is `# designated => cdhash H"ce29b1d9..."`
— literally just the cdhash, which is exactly what changes every rebuild.
This confirms the mechanism directly: any Keychain ACL trusting this DR
survives a Developer ID rebuild. Not yet done: an end-to-end pass through the
real running app (write a secret in build 1, read it in build 2, confirm no
re-prompt) — the DR-level proof above is what actually determines that
outcome, so this is a lower-priority formality, not an open question.

## Signing modes (`script/build_and_run.sh`)

| Channel | Identity | codesign flags | Use |
|--------|----------|----------------|-----|
| `dev` (default), no cert | ad-hoc (`--sign -`) | `--force --deep --entitlements` | Throwaway local builds; churns the Keychain on every rebuild |
| `dev`, with `ASTRA Local Dev` cert | self-signed | `--force --deep --entitlements` (no hardened runtime) | **Recommended for day-to-day dev** — stable Keychain, same runtime behavior as ad-hoc |
| `prod` / `beta`, with identity | Developer ID | inside-out: tools + Sparkle.framework signed individually, then the app, with `--timestamp --options runtime` | Distribution; notarizable |

All modes sign with `--entitlements script/ASTRA.entitlements` (apple-events only) on the outer app bundle; the dev/prod difference is the identity plus `--timestamp --options runtime`.
Do not add `com.apple.security.app-sandbox` without also replacing or preserving
ASTRA's runtime Seatbelt launcher; see
`docs/security/host-app-sandbox-assessment.md`.

### Why the prod/beta path doesn't use `--deep`

Dev and ad-hoc builds sign with `codesign --deep`, which recursively re-signs
everything inside the bundle using the app's own identity and entitlements.
That's fine when nothing inside needs its own independent signature. It is
**not** fine for a distributable bundle: `--deep` would stamp ASTRA's
`com.apple.security.automation.apple-events` entitlement onto Sparkle's XPC
services and helper app (`Sparkle.framework/Versions/B/XPCServices/*.xpc`,
`.../Updater.app`, `.../Autoupdate`), invalidating the signatures Sparkle
ships with and that its own runtime checks expect.

So the `prod`/`beta` + identity path in `script/build_and_run.sh` signs
**inside-out** instead: each of the 7 bundled tools individually
(`sign_bundled_tools_for_notarization`), then Sparkle's nested
XPC services/helper app/`Autoupdate` followed by the framework itself
(`sign_sparkle_framework_for_notarization`), and only then the outer `.app`
— each with `--timestamp --options runtime`, no `--deep`. `verify_app_bundle`
checks each of these signatures independently so a broken inside-out sign is
caught locally instead of surfacing as an opaque `notarytool` rejection.

**Validated 2026-07-07** with a real Developer ID identity
(`Developer ID Application: Alvaro Andres Alvarez Peralta (2BKAYYACN9)`)
against a `beta`-channel release build: `xcrun notarytool submit --wait`
returned `status: Accepted` with `"issues": null` (zero warnings), `stapler
staple`/`validate` succeeded, and `spctl --assess --type execute` flipped from
`rejected, source=Unnotarized Developer ID` to
`accepted, source=Notarized Developer ID`. `codesign -d --entitlements -` on
`Sparkle.framework` and each bundled tool confirmed no entitlement leakage —
they carry no entitlements at all, only the outer app has
`com.apple.security.automation.apple-events`.

This resolved the two open questions from the original inside-out signing
change:

- The 7 tools staged under `Contents/Resources/ASTRA_ASTRA.bundle/Tools/`
  (rather than `Contents/MacOS/`) **do** pass notarization as-is — the notary
  ticket explicitly lists all 7 as accepted. No relocation needed.
- Sparkle's `Autoupdate`/XPC services signed cleanly this way (`codesign
  --verify` and the notary ticket both confirm valid signatures on each). Not
  yet confirmed: that a re-signed `Autoupdate` actually *runs* an update
  end-to-end post-install — that's an app-install-level test, not a signing
  one, and is still open (see the adoption plan, Phase 3).

The dev build **auto-detects** a code-signing identity literally named
`ASTRA Local Dev` and signs with it; otherwise it falls back to ad-hoc. Hardened
runtime and `--timestamp` are intentionally applied **only** to non-dev channels:
they are needed for notarization but enable library validation (which would
scrutinize the bundled tools and the MLX helper) and require network, neither of
which is wanted for local debugging.

## Local development — self-signed cert (no Apple account)

One-time, in **Keychain Access → Certificate Assistant → Create a Certificate**:

- **Name:** `ASTRA Local Dev` (must match exactly — the build script greps for it)
- **Identity Type:** Self Signed Root
- **Certificate Type:** Code Signing
- *(optional)* check **"Let me override defaults"** and set validity to ~3650
  days so it does not expire in a year (expiry would churn the Keychain once).

Verify, then build:

```bash
security find-identity -v -p codesigning      # should list "ASTRA Local Dev"
./script/build_and_run.sh                      # dev channel auto-signs with it
```

First launch after switching from ad-hoc prompts once because existing items
carry the old DR. Click **Always Allow**, or clear the stale items and re-enter
the credential (`security delete-generic-password -s "astra-dev-<connectorUUID>"`,
or delete the `astra-dev-*` entries in Keychain Access). **Never** click *Reset To
Defaults* — it wipes the entire login Keychain.

A self-signed cert is **local only**: it is not trusted by Gatekeeper on other
Macs and **cannot be notarized**. Use Developer ID for anything you distribute.

## Production — Developer ID + notarization

Requires a paid Apple Developer Program membership (Individual or Organization).
The full adoption sequence (this signing setup plus CI, Sparkle transition
testing, and which newly-unlocked platform features are worth adopting) is
tracked in
[`docs/specs/2026-07-07-apple-developer-program-adoption-plan.md`](specs/2026-07-07-apple-developer-program-adoption-plan.md).

**One-time account/asset setup checklist** (Apple Developer Program portal —
manual, no code):

- [x] Enrolled in the Apple Developer Program.
- [x] Created a **Developer ID Application** certificate; Team ID `2BKAYYACN9`.
- [x] Exported the certificate's private key as a `.p12` (`Certificates.p12`,
      alongside the notary API key). Recommended, not yet confirmed: also
      copy the file + its passphrase into an actual password manager — a
      lone file on one Mac isn't a real backup if that disk dies.
- [x] Created an **App Store Connect API key** (`.p8` + Key ID + Issuer ID) for
      notarization — preferred over an app-specific password since it also
      works headless in CI.
- [x] Ran `xcrun notarytool store-credentials` locally under the profile name
      `astra-notary`.
- [x] Confirmed `security find-identity -v -p codesigning` lists
      `Developer ID Application: Alvaro Andres Alvarez Peralta (2BKAYYACN9)`.

1. **Enroll** at <https://developer.apple.com/programs/enroll> (2FA required).
2. **Create the cert** (Account Holder only): Xcode → Settings → Accounts →
   *Manage Certificates…* → **+** → **Developer ID Application**. Confirm with
   `security find-identity -v -p codesigning` → `Developer ID Application: <Name> (TEAMID)`.
3. **Store a notarization profile** (app-specific password from
   <https://appleid.apple.com> → Sign-In and Security):

   ```bash
   xcrun notarytool store-credentials "ASTRA-Notary" \
     --apple-id "you@appleid.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
   ```

4. **Release** (signs with hardened runtime + timestamp, notarizes, staples,
   generates the Sparkle appcast):

   ```bash
   ASTRA_RELEASE_MODE=developer-id \
   ASTRA_SIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)" \
   ASTRA_NOTARY_PROFILE="ASTRA-Notary" \
   ASTRA_VERSION="0.1.0" ASTRA_BUILD="1" \
   ASTRA_SPARKLE_PUBLIC_ED_KEY="<public key>" \
   ./script/release_update.sh
   ```

The same Developer ID cert can also be used for dev builds (`export
ASTRA_SIGN_IDENTITY="Developer ID Application: …"`) to get a stable Keychain.
`ASTRA_RELEASE_MODE=internal` (the default) stays ad-hoc and skips notarization.
