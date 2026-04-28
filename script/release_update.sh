#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_NAME="ASTRA"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DOWNLOAD_URL_PREFIX="${ASTRA_DOWNLOAD_URL_PREFIX:-https://github.com/susom/astra/releases/latest/download/}"

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
require_env ASTRA_SIGN_IDENTITY
require_env ASTRA_SPARKLE_PUBLIC_ED_KEY

if [[ "${ASTRA_SKIP_NOTARIZATION:-0}" != "1" ]]; then
  require_env ASTRA_NOTARY_PROFILE
fi

require_tool ditto
require_tool codesign
require_tool xcrun

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
ASTRA_SIGN_IDENTITY="$ASTRA_SIGN_IDENTITY" \
"$ROOT_DIR/script/build_and_run.sh" bundle >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

NOTARY_ZIP="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}-notary.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"

if [[ "${ASTRA_SKIP_NOTARIZATION:-0}" != "1" ]]; then
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$ASTRA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  spctl --assess --type execute --verbose "$APP_BUNDLE"
fi
rm -f "$NOTARY_ZIP"

FINAL_ZIP="$RELEASE_DIR/${APP_NAME}-${ASTRA_VERSION}.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"

GENERATE_APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  GENERATE_APPCAST_ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

"$GENERATE_APPCAST" "${GENERATE_APPCAST_ARGS[@]}" "$RELEASE_DIR"

echo "Release assets:"
echo "  $FINAL_ZIP"
echo "  $RELEASE_DIR/appcast.xml"
