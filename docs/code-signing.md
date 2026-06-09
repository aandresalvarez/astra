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

## Signing modes (`script/build_and_run.sh`)

| Channel | Identity | codesign flags | Use |
|--------|----------|----------------|-----|
| `dev` (default), no cert | ad-hoc (`--sign -`) | `--force --deep --entitlements` | Throwaway local builds; churns the Keychain on every rebuild |
| `dev`, with `ASTRA Local Dev` cert | self-signed | `--force --deep --entitlements` (no hardened runtime) | **Recommended for day-to-day dev** — stable Keychain, same runtime behavior as ad-hoc |
| `prod` / `beta`, with identity | Developer ID | `--force --deep --entitlements --timestamp --options runtime` | Distribution; notarizable |

All modes sign with `--entitlements script/ASTRA.entitlements` (apple-events only); the dev/prod difference is the identity plus `--timestamp --options runtime`.

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
