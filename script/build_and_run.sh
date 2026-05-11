#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="ASTRA"
TOOL_PRODUCTS=("astra-browser" "stanford-mail" "stanford-apple-mail" "stanford-graph-mail")
ASTRA_CHANNEL="${ASTRA_CHANNEL:-dev}"
MIN_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${ASTRA_BUILD_CONFIGURATION:-debug}"
REQUIRE_ARM64="${ASTRA_REQUIRE_ARM64:-1}"
APP_VERSION="${ASTRA_VERSION:-0.1.0}"
APP_BUILD="${ASTRA_BUILD:-1}"
SPARKLE_PUBLIC_ED_KEY="${ASTRA_SPARKLE_PUBLIC_ED_KEY:-${SPARKLE_PUBLIC_ED_KEY:-}}"
SIGN_IDENTITY="${ASTRA_SIGN_IDENTITY:-}"

verify_arm64_binary() {
  local binary="$1"
  local description
  description="$(/usr/bin/file "$binary")"
  if [[ "$description" != *"arm64"* ]]; then
    echo "ASTRA is Apple-Silicon-only; expected an arm64 binary at $binary." >&2
    echo "Actual: $description" >&2
    exit 2
  fi
}

validate_sparkle_public_ed_key() {
  local key="$1"
  local decoded_length
  decoded_length="$(printf '%s' "$key" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')" || return 1
  [[ "$decoded_length" == "32" ]]
}

case "$ASTRA_CHANNEL" in
  prod|production)
    ASTRA_CHANNEL="prod"
    APP_NAME="ASTRA"
    BUNDLE_ID="com.coral.ASTRA"
    DEFAULT_SPARKLE_FEED_URL="https://github.com/susom/astra/releases/latest/download/appcast.xml"
    ;;
  dev|development)
    ASTRA_CHANNEL="dev"
    APP_NAME="ASTRA Dev"
    BUNDLE_ID="com.coral.ASTRA.dev"
    DEFAULT_SPARKLE_FEED_URL=""
    ;;
  beta)
    APP_NAME="ASTRA Beta"
    BUNDLE_ID="com.coral.ASTRA.beta"
    DEFAULT_SPARKLE_FEED_URL="https://github.com/susom/astra/releases/latest/download/appcast-beta.xml"
    ;;
  *)
    echo "Unknown ASTRA_CHANNEL '$ASTRA_CHANNEL'. Use dev, beta, or prod." >&2
    exit 2
    ;;
esac

SPARKLE_FEED_URL="${ASTRA_SPARKLE_FEED_URL:-$DEFAULT_SPARKLE_FEED_URL}"

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] && ! validate_sparkle_public_ed_key "$SPARKLE_PUBLIC_ED_KEY"; then
  echo "Invalid ASTRA_SPARKLE_PUBLIC_ED_KEY: expected a base64 Sparkle EdDSA public key that decodes to 32 bytes." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/script/ASTRA.entitlements"

if [[ "$REQUIRE_ARM64" == "1" ]]; then
  HOST_ARCH="$(/usr/bin/uname -m)"
  if [[ "$HOST_ARCH" != "arm64" ]]; then
    echo "ASTRA is Apple-Silicon-only; run this script from a native arm64 shell on Apple Silicon." >&2
    echo "Current process architecture: $HOST_ARCH" >&2
    exit 2
  fi
fi

if [[ "$MODE" != "bundle" && "$MODE" != "--bundle" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

SWIFT_BUILD_ARGS=(--package-path "$ROOT_DIR")
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  SWIFT_BUILD_ARGS=(-c release "${SWIFT_BUILD_ARGS[@]}")
fi

swift build "${SWIFT_BUILD_ARGS[@]}"
for tool_product in "${TOOL_PRODUCTS[@]}"; do
  swift build "${SWIFT_BUILD_ARGS[@]}" --product "$tool_product"
done
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [[ "$REQUIRE_ARM64" == "1" ]]; then
  verify_arm64_binary "$BUILD_BINARY"
  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    verify_arm64_binary "$BUILD_DIR/$tool_product"
  done
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ -d "$BUILD_DIR/ASTRA_ASTRA.bundle" ]; then
  cp -R "$BUILD_DIR/ASTRA_ASTRA.bundle" "$APP_RESOURCES/"
fi

BUNDLED_TOOLS_DIR="$APP_RESOURCES/ASTRA_ASTRA.bundle/Tools"
mkdir -p "$BUNDLED_TOOLS_DIR"
for tool_product in "${TOOL_PRODUCTS[@]}"; do
  cp "$BUILD_DIR/$tool_product" "$BUNDLED_TOOLS_DIR/$tool_product"
  chmod +x "$BUNDLED_TOOLS_DIR/$tool_product"
done

if [ -f "$ROOT_DIR/Astra/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Astra/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

copy_sparkle_framework() {
  local framework=""
  framework="$(find "$ROOT_DIR/.build" -type d -name Sparkle.framework | head -n 1 || true)"
  if [[ -n "$framework" ]]; then
    /usr/bin/ditto "$framework" "$APP_FRAMEWORKS/Sparkle.framework"
    /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY" >/dev/null 2>&1 || true
  fi
}

copy_sparkle_framework

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>ASTRAChannel</key>
  <string>$ASTRA_CHANNEL</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>ASTRA needs permission to control Apple Mail when the Stanford Mail via Apple Mail capability is enabled.</string>
PLIST

if [[ -n "$SPARKLE_FEED_URL" ]]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
PLIST
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
PLIST
fi

cat >>"$INFO_PLIST" <<PLIST
</dict>
</plist>
PLIST

if [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  /usr/bin/codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  bundle|--bundle)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [bundle|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
