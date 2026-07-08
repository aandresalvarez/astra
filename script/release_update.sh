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

FINAL_ZIP="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.zip"
FINAL_DMG="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.dmg"

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

SIGN_KEYCHAIN_ARGS=()
if [[ -n "${ASTRA_RELEASE_KEYCHAIN:-}" ]]; then
  SIGN_KEYCHAIN_ARGS=(--keychain "$ASTRA_RELEASE_KEYCHAIN")
fi

require_tool ditto
require_tool codesign
require_tool hdiutil
if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  require_tool xcrun
fi

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-generate_appcast}"
if ! command -v "$GENERATE_APPCAST" >/dev/null 2>&1; then
  echo "Missing Sparkle generate_appcast. Set SPARKLE_GENERATE_APPCAST to its absolute path." >&2
  exit 2
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ASTRA_BUILD_CONFIGURATION=release \
ASTRA_CHANNEL=prod \
ASTRA_VERSION="$ASTRA_VERSION" \
ASTRA_BUILD="$ASTRA_BUILD" \
ASTRA_SPARKLE_PUBLIC_ED_KEY="$ASTRA_SPARKLE_PUBLIC_ED_KEY" \
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

ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"

GENERATE_APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  GENERATE_APPCAST_ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

# Keep the DMG out of Sparkle's appcast. Sparkle updates use the zip; humans
# should install from the signed/notarized disk image to avoid raw-zip
# quarantine propagation on first launch.
"$GENERATE_APPCAST" "${GENERATE_APPCAST_ARGS[@]}" "$RELEASE_DIR"

DMG_STAGING="$RELEASE_DIR/dmg-root"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -quiet \
  -volname "$APP_NAME $ASTRA_VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$FINAL_DMG"
rm -rf "$DMG_STAGING"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp "${SIGN_KEYCHAIN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$FINAL_DMG"
fi

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$ASTRA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$FINAL_DMG"
  xcrun stapler validate "$FINAL_DMG"
fi

echo "Release assets:"
echo "  $FINAL_ZIP"
echo "  $FINAL_DMG"
echo "  $RELEASE_DIR/appcast.xml"
if [[ "$RELEASE_MODE" == "internal" ]]; then
  echo
  echo "Internal release note:"
  echo "  This build is ad-hoc signed and Sparkle-signed, but the app/DMG are not Apple notarized."
  echo "  First install may require a manual Gatekeeper approval on each Mac."
fi
