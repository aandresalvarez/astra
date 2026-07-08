# Apple Developer Program Adoption Plan

**Date:** 2026-07-07
**Status:** Phases 0–3 validated live and landed (see below). Phase 4 CI scaffold exists; blocked on secrets, which must be added by a human (entering credentials is outside what an AI agent should do, regardless of authorization). Phase 5 platform capabilities remain deliberately parked per their own table.
**Context:** The team now has a paid Apple Developer Program membership. Until now ASTRA has shipped ad-hoc-signed internal builds (`ASTRA_RELEASE_MODE=internal`). This plan sequences everything the membership unlocks — Developer ID signing, notarization, a real Sparkle update channel, CI release automation, and the Team-ID-gated capabilities — and calls out the traps specific to this codebase.

**What already exists (do not rebuild):**
- `script/release_update.sh` has a `developer-id` mode with the full `notarytool submit --wait` → `stapler staple` → `spctl --assess` flow scaffolded (lines 37–44, 76–85).
- `script/build_and_run.sh` already signs prod/beta with `--options runtime --timestamp` when `ASTRA_SIGN_IDENTITY` is set (line 308), copies Sparkle.framework into `Contents/Frameworks`, and generates `Info.plist` (incl. `SUFeedURL`/`SUPublicEDKey`) at build time.
- Sparkle 2.9.1 is integrated (`Package.swift:18`, `Astra/Services/Settings/AppUpdateController.swift`) with EdDSA appcast signing and per-channel feeds; the internal ad-hoc channel already works.
- `docs/code-signing.md` documents the enrollment → cert → notary-profile runbook (lines 77–107).

The work is therefore: **(1)** one-time account/asset setup, **(2)** hardening the signing pipeline for notarization's stricter rules, **(3)** validating the two known signing-coupled bugs are fixed, **(4)** the ad-hoc → Developer ID transition for existing installs, **(5)** CI automation, **(6)** selectively adopting newly unlocked platform capabilities.

---

## Phase 0 — Account and asset setup (one-time, no code)

1. **Create a Developer ID Application certificate** in the Apple Developer portal (Account Holder role required — fine for a personal enrollment). Record the Team ID. Do **not** create a Developer ID Installer cert yet — distribution is a zip, not a `.pkg`.
2. **Export and back up the private key** (`.p12` with a strong passphrase) to a password manager. This key can only be created a limited number of times and losing it complicates CI setup later.
3. **Store notary credentials:** create an **App Store Connect API key** (preferred over app-specific password — it also works headless in CI later) and run
   `xcrun notarytool store-credentials astra-notary --key <key.p8> --key-id <id> --issuer <issuer>`.
   The profile name `astra-notary` becomes `ASTRA_NOTARY_PROFILE`.
4. **Verify identity resolution:** `security find-identity -v -p codesigning` shows `Developer ID Application: <name> (<TEAMID>)`. That exact string is `ASTRA_SIGN_IDENTITY`.

Deliverable: nothing in-repo; a short "assets checklist" appended to `docs/code-signing.md` (cert name, Team ID, notary profile name, where the `.p12` backup lives — **never** the secrets themselves).

## Phase 1 — First notarized build: harden the signing pipeline — ✅ DONE (2026-07-07)

Goal: `ASTRA_RELEASE_MODE=developer-id ./script/release_update.sh` produces a stapled, Gatekeeper-clean app. Two known frictions must be addressed first; both live in `script/build_and_run.sh`.

**Result:** validated live against a real `beta`-channel build signed with `Developer ID Application: Alvaro Andres Alvarez Peralta (2BKAYYACN9)`. `notarytool submit --wait` → `Accepted`, `"issues": null`. `stapler staple`/`validate` succeeded. `spctl --assess` went from `rejected, source=Unnotarized Developer ID` (pre-notarization) to `accepted, source=Notarized Developer ID`. Full details and the resolved 1a/1b questions are in `docs/code-signing.md` ("Why the prod/beta path doesn't use `--deep`"). The clean-machine download test (1c, via quarantine simulation) and Phase 3's live Sparkle transition-update test are both also done — see their respective sections below.

