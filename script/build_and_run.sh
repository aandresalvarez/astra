#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="ASTRA"
TOOL_PRODUCTS=("astra-browser" "astra-mcp-gateway" "astra-host-control" "astra-run-broker" "astra-run-supervisor" "astra-workspace" "stanford-mail" "stanford-apple-mail" "stanford-graph-mail")
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
SIGN_IDENTITY_RAW="${ASTRA_SIGN_IDENTITY:-}"
# Trim leading/trailing whitespace (including a leading/trailing newline from
# copy-pasting into the GitHub secret field). codesign matches -s against the
# certificate's common name as a literal substring, so stray whitespace turns
# an otherwise-correct identity into a silent "no identity found" -- live CI
# run 28916225382 proved the identity was present, valid, and unlocked in the
# keychain (security find-identity found it cleanly) while codesign's own
# lookup using the raw secret still failed. Trimmed as one whole string via
# bash pattern matching, not line-by-line: sed processes input line by line,
# so a leading blank line (e.g. a secret starting with "\n...") would keep
# that embedded newline in the result even after trimming each line's own
# whitespace.
SIGN_IDENTITY="${SIGN_IDENTITY_RAW#"${SIGN_IDENTITY_RAW%%[![:space:]]*}"}"
SIGN_IDENTITY="${SIGN_IDENTITY%"${SIGN_IDENTITY##*[![:space:]]}"}"

latest_release_tag() {
  # `git tag --list` uses shell globs, not a strict regex -- the trailing
  # `*` in each `[0-9]*` swallows any suffix, so this glob also matches a
  # non-release tag like v0.1.29-alpha or v0.1.28-beta1 (PR #253 review
  # comment 3549627103). Since the result feeds APP_VERSION into
  # default_app_build() below, which only accepts exact digit-only
  # components, a suffixed tag would make a normal local dev build abort
  # instead of silently skipping it and picking the true latest exact
  # release. Filter to the strict vX.Y.Z shape with the same glob-then-grep
  # approach release.yml's "Determine release version and build" step
  # already uses for its own HIGHEST_TAG guard, so a local build and the
  # release workflow agree on what counts as "the latest release tag".
  git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=v:refname 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n 1 || true
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

# Build number is derived PURELY from the version's own MAJOR.MINOR.PATCH
# components -- never from counting or ranking existing git tags. See
# .github/workflows/release.yml's "Determine release version and build" step
# for the full rationale (tag-count/rank schemes aren't append-only: deleting
# an old tag shifts the count for every later release, which can collide two
# different versions onto the same Sparkle CFBundleVersion). This must
# exactly match that formula so a local/dev build of a given version number
# lands on the same build number a real release would use for it.
#   BUILD = MAJOR*1,000,000 + MINOR*10,000 + PATCH
# This flat, non-dotted integer is intentionally kept as the CFBundleVersion
# shape (not switched to a dotted MAJOR.MINOR.PATCH string): Apple's current
# CFBundleVersion documentation describes the key as "one to three
# period-separated integers" and explicitly treats a bare single integer as
# shorthand for [N].0.0, so a flat integer is a legal, documented
# CFBundleVersion value for this project's notarized-direct-download +
# Sparkle distribution model (it does not go through App Store Connect,
# whose stricter three-component/first-component-<=4-digit rule is a
# separate, submission-specific constraint). This is also empirically
# confirmed: the already-published v0.1.25-v0.1.28 releases shipped
# flat-integer CFBundleVersion values (25, 26, 3, 4) and were signed,
# notarized, and published without rejection. See release.yml's "Determine
# release version and build" step and PR #253 review comment 3549454188 for
# the full research.
#
# Headroom before a digit-group overflows into the next -- MINOR up to 99,
# PATCH up to 9999 -- is enforced BELOW, before packing, not just documented:
# without it, the packing is not one-to-one (two different version strings
# can produce the same BUILD), e.g. "0.01.08" and "0.1.8" both pack to
# 10008 (leading zero), "0.1.10000" and "0.2.0" both pack to 20000 (PATCH
# overflowing into MINOR), and "0.100.0" and "1.0.0" both pack to 1000000
# (MINOR overflowing into MAJOR). MAJOR is bounded to <=999 as a sanity
# ceiling (nothing packs on top of it, so it can't collide, but an unbounded
# MAJOR could still grow the build number past what's sane to
# compare/represent). Current tags top out at v0.1.28, so these bounds leave
# enormous headroom for this project's cadence.
default_app_build() {
  local version="$1"
  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Cannot derive a default build number from version '$version': expected X.Y.Z." >&2
    exit 2
  fi
  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[2]}"
  local patch="${BASH_REMATCH[3]}"
  local component_name component_value
  # Canonical-form validation: reject leading zeros (e.g. "01", "08") so two
  # textually different version strings can never parse to the same integer
  # for a component.
  for component_name in major minor patch; do
    component_value="${!component_name}"
    if [[ ! "$component_value" =~ ^(0|[1-9][0-9]*)$ ]]; then
      echo "Cannot derive a default build number from version '$version': component '$component_name' ('$component_value') has a leading zero (use '1', not '01')." >&2
      exit 2
    fi
  done
  # Length validation FIRST, using pure string-length comparison -- BEFORE
  # any arithmetic ever touches these values (PR #253 review comment
  # 3549627096, mirrored from release.yml's identical bounds checks, which
  # this function must stay in sync with). The canonical-form regex above
  # accepts a string of digits of any length (e.g. a component with 50
  # digits), and bash's `((...))` arithmetic is bounded 64-bit signed:
  # evaluating `10#$major > 999` on a value that long overflows, and an
  # overflowed comparison can't be trusted to reject it -- letting an
  # absurdly long component sneak past the intended bound and then ALSO
  # misbehave when the build number is packed below. `${#var}` is a
  # string-length operation, not arithmetic on the numeric value, so it
  # cannot overflow no matter how long the component is. Each bound's
  # digit-count limit is exactly the count of digits its own numeric limit
  # has (999 -> 3, 99 -> 2, 9999 -> 4); combined with the canonical-form
  # check above (no leading zeros), a component within its digit-count
  # limit is *guaranteed* within its numeric limit too, so only after this
  # passes is it safe to also do the numeric bound check below.
  if [[ ${#major} -gt 3 ]]; then
    echo "Cannot derive a default build number from version '$version': MAJOR ($major) has too many digits (must be <=999, i.e. at most 3 digits)." >&2
    exit 2
  fi
  if [[ ${#minor} -gt 2 ]]; then
    echo "Cannot derive a default build number from version '$version': MINOR ($minor) has too many digits (must be <=99, i.e. at most 2 digits) -- a longer value would overflow into the MAJOR digit-group and could collide with a different version." >&2
    exit 2
  fi
  if [[ ${#patch} -gt 4 ]]; then
    echo "Cannot derive a default build number from version '$version': PATCH ($patch) has too many digits (must be <=9999, i.e. at most 4 digits) -- a longer value would overflow into the MINOR digit-group and could collide with a different version." >&2
    exit 2
  fi
  # Component-bound validation: reject values that would overflow into a
  # neighboring digit-group of the packed build number. Safe from
  # arithmetic overflow now -- the length checks above already guarantee
  # each component is at most a handful of digits.
  if (( 10#$major > 999 )); then
    echo "Cannot derive a default build number from version '$version': MAJOR ($major) must be <=999." >&2
    exit 2
  fi
  if (( 10#$minor > 99 )); then
    echo "Cannot derive a default build number from version '$version': MINOR ($minor) must be <=99 -- a larger value would overflow into the MAJOR digit-group and could collide with a different version." >&2
    exit 2
  fi
  if (( 10#$patch > 9999 )); then
    echo "Cannot derive a default build number from version '$version': PATCH ($patch) must be <=9999 -- a larger value would overflow into the MINOR digit-group and could collide with a different version." >&2
    exit 2
  fi
  # 10#$x forces base-10 interpretation in arithmetic context: a component
  # with a leading zero (e.g. "08") would otherwise be parsed as an invalid
  # octal literal and abort the run. (The canonical-form check above already
  # rejects genuine leading zeros; this stays as defense in depth.)
  printf '%s\n' "$((10#$major * 1000000 + 10#$minor * 10000 + 10#$patch))"
}

APP_VERSION="${ASTRA_VERSION:-$(default_app_version)}"
APP_BUILD="${ASTRA_BUILD:-$(default_app_build "$APP_VERSION")}"
ASTRA_GIT_COMMIT="${ASTRA_GIT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
ASTRA_BUILD_DATE="${ASTRA_BUILD_DATE:-$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')}"
ASTRA_SCHEMA_VERSION="$(/usr/bin/sed -n 's/.*public static let currentVersion = \([0-9][0-9]*\).*/\1/p' "$ROOT_DIR/Astra/Models/CurrentSchema.swift" | /usr/bin/tail -n 1)"
if [[ ! "$ASTRA_SCHEMA_VERSION" =~ ^[0-9]+$ ]]; then
  echo "Unable to derive ASTRA schema version from CurrentSchema.swift." >&2
  exit 2
fi

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

find_local_team_signing_identity() {
  local identities candidate
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  candidate="$(printf '%s\n' "$identities" | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | /usr/bin/head -n 1)"
  if [[ -z "$candidate" ]]; then
    candidate="$(printf '%s\n' "$identities" | /usr/bin/sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | /usr/bin/head -n 1)"
  fi
  printf '%s\n' "$candidate"
}

case "$ASTRA_CHANNEL" in
  prod|production)
    ASTRA_CHANNEL="prod"
    LINKED_CHANNEL_SWIFT_CONDITION="ASTRA_LINKED_CHANNEL_PROD"
    APP_NAME="ASTRA"
    BUNDLE_ID="com.coral.ASTRA"
    URL_SCHEME="astra"
    DEFAULT_SPARKLE_FEED_URL="https://github.com/aandresalvarez/astra/releases/latest/download/appcast.xml"
    ;;
  dev|development)
    ASTRA_CHANNEL="dev"
    LINKED_CHANNEL_SWIFT_CONDITION="ASTRA_LINKED_CHANNEL_DEV"
    APP_NAME="ASTRA Dev"
    BUNDLE_ID="com.coral.ASTRA.dev"
    URL_SCHEME="astra-dev"
    DEFAULT_SPARKLE_FEED_URL=""
    ;;
  beta)
    LINKED_CHANNEL_SWIFT_CONDITION="ASTRA_LINKED_CHANNEL_BETA"
    APP_NAME="ASTRA Beta"
    BUNDLE_ID="com.coral.ASTRA.beta"
    URL_SCHEME="astra-beta"
    DEFAULT_SPARKLE_FEED_URL="https://github.com/aandresalvarez/astra/releases/latest/download/appcast-beta.xml"
    ;;
  *)
    echo "Unknown ASTRA_CHANNEL '$ASTRA_CHANNEL'. Use dev, beta, or prod." >&2
    exit 2
    ;;
esac

# Local run/verify builds prefer an available Apple team identity so AppKit's
# automatic App Intents registration has the validated bundle identity macOS
# requires. Packaging mode remains deterministic: internal releases stay
# ad-hoc unless an identity is explicitly supplied by the release workflow.
if [[ -n "${ASTRA_AUTO_TEAM_SIGNING:-}" ]]; then
  AUTO_TEAM_SIGNING="$ASTRA_AUTO_TEAM_SIGNING"
elif [[ "$MODE" == "bundle" ]]; then
  AUTO_TEAM_SIGNING=0
else
  AUTO_TEAM_SIGNING=1
fi
if [[ "$AUTO_TEAM_SIGNING" != "0" && "$AUTO_TEAM_SIGNING" != "1" ]]; then
  echo "Invalid ASTRA_AUTO_TEAM_SIGNING '$AUTO_TEAM_SIGNING'. Use 0 or 1." >&2
  exit 2
fi
if [[ -z "$SIGN_IDENTITY" && "$AUTO_TEAM_SIGNING" == "1" ]]; then
  SIGN_IDENTITY="$(find_local_team_signing_identity)"
  if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "  signing local $ASTRA_CHANNEL build with team identity '$SIGN_IDENTITY'"
  fi
fi

# `linkd` accepts App Intents only from a validated bundle identity with a
# signing Team ID. Ad-hoc apps can never satisfy that contract, so do not
# compile an integration into them that the system cannot make available.
# Developer-ID production/beta builds enable the integration by default. An
# explicit override remains available, but enabling it without a signing
# identity is rejected before compiling and the finished bundle's Team ID is
# verified below.
APP_INTENTS_REQUEST="${ASTRA_ENABLE_APP_INTENTS:-auto}"
case "$APP_INTENTS_REQUEST" in
  auto)
    if [[ -n "$SIGN_IDENTITY" ]]; then
      APP_INTENTS_ENABLED=1
    else
      APP_INTENTS_ENABLED=0
    fi
    ;;
  0|1)
    APP_INTENTS_ENABLED="$APP_INTENTS_REQUEST"
    ;;
  *)
    echo "Invalid ASTRA_ENABLE_APP_INTENTS '$APP_INTENTS_REQUEST'. Use 0 or 1." >&2
    exit 2
    ;;
esac
if [[ "$APP_INTENTS_ENABLED" == "1" && -z "$SIGN_IDENTITY" ]]; then
  echo "ASTRA_ENABLE_APP_INTENTS=1 requires ASTRA_SIGN_IDENTITY with a valid Team ID." >&2
  exit 2
fi
if [[ "$APP_INTENTS_ENABLED" == "1" ]]; then
  APP_INTENTS_PLIST_VALUE="<true/>"
else
  APP_INTENTS_PLIST_VALUE="<false/>"
fi

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

stop_existing_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  local attempts=0
  while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 50 ]]; then
      echo "FAIL: $APP_NAME did not exit before bundle replacement; refusing to stage over a running app." >&2
      exit 4
    fi
    sleep 0.1
  done
}

if [[ "$REQUIRE_ARM64" == "1" ]]; then
  HOST_ARCH="$(/usr/bin/uname -m)"
  if [[ "$HOST_ARCH" != "arm64" ]]; then
    echo "ASTRA is Apple-Silicon-only; run this script from a native arm64 shell on Apple Silicon." >&2
    echo "Current process architecture: $HOST_ARCH" >&2
    exit 2
  fi
fi

SWIFT_BUILD_ARGS=(--package-path "$ROOT_DIR")
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  SWIFT_BUILD_ARGS=(-c release "${SWIFT_BUILD_ARGS[@]}")
fi
SWIFT_BUILD_ARGS+=(-Xswiftc "-D$LINKED_CHANNEL_SWIFT_CONDITION")
if [[ "$APP_INTENTS_ENABLED" == "1" ]]; then
  SWIFT_BUILD_ARGS+=(-Xswiftc -DASTRA_ENABLE_APP_INTENTS)
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

stop_existing_app

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
RUN_BROKER_PAYLOAD_SCHEMA_VERSION=2
RUN_BROKER_EXECUTABLE_NAME="astra-run-broker"
RUN_BROKER_EXECUTABLE="$BUNDLED_TOOLS_DIR/$RUN_BROKER_EXECUTABLE_NAME"
RUN_SUPERVISOR_EXECUTABLE_NAME="astra-run-supervisor"
RUN_SUPERVISOR_EXECUTABLE="$BUNDLED_TOOLS_DIR/$RUN_SUPERVISOR_EXECUTABLE_NAME"

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
  <key>ASTRALinkedChannel</key>
  <string>$ASTRA_CHANNEL</string>
  <key>ASTRAAppIntentsEnabled</key>
  $APP_INTENTS_PLIST_VALUE
  <key>ASTRAGitCommit</key>
  <string>$ASTRA_GIT_COMMIT</string>
  <key>ASTRABuildDate</key>
  <string>$ASTRA_BUILD_DATE</string>
  <key>ASTRASchemaVersion</key>
  <integer>$ASTRA_SCHEMA_VERSION</integer>
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

# In CI the identity lives in a non-default temporary keychain
# ($ASTRA_RELEASE_KEYCHAIN, set by release.yml's cert-import step via
# $GITHUB_ENV). Relying on the ambient keychain search list to find it is
# fragile across a long-running job -- confirmed live in CI (run
# 28913131937): the identity was importable and verifiable right after
# import, but codesign reported "no identity found" for it ~14 minutes
# later once the actual signing step ran, well past the keychain's normal
# lock timeout window. Passing --keychain explicitly removes the ambiguity
# entirely instead of debugging search-list persistence across steps.
SIGN_KEYCHAIN_ARGS=()
if [[ -n "${ASTRA_RELEASE_KEYCHAIN:-}" ]]; then
  SIGN_KEYCHAIN_ARGS=(--keychain "$ASTRA_RELEASE_KEYCHAIN")
fi

sign_developer_id() {
  local target="$1"
  # ${arr[@]+"${arr[@]}"}, not "${arr[@]}" directly: under `set -u`, macOS's
  # default /bin/bash (3.2, frozen at GPLv2) treats an *empty* array's [@]
  # expansion as an unbound-variable error -- a bug fixed in bash 4.4+, but
  # GitHub Actions runners have a modern bash first in PATH so this never
  # surfaced in CI. Confirmed live: this exact line broke a local
  # developer-id test run on stock /bin/bash before this fix.
  /usr/bin/codesign --force --timestamp --options runtime "${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"}" --sign "$SIGN_IDENTITY" "$target"
}

sign_local_identity() {
  local target="$1"
  /usr/bin/codesign --force "${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"}" --sign "$SIGN_IDENTITY" "$target"
}

sign_ad_hoc() {
  local target="$1"
  /usr/bin/codesign --force --sign - "$target"
}

sign_bundled_tools_with() {
  local signer="$1"
  local tool_product
  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    "$signer" "$BUNDLED_TOOLS_DIR/$tool_product"
  done
}

sign_sparkle_framework_with() {
  local signer="$1"
  local framework="$APP_FRAMEWORKS/Sparkle.framework"
  [[ -d "$framework" ]] || return 0
  # Sign inside-out: Sparkle's own XPC services / helper app / Autoupdate tool
  # first, then the framework. The supplied signer preserves the active mode's
  # Developer-ID, local-identity, or ad-hoc semantics.
  local nested
  while IFS= read -r -d '' nested; do
    "$signer" "$nested"
  done < <(find "$framework" \( -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null)
  local autoupdate
  autoupdate="$(find "$framework" -type f -name "Autoupdate" -print 2>/dev/null | head -n 1 || true)"
  [[ -n "$autoupdate" ]] && "$signer" "$autoupdate"
  "$signer" "$framework"
}

finalize_run_broker_payload_metadata() {
  if [[ ! -x "$RUN_BROKER_EXECUTABLE" || ! -x "$RUN_SUPERVISOR_EXECUTABLE" ]]; then
    echo "FAIL: RunBroker cohort is incomplete before metadata finalization." >&2
    exit 3
  fi
  # The digest is intentionally computed only after the nested executable has
  # its final signature. codesign mutates Mach-O bytes, so hashing the stripped
  # but unsigned SwiftPM artifact would publish a contract no installer could
  # satisfy. The outer app signature added below seals this metadata without
  # touching the nested broker again.
  /usr/bin/codesign --verify --strict "$RUN_BROKER_EXECUTABLE"
  /usr/bin/codesign --verify --strict "$RUN_SUPERVISOR_EXECUTABLE"
  local broker_digest supervisor_digest cohort_digest payload_version
  broker_digest="$(/usr/bin/shasum -a 256 "$RUN_BROKER_EXECUTABLE" | /usr/bin/awk '{print $1}')"
  supervisor_digest="$(/usr/bin/shasum -a 256 "$RUN_SUPERVISOR_EXECUTABLE" | /usr/bin/awk '{print $1}')"
  cohort_digest="$(/usr/bin/printf 'astra.run-broker.cohort.v1\0%s\0%s\0%s\0%s' \
    "$RUN_BROKER_EXECUTABLE_NAME" "$broker_digest" \
    "$RUN_SUPERVISOR_EXECUTABLE_NAME" "$supervisor_digest" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  if [[ ! "$broker_digest" =~ ^[0-9a-f]{64}$ ||
        ! "$supervisor_digest" =~ ^[0-9a-f]{64}$ ||
        ! "$cohort_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: unable to derive RunBroker cohort SHA-256 metadata." >&2
    exit 3
  fi
  # A 128-bit digest prefix prevents different local/dev payload bytes with
  # the same app version/build from colliding in the immutable Versions store.
  payload_version="${APP_VERSION}-${APP_BUILD}-${cohort_digest:0:32}"
  if [[ ${#payload_version} -gt 128 || ! "$payload_version" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "FAIL: invalid derived RunBroker payload version '$payload_version'." >&2
    exit 3
  fi
  /usr/libexec/PlistBuddy -c "Add :ASTRARunBrokerPayloadSchemaVersion integer $RUN_BROKER_PAYLOAD_SCHEMA_VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunBrokerPayloadVersion string $payload_version" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunBrokerPayloadSHA256 string $broker_digest" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunBrokerPayloadExecutable string $RUN_BROKER_EXECUTABLE_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunSupervisorPayloadSHA256 string $supervisor_digest" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunSupervisorPayloadExecutable string $RUN_SUPERVISOR_EXECUTABLE_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ASTRARunBrokerCohortSHA256 string $cohort_digest" "$INFO_PLIST"
}

if [[ -n "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" != "dev" ]]; then
  # A prior CI run signed successfully right after cert import, then failed
  # with "no identity found" ~14 minutes later at this exact point with no
  # code change in between. Defensively re-unlock the CI temp keychain right
  # before it's actually needed, in case whatever caused that (auto-lock,
  # runner session change) recurs -- cheap and harmless when it's already
  # unlocked. This keychain's password is a fixed, non-secret literal (see
  # release.yml's import step for why); must match it exactly.
  if [[ -n "${ASTRA_RELEASE_KEYCHAIN:-}" ]]; then
    security unlock-keychain -p "astra-release-ci-ephemeral-keychain" "$ASTRA_RELEASE_KEYCHAIN" 2>&1 || true
  fi
  # Diagnostic only -- not a functional dependency. Makes the live keychain
  # state at sign-time visible in the log instead of guessing blind if the
  # failure above recurs despite the re-unlock. Written to stderr, not
  # stdout: release_update.sh invokes this script with stdout redirected to
  # /dev/null, so a stdout-only diagnostic here would never actually reach
  # the CI job log where it's needed (caught by review before it shipped).
  if [[ -n "${ASTRA_RELEASE_KEYCHAIN:-}" ]]; then
    {
      echo "  [diagnostic] ASTRA_SIGN_IDENTITY length: raw=${#SIGN_IDENTITY_RAW} trimmed=${#SIGN_IDENTITY} (lengths only, never the value)"
      echo "  [diagnostic] identities visible in \$ASTRA_RELEASE_KEYCHAIN at sign-time:"
      security find-identity -v -p codesigning "$ASTRA_RELEASE_KEYCHAIN" 2>&1 | sed 's/^/    /'
      echo "  [diagnostic] keychain-list membership check:"
      security show-keychain-info "$ASTRA_RELEASE_KEYCHAIN" 2>&1 | sed 's/^/    /'
      security list-keychains -d user 2>&1 | sed 's/^/    /'
    } >&2 || true
  fi
  # Distributed channels (prod/beta): sign inside-out with hardened runtime +
  # secure timestamp so the bundle can be notarized. Deliberately NOT --deep
  # here: --deep stamps this app's own entitlements onto every nested Mach-O,
  # including Sparkle's XPC services and helper app, which invalidates their
  # own signatures. Nested code must be signed first, then the outer bundle.
  sign_bundled_tools_with sign_developer_id
  sign_sparkle_framework_with sign_developer_id
elif [[ -n "$SIGN_IDENTITY" ]]; then
  # Dev: stable identity but NO hardened runtime/timestamp. Those are only needed
  # for notarization and would change local runtime behavior vs the ad-hoc build
  # (hardened runtime enables library validation against the bundled tools/helper).
  sign_bundled_tools_with sign_local_identity
  sign_sparkle_framework_with sign_local_identity
else
  sign_bundled_tools_with sign_ad_hoc
  sign_sparkle_framework_with sign_ad_hoc
fi

finalize_run_broker_payload_metadata

generate_run_broker_successor_manifest() {
  local signer="${ASTRA_SPARKLE_SIGN_UPDATE:-}"
  if [[ -z "$signer" ]]; then
    return
  fi
  if [[ ! -x "$signer" ]]; then
    echo "FAIL: ASTRA_SPARKLE_SIGN_UPDATE is not executable: $signer" >&2
    exit 3
  fi
  if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "FAIL: signed successor manifest requires ASTRA_SPARKLE_PUBLIC_ED_KEY." >&2
    exit 3
  fi

  local unsigned_copy executable_digest broker_digest supervisor_digest manifest signature
  unsigned_copy="$(mktemp)"
  /usr/bin/ditto "$APP_BINARY" "$unsigned_copy"
  /usr/bin/codesign --remove-signature "$unsigned_copy"
  executable_digest="$(/usr/bin/shasum -a 256 "$unsigned_copy" | /usr/bin/awk '{print $1}')"
  /bin/rm -f "$unsigned_copy"
  broker_digest="$(/usr/bin/shasum -a 256 "$RUN_BROKER_EXECUTABLE" | /usr/bin/awk '{print $1}')"
  supervisor_digest="$(/usr/bin/shasum -a 256 "$RUN_SUPERVISOR_EXECUTABLE" | /usr/bin/awk '{print $1}')"
  manifest="$APP_RESOURCES/RunBrokerSuccessorManifest.json"
  /usr/bin/printf '{"brokerSHA256":"%s","build":"%s","bundleIdentifier":"%s","channel":"%s","executableSHA256":"%s","schemaVersion":1,"supervisorSHA256":"%s","version":"%s"}' \
    "$broker_digest" "$APP_BUILD" "$BUNDLE_ID" "$ASTRA_CHANNEL" "$executable_digest" \
    "$supervisor_digest" "$APP_VERSION" > "$manifest"
  signature="$($signer -p "$manifest")"
  if [[ -z "$signature" ]]; then
    echo "FAIL: Sparkle sign_update returned an empty successor signature." >&2
    exit 3
  fi
  /usr/bin/printf '%s' "$signature" | /usr/bin/base64 -D \
    > "$APP_RESOURCES/RunBrokerSuccessorManifest.sig"
  if [[ "$(/usr/bin/wc -c < "$APP_RESOURCES/RunBrokerSuccessorManifest.sig" | /usr/bin/tr -d ' ')" != "64" ]]; then
    echo "FAIL: successor manifest signature is not 64 bytes." >&2
    exit 3
  fi
}

generate_run_broker_successor_manifest

# Sign only the outer app after finalizing payload metadata. Every nested code
# object is already signed for the active mode above; omitting --deep here is
# what guarantees the broker bytes hashed into Info.plist remain unchanged.
if [[ -n "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" != "dev" ]]; then
  /usr/bin/codesign --force --timestamp --options runtime "${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
elif [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force "${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"}" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  /usr/bin/codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
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

  if ! /usr/bin/strings "$APP_BINARY" | /usr/bin/grep -F "astra-linked-channel:$ASTRA_CHANNEL" >/dev/null; then
    echo "FAIL: executable is missing its linked $ASTRA_CHANNEL channel identity." >&2
    errors=$((errors + 1))
  fi

  if ! /usr/bin/strings "$APP_BINARY" | /usr/bin/grep -F "astra-app-intents:$([[ "$APP_INTENTS_ENABLED" == "1" ]] && echo enabled || echo disabled)" >/dev/null; then
    echo "FAIL: executable App Intents capability does not match the packaging decision." >&2
    errors=$((errors + 1))
  fi

  if [[ "$APP_INTENTS_ENABLED" == "1" ]]; then
    local signature_details team_identifier
    signature_details="$(/usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1 || true)"
    team_identifier="$(printf '%s\n' "$signature_details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
    if [[ -z "$team_identifier" || "$team_identifier" == "not set" ]]; then
      echo "FAIL: App Intents require a signed bundle with a TeamIdentifier; this signature has none." >&2
      errors=$((errors + 1))
    fi
  fi

  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    if [[ ! -x "$BUNDLED_TOOLS_DIR/$tool_product" ]]; then
      echo "FAIL: bundled tool missing: $BUNDLED_TOOLS_DIR/$tool_product" >&2
      errors=$((errors + 1))
    fi
  done

  local metadata_schema metadata_version metadata_sha metadata_executable
  local metadata_supervisor_sha metadata_supervisor_executable metadata_cohort_sha
  local actual_broker_sha actual_supervisor_sha actual_cohort_sha expected_payload_version
  metadata_schema="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunBrokerPayloadSchemaVersion' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_version="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunBrokerPayloadVersion' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_sha="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunBrokerPayloadSHA256' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_executable="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunBrokerPayloadExecutable' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_supervisor_sha="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunSupervisorPayloadSHA256' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_supervisor_executable="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunSupervisorPayloadExecutable' "$INFO_PLIST" 2>/dev/null || true)"
  metadata_cohort_sha="$(/usr/libexec/PlistBuddy -c 'Print :ASTRARunBrokerCohortSHA256' "$INFO_PLIST" 2>/dev/null || true)"
  actual_broker_sha="$(/usr/bin/shasum -a 256 "$RUN_BROKER_EXECUTABLE" 2>/dev/null | /usr/bin/awk '{print $1}')"
  actual_supervisor_sha="$(/usr/bin/shasum -a 256 "$RUN_SUPERVISOR_EXECUTABLE" 2>/dev/null | /usr/bin/awk '{print $1}')"
  actual_cohort_sha="$(/usr/bin/printf 'astra.run-broker.cohort.v1\0%s\0%s\0%s\0%s' \
    "$RUN_BROKER_EXECUTABLE_NAME" "$actual_broker_sha" \
    "$RUN_SUPERVISOR_EXECUTABLE_NAME" "$actual_supervisor_sha" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  expected_payload_version="${APP_VERSION}-${APP_BUILD}-${actual_cohort_sha:0:32}"
  if [[ "$metadata_schema" != "$RUN_BROKER_PAYLOAD_SCHEMA_VERSION" ||
        "$metadata_executable" != "$RUN_BROKER_EXECUTABLE_NAME" ||
        "$metadata_sha" != "$actual_broker_sha" ||
        "$metadata_supervisor_executable" != "$RUN_SUPERVISOR_EXECUTABLE_NAME" ||
        "$metadata_supervisor_sha" != "$actual_supervisor_sha" ||
        "$metadata_cohort_sha" != "$actual_cohort_sha" ||
        "$metadata_version" != "$expected_payload_version" ]]; then
    echo "FAIL: signed RunBroker cohort metadata does not match the final bundled executables." >&2
    errors=$((errors + 1))
  fi
  if ! /usr/bin/codesign --verify --strict "$RUN_BROKER_EXECUTABLE" 2>/dev/null; then
    echo "FAIL: final bundled RunBroker payload signature is invalid." >&2
    errors=$((errors + 1))
  fi
  if ! /usr/bin/codesign --verify --strict "$RUN_SUPERVISOR_EXECUTABLE" 2>/dev/null; then
    echo "FAIL: final bundled RunSupervisor cohort signature is invalid." >&2
    errors=$((errors + 1))
  fi

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
  stop_existing_app
  /usr/bin/open "$APP_BUNDLE"
}

verify_single_launched_app() {
  local pids
  pids="$(pgrep -x "$APP_NAME" || true)"
  local count
  count="$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$count" != "1" ]]; then
    echo "FAIL: expected exactly one $APP_NAME process after launch; found $count." >&2
    exit 4
  fi
  local pid
  pid="$(printf '%s\n' "$pids" | awk 'NF { print; exit }')"
  local command
  command="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//')"
  if [[ "$command" != "$APP_BINARY"* ]]; then
    echo "FAIL: $APP_NAME launched from an unexpected bundle: $command" >&2
    exit 4
  fi
  echo "OK: $APP_NAME is running (pid $pid)."
}

case "$MODE" in
  bundle|--bundle)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    stop_existing_app
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
    verify_single_launched_app
    ;;
  *)
    echo "usage: $0 [bundle|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
