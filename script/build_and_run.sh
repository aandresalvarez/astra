#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="ASTRA"
TOOL_PRODUCTS=("astra-browser" "astra-mcp-gateway" "astra-host-control" "astra-workspace" "stanford-mail" "stanford-apple-mail" "stanford-graph-mail")
ASTRA_CHANNEL="${ASTRA_CHANNEL:-dev}"
MIN_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${ASTRA_BUILD_CONFIGURATION:-debug}"
# Strip debug/symbol tables from bundled binaries before signing. The shipped
# executable carries a ~50%+ __LINKEDIT segment of local symbols that page in
# nothing at launch but bloat the download. Off by default for debug builds so
# `--debug` runs keep symbols for lldb; on by default for release. Override with
# ASTRA_STRIP_BINARIES=0/1.
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  STRIP_BINARIES="${ASTRA_STRIP_BINARIES:-1}"
else
  STRIP_BINARIES="${ASTRA_STRIP_BINARIES:-0}"
fi
REQUIRE_ARM64="${ASTRA_REQUIRE_ARM64:-1}"
SPARKLE_PUBLIC_ED_KEY="${ASTRA_SPARKLE_PUBLIC_ED_KEY:-${SPARKLE_PUBLIC_ED_KEY:-}}"
GOOGLE_MANAGED_OAUTH_CLIENT_ID="${ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID:-}"
SIGN_IDENTITY="${ASTRA_SIGN_IDENTITY:-}"

latest_release_tag() {
  git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=v:refname 2>/dev/null | tail -n 1 || true
}

default_app_version() {
  local tag
  tag="$(latest_release_tag)"
  if [[ -n "$tag" ]]; then
    printf '%s\n' "${tag#v}"
  else
    printf '0.1.0\n'
  fi
}

default_app_build() {
  local count
  count="$(git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    printf '%s\n' "$count"
  else
    printf '1\n'
  fi
}

APP_VERSION="${ASTRA_VERSION:-$(default_app_version)}"
APP_BUILD="${ASTRA_BUILD:-$(default_app_build)}"
ASTRA_GIT_COMMIT="${ASTRA_GIT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
ASTRA_BUILD_DATE="${ASTRA_BUILD_DATE:-$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')}"

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

validate_google_managed_oauth_client_id() {
  local client_id="$1"
  [[ "$client_id" =~ ^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$ ]]
}

case "$ASTRA_CHANNEL" in
  prod|production)
    ASTRA_CHANNEL="prod"
    APP_NAME="ASTRA"
    BUNDLE_ID="com.coral.ASTRA"
    URL_SCHEME="astra"
    DEFAULT_SPARKLE_FEED_URL="https://github.com/susom/astra/releases/latest/download/appcast.xml"
    ;;
  dev|development)
    ASTRA_CHANNEL="dev"
    APP_NAME="ASTRA Dev"
    BUNDLE_ID="com.coral.ASTRA.dev"
    URL_SCHEME="astra-dev"
    DEFAULT_SPARKLE_FEED_URL=""
    ;;
  beta)
    APP_NAME="ASTRA Beta"
    BUNDLE_ID="com.coral.ASTRA.beta"
    URL_SCHEME="astra-beta"
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

if [[ -n "$GOOGLE_MANAGED_OAUTH_CLIENT_ID" ]] && ! validate_google_managed_oauth_client_id "$GOOGLE_MANAGED_OAUTH_CLIENT_ID"; then
  echo "Invalid ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID: expected a Google OAuth client ID ending in .apps.googleusercontent.com." >&2
  exit 2
fi

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

APP_ICON_SOURCE="$ROOT_DIR/Astra/Resources/AppIcon.icns"
if [[ "$ASTRA_CHANNEL" == "dev" && -f "$ROOT_DIR/Astra/Resources/AppIconDev.icns" ]]; then
  APP_ICON_SOURCE="$ROOT_DIR/Astra/Resources/AppIconDev.icns"
fi

if [ -f "$APP_ICON_SOURCE" ]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
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