### 1a. Replace `--deep` with explicit inside-out signing (developer-id path)

`codesign --deep` is deprecated for distribution and has two concrete failure modes here:
- It stamps the **app's entitlements onto every nested binary**, which breaks Sparkle's `Autoupdate`/`Updater.app`/XPC helpers (they need their own entitlements, or Sparkle's own valid signature preserved).
- It signs nested items with default flags in ways notarization can reject.

Change the signing step (currently `build_and_run.sh:305–316`) so that when a real identity is set it signs inside-out:
1. Each of the 7 bundled tools (`astra-browser`, `astra-mcp-gateway`, `astra-host-control`, `astra-workspace`, `stanford-mail`, `stanford-apple-mail`, `stanford-graph-mail`) individually with `--options runtime --timestamp`, **no** app entitlements.
2. Sparkle.framework's nested helpers (`Autoupdate`, `Updater.app`, the two XPC services) with `--options runtime --timestamp --preserve-metadata=entitlements`, then the framework itself. (Alternative: leave Sparkle's shipped signature intact — it arrives validly signed and hardened from the Sparkle project — and only re-sign if `codesign --verify --strict` or notarization complains. Pick whichever passes; document the choice.)
3. The main app last, with `--options runtime --timestamp --entitlements script/ASTRA.entitlements`.

Keep the current `--deep` behavior for the dev/ad-hoc paths — no reason to churn the fast local loop. Note the dev path intentionally omits library validation (`docs/code-signing.md:48`); that stays.

### 1b. Resolve the Tools-under-Resources layout question — ✅ resolved: keep as-is

The 7 helper executables are staged into `Contents/Resources/ASTRA_ASTRA.bundle/Tools/`. Mach-O executables under `Resources/` are a classic notarization/Gatekeeper friction point, but the real submission's notarization ticket explicitly lists all 7 as accepted (`ticketContents` in the `notarytool log` output) with zero issues. No relocation to `Contents/MacOS/` needed; no code or test changes required here.

### 1c. Run the pipeline and validate

