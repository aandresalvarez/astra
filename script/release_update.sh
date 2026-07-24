#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_NAME="ASTRA"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DOWNLOAD_URL_PREFIX="${ASTRA_DOWNLOAD_URL_PREFIX:-https://github.com/aandresalvarez/astra/releases/latest/download/}"
RELEASE_MODE="${ASTRA_RELEASE_MODE:-internal}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 2
  fi
}

require_env ASTRA_VERSION
require_env ASTRA_BUILD
require_env ASTRA_SPARKLE_PUBLIC_ED_KEY

case "$RELEASE_MODE" in
  internal)
    SIGN_IDENTITY=""
    SKIP_NOTARIZATION=1
    ;;
  developer-id)
    require_env ASTRA_SIGN_IDENTITY
    SIGN_IDENTITY="$ASTRA_SIGN_IDENTITY"
    SKIP_NOTARIZATION="${ASTRA_SKIP_NOTARIZATION:-0}"
    if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
      require_env ASTRA_NOTARY_PROFILE
    fi
    ;;
  *)
    echo "Unknown ASTRA_RELEASE_MODE '$RELEASE_MODE'. Use internal or developer-id." >&2
    exit 2
    ;;
esac

require_tool ditto
require_tool codesign
require_tool hdiutil
if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  require_tool xcrun
  require_tool syspolicy_check
  require_tool xattr
  require_tool uuidgen
fi

# Simulates what Gatekeeper actually evaluates on a user's Mac: extracts the
# exact zip we're about to ship into a clean directory and stamps a quarantine
# xattr on every file inside it, recursively -- exactly what Archive Utility
# does to a browser download, confirmed live against a real Chrome extraction.
# codesign --verify at build time (above) only proves the signature is well
# formed; it says nothing about whether a freshly quarantined copy will
# actually be allowed to launch. syspolicy_check distribution is Apple's
# current recommended tool for this (see `syspolicy_check --help`) -- spctl is
# deprecated and has produced spurious "bundle format unrecognized" failures
# on notarized, correctly-signed apps on at least one real Mac.
verify_first_launch_experience() {
  local zip_path="$1"
  local verify_dir
  verify_dir="$(mktemp -d)"
  trap 'rm -rf "$verify_dir"' RETURN

  ditto -x -k "$zip_path" "$verify_dir"
  local extracted_app="$verify_dir/$APP_NAME.app"

  local quarantine_value
  quarantine_value="0083;$(printf '%08x' "$(date +%s)");Chrome;$(uuidgen)"
  find "$extracted_app" -exec xattr -w com.apple.quarantine "$quarantine_value" {} +

  echo "Verifying first-launch experience against a quarantined copy of the shipped zip..."
  codesign --verify --deep --strict --verbose=2 "$extracted_app"
  syspolicy_check distribution "$extracted_app" --verbose
}

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-generate_appcast}"
if ! command -v "$GENERATE_APPCAST" >/dev/null 2>&1; then
  echo "Missing Sparkle generate_appcast. Set SPARKLE_GENERATE_APPCAST to its absolute path." >&2
  exit 2
fi
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$(dirname "$GENERATE_APPCAST")/sign_update}"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "Missing Sparkle sign_update beside generate_appcast. Set SPARKLE_SIGN_UPDATE." >&2
  exit 2
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ASTRA_BUILD_CONFIGURATION=release \
ASTRA_CHANNEL=prod \
ASTRA_VERSION="$ASTRA_VERSION" \
ASTRA_BUILD="$ASTRA_BUILD" \
ASTRA_SPARKLE_PUBLIC_ED_KEY="$ASTRA_SPARKLE_PUBLIC_ED_KEY" \
ASTRA_SPARKLE_SIGN_UPDATE="$SIGN_UPDATE" \
ASTRA_SIGN_IDENTITY="$SIGN_IDENTITY" \
"$ROOT_DIR/script/build_and_run.sh" bundle >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  NOTARY_ZIP="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}-notary.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$ASTRA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  spctl --assess --type execute --verbose "$APP_BUNDLE"
  rm -f "$NOTARY_ZIP"
else
  echo "Skipping Apple Developer ID notarization for ASTRA_RELEASE_MODE=$RELEASE_MODE."
fi

FINAL_ZIP="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  verify_first_launch_experience "$FINAL_ZIP"
fi