strip_bundled_binaries() {
  [[ "$STRIP_BINARIES" == "1" ]] || return 0
  # Preserve a dSYM for crash symbolication before stripping local symbols.
  if xcrun dsymutil "$APP_BINARY" -o "$APP_BUNDLE.dSYM" >/dev/null 2>&1; then
    echo "  wrote $APP_BUNDLE.dSYM"
  fi
  # -r keeps dynamically-referenced symbols, -S removes debug symbols,
  # -T/-x trim local symbol-table entries. Must run before codesign so the
  # signature covers the stripped bytes.
  local target
  for target in "$APP_BINARY" "$BUNDLED_TOOLS_DIR"/*; do
    [[ -f "$target" ]] || continue
    local before after
    before="$(stat -f%z "$target" 2>/dev/null || echo 0)"
    if xcrun strip -rSTx "$target" >/dev/null 2>&1; then
      after="$(stat -f%z "$target" 2>/dev/null || echo 0)"
      echo "  stripped $(basename "$target"): ${before} -> ${after} bytes"
    fi
  done
}

strip_bundled_binaries

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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.external-route</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$URL_SCHEME</string>
      </array>
    </dict>
  </array>
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
  <key>ASTRAGitCommit</key>
  <string>$ASTRA_GIT_COMMIT</string>
  <key>ASTRABuildDate</key>
  <string>$ASTRA_BUILD_DATE</string>
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
  <true/>
PLIST
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
PLIST
fi

if [[ -n "$GOOGLE_MANAGED_OAUTH_CLIENT_ID" ]]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>ASTRAGoogleOAuthClientID</key>
  <string>$GOOGLE_MANAGED_OAUTH_CLIENT_ID</string>
PLIST
fi

cat >>"$INFO_PLIST" <<PLIST
</dict>
</plist>
PLIST

# Dev builds prefer a STABLE self-signed identity over ad-hoc when one exists, so
# the login-keychain ACL (bound to the signing Designated Requirement) survives
# rebuilds. An ad-hoc signature's DR is a cdhash that changes on every build, which
# is what triggers the repeated keychain prompts/failures while configuring ASTRA.
if [[ -z "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" == "dev" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"ASTRA Local Dev"'; then
    SIGN_IDENTITY="ASTRA Local Dev"
    echo "  signing dev build with stable self-signed identity 'ASTRA Local Dev'"
  fi
fi

sign_developer_id() {
  local target="$1"
  /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$target"
}

sign_bundled_tools_for_notarization() {
  local tool_product
  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    sign_developer_id "$BUNDLED_TOOLS_DIR/$tool_product"
  done
}

sign_sparkle_framework_for_notarization() {
  local framework="$APP_FRAMEWORKS/Sparkle.framework"
  [[ -d "$framework" ]] || return 0
  # Sign inside-out: Sparkle's own XPC services / helper app / Autoupdate tool
  # first, then the framework. Notarization requires every Mach-O in the
  # bundle to carry hardened runtime + a secure timestamp.
  local nested
  while IFS= read -r -d '' nested; do
    sign_developer_id "$nested"
  done < <(find "$framework" \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null)
  local autoupdate
  autoupdate="$(find "$framework" -type f -name "Autoupdate" -print 2>/dev/null | head -n 1 || true)"
  [[ -n "$autoupdate" ]] && sign_developer_id "$autoupdate"
  sign_developer_id "$framework"
}

if [[ -n "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" != "dev" ]]; then
  # Distributed channels (prod/beta): sign inside-out with hardened runtime +
  # secure timestamp so the bundle can be notarized. Deliberately NOT --deep
  # here: --deep stamps this app's own entitlements onto every nested Mach-O,
  # including Sparkle's XPC services and helper app, which invalidates their
  # own signatures. Nested code must be signed first, then the outer bundle.
  sign_bundled_tools_for_notarization
  sign_sparkle_framework_for_notarization
  /usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
elif [[ -n "$SIGN_IDENTITY" ]]; then
  # Dev: stable identity but NO hardened runtime/timestamp. Those are only needed
  # for notarization and would change local runtime behavior vs the ad-hoc build
  # (hardened runtime enables library validation against the bundled tools/helper).
  /usr/bin/codesign --force --deep --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  /usr/bin/codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
fi

verify_app_bundle() {
  local errors=0

  if [[ ! -x "$APP_BINARY" ]]; then
    echo "FAIL: executable missing: $APP_BINARY" >&2
    errors=$((errors + 1))
  fi

  if [[ ! -f "$INFO_PLIST" ]]; then
    echo "FAIL: Info.plist missing: $INFO_PLIST" >&2
    errors=$((errors + 1))
  fi

  if [[ ! -d "$APP_FRAMEWORKS/Sparkle.framework" ]]; then
    echo "FAIL: Sparkle.framework missing from $APP_FRAMEWORKS" >&2
    errors=$((errors + 1))
  fi

  if [[ ! -f "$APP_FRAMEWORKS/Sparkle.framework/Versions/B/Sparkle" ]]; then
    echo "FAIL: Sparkle dynamic library missing inside Sparkle.framework" >&2
    errors=$((errors + 1))
  fi

  local linked_libs
  linked_libs="$(/usr/bin/otool -L "$APP_BINARY" 2>/dev/null)" || true
  if echo "$linked_libs" | grep -q '@rpath/Sparkle.framework'; then
    if ! /usr/bin/otool -l "$APP_BINARY" 2>/dev/null | grep -q '@executable_path/../Frameworks'; then
      echo "FAIL: binary links Sparkle via @rpath but missing @executable_path/../Frameworks rpath" >&2
      errors=$((errors + 1))
    fi
  fi

  if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "FAIL: code signature verification failed for $APP_BUNDLE" >&2
    errors=$((errors + 1))
  fi

  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    if [[ ! -x "$BUNDLED_TOOLS_DIR/$tool_product" ]]; then
      echo "FAIL: bundled tool missing: $BUNDLED_TOOLS_DIR/$tool_product" >&2
      errors=$((errors + 1))
    fi
  done

  if [[ -n "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" != "dev" ]]; then
    # Distribution builds: catch a broken inside-out signature locally,
    # before it surfaces as an opaque notarytool rejection.
    for tool_product in "${TOOL_PRODUCTS[@]}"; do
      if ! /usr/bin/codesign --verify --strict "$BUNDLED_TOOLS_DIR/$tool_product" 2>/dev/null; then
        echo "FAIL: signature verification failed for bundled tool $tool_product" >&2
        errors=$((errors + 1))
      fi
    done
    if ! /usr/bin/codesign --verify --deep --strict "$APP_FRAMEWORKS/Sparkle.framework" 2>/dev/null; then
      echo "FAIL: signature verification failed for Sparkle.framework" >&2
      errors=$((errors + 1))
    fi
  fi

  if [[ "$errors" -gt 0 ]]; then
    echo "App bundle verification failed with $errors error(s)." >&2
    exit 3
  fi
}

verify_app_bundle

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
    sleep 2
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      echo "FAIL: $APP_NAME did not stay running after launch." >&2
      echo "Check Console.app or 'log show --last 10s' for crash details." >&2
      exit 4
    fi
    echo "OK: $APP_NAME is running (pid $(pgrep -x "$APP_NAME"))."
    ;;
  *)
    echo "usage: $0 [bundle|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