- `ASTRA_RELEASE_MODE=developer-id ASTRA_SIGN_IDENTITY=... ASTRA_NOTARY_PROFILE=astra-notary ./script/release_update.sh`
- Success criteria, in order: `codesign --verify --deep --strict --verbose=2` clean → notarytool `Accepted` → `stapler validate` clean → `spctl --assess --type execute` says `accepted, source=Notarized Developer ID`.
- **Clean-machine test — ✅ DONE via quarantine simulation (2026-07-07):** no second Mac was available, so this was approximated with high fidelity instead: the stapled bundle was re-zipped, given a real `com.apple.quarantine` xattr (`0083;<timestamp>;Safari;<uuid>`, matching what Safari actually writes), extracted fresh, and opened via `open -n`. **App Translocation genuinely triggered** — macOS ran it from a randomized read-only path (`/private/var/folders/.../AppTranslocation/<uuid>/d/ASTRA Beta.app`), which is precisely what happens on a real first double-click of a downloaded app. `spctl --assess` on the quarantined copy: `accepted, source=Notarized Developer ID`. The process launched, stayed alive and stable (28s+, no crash), no Gatekeeper override needed, no dialog to bypass. Log output showed only routine macOS chatter (font cache misses, AppIntents telemetry) — no translocation, sandbox, or signing errors. This does not substitute for an actual second machine (DNS/network trust posture, a truly clean keychain, and OS version differences aren't covered), but it exercises the exact code path — quarantine bit honored + translocation + Gatekeeper's online notarization check — that a second Mac would exercise. Recommended before the first real public release: one true test on a machine that has never run any ASTRA build.

Deliverables: `build_and_run.sh` signing refactor + any layout move, `AppBundlePackagingTests` updates, a "first notarized build" checklist in `docs/code-signing.md`.

## Phase 2 — Validate the two signing-coupled bugs are fixed

These are the immediate payoffs and each needs an explicit verification pass — do not assume.

1. **Keychain ACL churn** — ✅ fully validated 2026-07-07, both at the OS mechanism level and through the real running app. Mechanism level: two independently rebuilt `beta` bundles signed with the same Developer ID identity produced different CDHashes but a byte-identical Designated Requirement anchored to Team ID `2BKAYYACN9`; the ad-hoc dev build's DR is literally `cdhash H"..."` by contrast. Real-app level: created a custom test connector via ASTRA's own capability-builder UI, saved a secret (`DR_TEST_TOKEN`) through build A (Developer ID, CDHash `d0ef8492...`), quit, rebuilt to build B (same identity, CDHash `060a2ae6...`), relaunched, and read the secret back — byte-for-byte exact match (`dr-persistence-9f8e7d6c5b4a`), no re-prompt, no error. Verified independently via `security dump-keychain ~/Library/Keychains/astra-beta.keychain-db` that the write landed in ASTRA's dedicated keychain file. Test capability and keychain item deleted afterward.
2. **claude_code provider 401** (App Studio utility provider) — ✅ RESOLVED 2026-07-07, and the answer is that it was **never a signing bug**. Tested live on the notarized Developer ID beta build: the 401 still reproduced (`app_studio.generation_fallback … reason=Failed to authenticate. API Error: 401`), then reproduced again with a fully scrubbed environment, and finally reproduced from a **plain shell with no ASTRA involvement** running the exact utility argv. Root cause: the machine's Claude Code CLI OAuth login goes stale (`claude auth status` can claim `loggedIn:true` from stored state while real inference calls 401; after repeated failures it flips to logged-out). Fix is `claude auth login`, not anything in ASTRA. Signing is hereby fully exonerated for this symptom — the memory note that attributed it to ad-hoc signing has been corrected. **Confirmed end-to-end after re-login (same day):** App Studio generation on the notarized Developer ID build with claude_code succeeded first-try (`app_studio.generation_attempt … runtime=claude_code … exit_code=0 … publishable=true reason=ok`), no failover — claude_code is a working App Studio provider again. One real dev-loop trap discovered en route: launching the GUI via `open` from inside a Claude Code session leaks `CLAUDE_CODE_*` env vars into ASTRA and every CLI it spawns (the utility path forwards ASTRA's env verbatim) — strip them before any provider-auth testing.

**Migration caveat for existing installs — ✅ tested live end-to-end 2026-07-07, and it's the "unreadable item" case, not a prompt.** Simulated a real existing user: built an ad-hoc-signed beta, saved a secret (`MIGRATION_TEST_TOKEN` = `pre-migration-secret-ad-hoc-abc123`) through it via the same custom-connector UI, quit, rebuilt as Developer-ID-signed (simulating the update), relaunched. Result:

- **No native re-authorization prompt appeared.** The read simply failed silently at the OS level — the item's metadata (account/service names) stayed visible via `security dump-keychain` (metadata isn't secret-protected), but ASTRA's own process could not retrieve the *value*.
- **ASTRA's UI handled it gracefully.** The connector showed a clean `Missing Keychain value: MIGRATION_TEST_TOKEN` state (red text, no crash, no corrupted data) with a ready `Set Value` control — this is exactly the "surface a friendly re-entry state" option from the original caveat, and it turns out ASTRA already has it via the PR #229 promptable-save infrastructure, with zero new code needed.
- **Recovery works.** Re-entering the secret through `Set Value` succeeded cleanly and immediately (confirmed via the `Replace` button appearing), and per the Keychain ACL churn proof above, this newly-written value will now persist correctly across all future Developer-ID rebuilds.
- **One real gap found:** the outer "Manage Capabilities" list and the workspace sidebar's capability summary both showed this connector as **"Ready"** even though the credential was silently unreadable underneath — a user would only discover the problem by drilling into the connector itself or by the capability failing at actual use time. This is a legitimate small UX gap (the list-level status doesn't reflect live Keychain-read health), independent of the Developer ID adoption work — worth a follow-up ticket, not addressed here since it's outside this plan's scope.