# The zip above is Sparkle's update payload, not what a human should click
# first. The DMG contains one unambiguous action: "Install ASTRA.app". Opening
# that signed app presents ASTRA's guided installer, which owns destination
# detection, explicit replacement, progress, verification, and relaunch.
# Renaming only the outer bundle directory does not alter the signed contents;
# the guided installer copies itself to the canonical /Applications/ASTRA.app
# destination. This also stays deterministic on headless CI: no Finder or
# AppleScript layout step is required.
#
# Built outside $RELEASE_DIR and only moved in after generate_appcast runs
# below: generate_appcast treats every update archive it finds in its target
# directory as a distinct update for its bundle version, and errors out
# ("Duplicate updates are not supported") if a .zip and a .dmg both exist
# there for the same version -- confirmed live. The DMG is a convenience
# download for humans, not part of Sparkle's feed, so it must not be visible
# to that scan at all.
FINAL_DMG="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg"
DMG_BUILD_PATH="$DIST_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg"
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
ditto "$APP_BUNDLE" "$DMG_STAGING/Install $APP_NAME.app"
rm -f "$DMG_BUILD_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -format UDZO -ov "$DMG_BUILD_PATH" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Reuse the exact hardened identity resolution build_and_run.sh uses for
  # app signing, not a naive `--sign "$SIGN_IDENTITY"`: this repo already
  # spent three PRs (#234-#236) tracking down "no identity found" in CI to
  # two separate root causes -- codesign relying on the ambient keychain
  # search list instead of an explicit --keychain pointer, fragile across
  # the ~10-25 minute CI job, and stray whitespace in the raw
  # ASTRA_SIGN_IDENTITY secret defeating codesign's literal substring
  # match. $SIGN_IDENTITY here is deliberately the RAW, untrimmed value
  # (build_and_run.sh does its own trimming internally, invisible to this
  # script, which just sets env vars for that separate subprocess) -- both
  # fixes have to be reapplied here or this new DMG-signing call would
  # regress exactly the bugs already fixed for the app.
  DMG_SIGN_IDENTITY="${SIGN_IDENTITY#"${SIGN_IDENTITY%%[![:space:]]*}"}"
  DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY%"${DMG_SIGN_IDENTITY##*[![:space:]]}"}"
  DMG_SIGN_KEYCHAIN_ARGS=()
  if [[ -n "${ASTRA_RELEASE_KEYCHAIN:-}" ]]; then
    DMG_SIGN_KEYCHAIN_ARGS=(--keychain "$ASTRA_RELEASE_KEYCHAIN")
  fi
  codesign --force --timestamp "${DMG_SIGN_KEYCHAIN_ARGS[@]+"${DMG_SIGN_KEYCHAIN_ARGS[@]}"}" --sign "$DMG_SIGN_IDENTITY" "$DMG_BUILD_PATH"
  codesign --verify --verbose=2 "$DMG_BUILD_PATH"

  if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
    # Apple's own DTS guidance for DMG distribution: sign the app, put it
    # in the disk image, sign the disk image, and notarize that outermost
    # container too (https://developer.apple.com/forums/thread/125145).
    # The inner .app being separately notarized+stapled isn't enough --
    # the DMG itself is the first thing Gatekeeper evaluates when a user
    # downloads and opens it, and an unnotarized signed container can
    # still fail or warn even though the app inside is fine.
    xcrun notarytool submit "$DMG_BUILD_PATH" --keychain-profile "$ASTRA_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_BUILD_PATH"
    xcrun stapler validate "$DMG_BUILD_PATH"
    # spctl, not syspolicy_check, for this specific check: syspolicy_check
    # distribution is documented in terms of an application bundle, not a
    # disk image, and --type open is the Apple-documented spctl invocation
    # for assessing a DMG container specifically (distinct from --type
    # execute, used above for the .app -- the spurious "bundle format
    # unrecognized" spctl failure seen on this project was specifically
    # from --type execute against a signed .app, not this).
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_BUILD_PATH"
  fi
fi

GENERATE_APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  GENERATE_APPCAST_ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

"$GENERATE_APPCAST" "${GENERATE_APPCAST_ARGS[@]}" "$RELEASE_DIR"

mv "$DMG_BUILD_PATH" "$FINAL_DMG"

echo "Release assets:"
echo "  $FINAL_ZIP"
echo "  $FINAL_DMG"
echo "  $RELEASE_DIR/appcast.xml"
if [[ "$RELEASE_MODE" == "internal" ]]; then
  echo
  echo "Internal release note:"
  echo "  This build is ad-hoc signed and Sparkle-signed, but not Apple notarized."
  echo "  First install may require a manual Gatekeeper approval on each Mac."
fi