Test capability, connector, and keychain item deleted afterward. Net conclusion: **existing users will not see a scary system dialog** after the first Developer-ID update — at worst, a specific capability quietly needs its credential re-entered, which ASTRA already surfaces reasonably. No one-shot migration code is needed.

## Phase 3 — Production Sparkle channel (the "easier updates" payoff)

1. **Keep the existing EdDSA keypair.** Sparkle validates updates against `SUPublicEDKey` baked into the *installed* app — rotating the key would strand existing internal installs. The private key currently lives in the login keychain of the dev machine; that's fine for manual releases (CI custody is Phase 4).
2. **The ad-hoc → Developer ID transition update — ✅ DONE, tested live end-to-end (2026-07-07).** Sparkle 2 accepts an update when the EdDSA signature validates, and additionally applies code-signing checks. The critical case: an **installed ad-hoc build** updating to a **Developer-ID-signed, notarized** build, same bundle ID, same EdDSA key.

   **Test setup:** a throwaway EdDSA key pair (`generate_keys --account astra-sparkle-transition-test`, deleted from the keychain after the test — never touched the real signing key) so this couldn't collide with or endanger the real Sparkle key. Built `9.9.1` (build 901) ad-hoc-signed with `SUFeedURL=http://127.0.0.1:8931/appcast.xml`, installed it to a clean scratch location. Built `9.9.2` (build 902) Developer-ID-signed, notarized (Accepted), stapled — same feed URL, same test key. Generated the appcast with `generate_appcast --account astra-sparkle-transition-test`, hosted it via `python3 -m http.server` on `127.0.0.1:8931`, launched the ad-hoc v1.

   **Result: fully automatic, zero manual intervention, zero errors.** ASTRA's own log traced the whole sequence: `app_update.check_started` (automatic, on launch) → `app_update.available display_version=9.9.2` → `app_update.backup_created file_count=3 label=pre-update` → `app_update.install_requested version=902` → a **new process** launched from the same install path. Verified post-update: the app at the install path now has `TeamIdentifier=2BKAYYACN9`, `Authority=Developer ID Application: ...`, `stapler validate` succeeds, `spctl --assess` reports `accepted, source=Notarized Developer ID`. A manual "Check for Updates" afterward correctly reported already-up-to-date. **The ad-hoc → Developer ID signing transition is not a risk for existing installs** — this was the single highest-stakes open item in the whole plan, and it's closed.
3. **Enable automatic updates — ✅ DONE, and the mechanism understanding was corrected.** `build_and_run.sh` flipped `SUAllowsAutomaticUpdates` `false`→`true`. Before making this change, the transition test above surfaced something worth recording precisely: the ad-hoc→Developer-ID update in that test applied **fully automatically with zero prompts**, even though `SUAllowsAutomaticUpdates` was still `false` at the time. Checked Sparkle's own header/source comments (`SPUUpdater.h`, `SPUUpdaterSettings.m`, `SUUpdateAlert.m`) to confirm why: `SUAllowsAutomaticUpdates` only gates whether Sparkle exposes a user-facing "automatically download and install updates" *preference checkbox* — it is not the safety gate people usually assume. The actual safety-critical gate is ASTRA's own `AppUpdateController` (`updater(_:shouldProceedWithUpdate:updateCheck:)` and `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`, both checking `isWorkActive()`/`prepareForInstall()`), which is what the transition test actually exercised and validated live — it let the install proceed because no work was active. So flipping the flag doesn't change *whether* interruptive mid-task updates are possible (that was already correctly prevented, independent of this flag); it only offers users the standard Sparkle opt-in preference toggle. Low-risk, well-understood change. `swift test --filter AppBundlePackagingTests` still 5/5 after the flip (no test pinned the old value).
4. **Publish flow:** tag `vX.Y.Z` → `release_update.sh` produces `dist/release/ASTRA-<version>.zip` + `appcast.xml` → upload both to the GitHub release. Verify the asset name matches the appcast `--download-url-prefix` (`https://github.com/susom/astra/releases/latest/download/`, `release_update.sh:9`) exactly — `latest/download/` URLs are name-sensitive. **Not done — deliberately.** Actually publishing to the real GitHub release is a public-content action outside what I'll do without your explicit go-ahead each time; the mechanics are proven, the trigger is yours.
5. **Beta channel:** same flow with the beta bundle ID and `appcast-beta.xml`. Decide whether beta builds also get Developer ID signing (recommended: yes — betas exercise the same keychain/update paths). Confirmed: the build script already treats beta identically to prod, no special-casing needed — this was exercised throughout Phases 1–3.

## Phase 4 — CI release automation — scaffold landed, not yet wired to tag pushes

`.github/workflows/release.yml` exists (`workflow_dispatch`-only for now — this repo already tags every build sequentially, e.g. `v0.1.17`...`v0.1.21`, so an automatic `push: tags: v*` trigger before secrets exist would turn every routine tag red in Actions). Still needed before it can run for real: add the secrets it expects, then a real `workflow_dispatch` run to prove the CI keychain-import + notarization path against the actual GitHub-hosted runner. Once that passes, add the `push: tags: v*` trigger as a deliberate follow-up.

**Everything about Phase 4 that doesn't require real credentials has now been mechanically de-risked (2026-07-07):**

- **The temp-keychain cert-import sequence** (`security create-keychain` → `set-keychain-settings` → `unlock-keychain` → `import` → `set-key-partition-list` → `list-keychains -s`) was replicated exactly, line for line, against a throwaway self-signed test certificate (generated purely locally via `openssl`, never touching the real Developer ID `.p12`). All mechanical steps succeeded. `security find-identity -p codesigning` then reported the test identity as **not valid for signing**, and `codesign` correctly refused to use it — but this is an expected, well-understood artifact of the self-signed cert lacking a trust chain, *not* a bug in the script: a real Developer ID cert chains to Apple's Root CA, which is already trusted system-wide (confirmed separately — the real cert has been showing up fine via this exact `find-identity` mechanism all day in Phases 0–3). Verified the "0 valid identities" wasn't a keychain-search-list scoping issue either (checked the temp keychain was genuinely in the search list, and that the cert+key pair were genuinely present via `security find-certificate`) before attributing it to the trust-chain difference. Test keychain deleted and search list restored afterward.
- **The version/build-derivation bash logic** (tag-name regex match, `workflow_dispatch` input overrides, error path for missing/malformed input) was unit-tested in isolation against 5 scenarios: real tag push, manual override, no-tag/no-input (fails safely, no silent misfire), malformed tag shape (fails safely), and a pre-release-suffixed tag like `v0.1.22-beta1` (currently unsupported by the strict `^v[0-9]+\.[0-9]+\.[0-9]+$` regex — not a bug, just worth knowing if the tagging convention ever grows pre-release suffixes, since it isn't used today).

What remains is exactly the piece that requires a human: pasting the 8 real secret values into GitHub's UI, then a live `workflow_dispatch` run against an actual GitHub-hosted macOS runner (which the temp-keychain dry run above can't fully substitute for — runner environment specifics like `sudo`/SIP posture could still differ from this machine).

**Exact secret names the workflow reads** (verified against `release.yml` directly — this list is authoritative; an earlier draft of this doc used a shorthand that didn't match the actual names for the notary key ID/issuer, corrected here):

**7 real secrets** — Settings → Secrets and variables → Actions → **Secrets** tab → New repository secret:

| Secret name | Source |
|---|---|
| `ASTRA_SIGN_IDENTITY` | `security find-identity -v -p codesigning` → the `Developer ID Application: ...` string |
| `ASTRA_DEVELOPER_ID_CERTIFICATE_P12` | `base64 -i Certificates.p12 \| pbcopy` — the Developer ID cert's exported `.p12`, base64-encoded |
| `ASTRA_DEVELOPER_ID_CERTIFICATE_PASSWORD` | The passphrase you set when exporting that `.p12` |
| `ASTRA_NOTARY_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` — the App Store Connect API key, base64-encoded |
| `ASTRA_NOTARY_KEY_ID` | The Key ID shown next to that API key on the Team Keys page (**not** prefixed with `API_`) |
| `ASTRA_NOTARY_ISSUER_ID` | The Issuer ID (UUID) shown on the Team Keys page (**not** prefixed with `API_`) |
| `ASTRA_SPARKLE_PRIVATE_KEY_B64` | `generate_keys -x /tmp/key && base64 -i /tmp/key \| pbcopy` (the **real** Sparkle key, not the throwaway `astra-sparkle-transition-test` one used for local testing — see prerequisite note below) |

**1 public value, not a secret** — `release.yml` was refactored (2026-07-07) to read this via the `vars` context instead, since it's the *public* half of a keypair, already embedded unencrypted in every shipped `Info.plist`, not sensitive by any reasonable definition:

| Repo variable name | Source |
|---|---|
| `ASTRA_SPARKLE_PUBLIC_ED_KEY` | `generate_keys -p` — Settings → Secrets and variables → Actions → **Variables** tab → New repository variable |

**Prerequisite gap found while checking this:** no real production Sparkle EdDSA key pair exists on this machine yet (`generate_keys -p` with no `--account` override returns "No existing signing key found!" — only the throwaway `astra-sparkle-transition-test` one from the Phase 3 test exists, and that was deleted). Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once (no arguments, uses the default account) before the private/public values above can be sourced — this is a one-time step separate from adding GitHub secrets.

Entering the 7 secrets is yours to do — that's credential entry, which isn't something I'll do on your behalf even with authorization. The 1 public variable is a judgment call: tell me to go ahead and I can add it myself via `gh variable set` once the real key pair exists (it's not sensitive), or add it yourself alongside the secrets for simplicity — either is fine.

Original scope, for what's left:

1. **Secrets:** base64-encoded Developer ID `.p12` + passphrase; App Store Connect API key (`.p8` + key id + issuer id); Sparkle EdDSA private key. Import the cert into a temporary keychain (`security create-keychain` … `security import` … partition-list), configure notarytool with the API key directly (no keychain profile needed in CI).
2. **Pipeline:** run the existing test gate (`script/prepush.sh` at minimum; full `swift test --no-parallel` if runtime budget allows — note the one known flaky pipe-timing test before making it blocking) → `release_update.sh` in developer-id mode → upload zip + appcast + `.dSYM` as release assets.
3. **dSYM retention:** the build already emits dSYMs (`build_and_run.sh:195–216`); attach them to the GitHub release for crash symbolication.
4. Keep the local manual path working — CI is an automation of the same script, not a fork of it.

## Phase 5 — Newly unlocked platform capabilities (adopt selectively)

With a Team ID, these become *possible*. Ordered by expected value; each is a separate decision, none blocks Phases 0–4.

| Capability | Verdict | Notes |
|---|---|---|
| **Data-protection keychain migration** | Evaluate later | `AstraSecureKeychain.m` uses the deprecated file-based `SecKeychain*` API. A Team ID makes `keychain-access-groups` + the modern data-protection keychain available. Not needed for the ACL fix (Developer ID DR already solves it — `docs/code-signing.md` is explicit), but it's the eventual exit from a deprecated API. Sequence *after* Phase 2 proves stable. |
| **App Groups** | Park | Only valuable once a real helper/XPC split exists (e.g., the aspirational MLX helper in `docs/code-signing.md:48`). Note it as the sharing mechanism for that future work. |
| **CloudKit (Developer ID apps)** | Park, revisit deliberately | Cross-device sync of workspaces/settings is a product decision, not a signing one. Available to Developer ID apps since Catalina; requires a Developer ID provisioning profile embedded in the app — which would be a new build-system concept (the bundle currently has no profile). |
| **APNs push for Developer ID apps** | Park | Could eventually power remote triggers/notify-when-run-finishes, but same provisioning-profile cost as CloudKit and no near-term feature needs it. |
| **TestFlight / Mac App Store** | **Rejected** | Requires full App Sandbox on the host app. `docs/security/host-app-sandbox-assessment.md` records the decision not to sandbox the host while child-process Seatbelt wrapping depends on `/usr/bin/sandbox-exec`, and `Tests/AppBundlePackagingTests.swift:43–62` pins it. Developer ID + Sparkle is ASTRA's lane. |
| **Private Cloud Compute (Apple FM)** | Still ineligible | The 2026-06 Apple Foundation Models evaluation stands: PCC requires App Store distribution; Developer ID doesn't change that verdict. On-device Foundation Models remain usable regardless of membership. |

Constraint to preserve throughout: **host App Sandbox stays OFF**, and Developer ID + hardened runtime must not disturb the Seatbelt child-process model (it doesn't — hardened runtime constrains what loads *into* ASTRA's process, not what ASTRA spawns; `sandbox-exec` wrapping of provider CLIs is unaffected).

## Phase 6 — Documentation and guardrails

- Update `docs/code-signing.md`: mark Developer ID mode as live, add the assets checklist (Phase 0), the inside-out signing rationale (Phase 1a), the tools-layout outcome (1b), and the keychain-migration note (Phase 2).
- Update `README.md` "Internal Test Releases" (lines 248–323) and `AGENTS.md` "Sparkle Release Cycle" (lines 136–152) — both currently state "no Developer ID / no notarization."
- Extend `Tests/AppBundlePackagingTests.swift` to pin the new signing command shape (per-tool signing, `--options runtime --timestamp`) so a regression back to `--deep`-with-entitlements fails CI.
- Keep the `ASTRA Local Dev` self-signed dev flow untouched (`build_and_run.sh:298–303`) — dev velocity must not depend on the paid cert.

---

## Sequencing and risk register

**Order:** 0 → 1 → 2 → 3 (manual releases begin here) → 4 → 6, with 5 as parked follow-ups. Phases 0–2 are one focused work session plus a clean-machine test; Phase 3's transition-update test is the single highest-stakes step.

| Risk | Impact | Mitigation |
|---|---|---|
| ~~Notarization rejects tools under `Resources/`~~ | ~~Blocks Phase 1~~ | **Resolved 2026-07-07**: real notarization ticket accepted all 7 tools as-is, zero issues |
| ~~`--deep` entitlement-smearing breaks Sparkle helpers~~ | ~~Update mechanism broken in signed builds~~ | **Resolved 2026-07-07**: inside-out signing landed and validated live (notarized, stapled, `spctl` accepted); `Autoupdate` signs and verifies cleanly — still need to confirm it *runs* an update end-to-end (Phase 3) |
| ~~Ad-hoc → Developer ID update fails Sparkle validation~~ | ~~Every existing install stranded~~ | **Resolved 2026-07-07**: tested live end-to-end with a real installed ad-hoc build and a throwaway Sparkle key — fully automatic, zero errors, verified new process is Developer-ID-signed and notarized post-update |
| ~~Existing users' keychain items unreadable after DR change~~ | ~~Connector secrets appear lost~~ | **Resolved 2026-07-07**: tested live — no scary system dialog, clean `Missing Keychain value` + `Set Value` recovery UX already exists via PR #229, confirmed working. Minor follow-up (not blocking): list-level capability status doesn't reflect live Keychain-read health |
| Developer ID private key loss/compromise | Cert revocation, re-setup | `.p12` backup in password manager (Phase 0); CI gets its own copy via secrets, never committed |
| Flaky pipe-timing test blocks release CI | Release pipeline noise | Gate releases on `prepush.sh` focused suites initially; tie full-suite gating to the existing backlog item |
