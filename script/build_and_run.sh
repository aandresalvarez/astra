#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="ASTRA"
TOOL_PRODUCTS=("astra-browser" "astra-local-model" "astra-host-control" "astra-workspace" "stanford-mail" "stanford-apple-mail" "stanford-graph-mail")
ASTRA_CHANNEL="${ASTRA_CHANNEL:-dev}"
LOCAL_MODEL_BACKEND="${ASTRA_LOCAL_MODEL_BACKEND:-mlx}"
LOCAL_MODEL_SMOKE_MODEL_DIR="${ASTRA_LOCAL_MODEL_SMOKE_MODEL_DIR:-}"
LOCAL_MODEL_SMOKE_MODEL="${ASTRA_LOCAL_MODEL_SMOKE_MODEL:-Qwen/Qwen3-4B-MLX-4bit}"
LOCAL_MODEL_SMOKE_CONTEXT_TOKENS="${ASTRA_LOCAL_MODEL_SMOKE_CONTEXT_TOKENS:-8192}"
LOCAL_MODEL_COLD_START_MAX_MS="${ASTRA_LOCAL_MODEL_COLD_START_MAX_MS:-0}"
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

case "$LOCAL_MODEL_BACKEND" in
  scaffold|mlx)
    ;;
  *)
    echo "Unknown ASTRA_LOCAL_MODEL_BACKEND '$LOCAL_MODEL_BACKEND'. Use scaffold or mlx." >&2
    exit 2
    ;;
esac

if [[ "$ASTRA_CHANNEL" != "dev" && "$LOCAL_MODEL_BACKEND" == "scaffold" ]]; then
  echo "Production and beta ASTRA bundles must include the native MLX local model helper." >&2
  echo "Use ASTRA_LOCAL_MODEL_BACKEND=mlx. The scaffold helper is only allowed for development-channel builds." >&2
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

NATIVE_LOCAL_MODEL_BINARY=""
NATIVE_LOCAL_MODEL_BUILD_DIR=""

build_native_local_model_metallib() {
  local native_package="$1"
  local mlx_metal_root="$native_package/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
  local air_dir="$NATIVE_LOCAL_MODEL_BUILD_DIR/astra-local-model-metal-air"
  local metal_tool
  local metallib_tool
  local -a metal_sources
  local source_path
  local output_name

  if [[ ! -d "$mlx_metal_root" ]]; then
    echo "Missing MLX generated Metal shader sources at $mlx_metal_root." >&2
    exit 2
  fi

  metal_tool="$(xcrun -sdk macosx -find metal 2>/dev/null || true)"
  metallib_tool="$(xcrun -sdk macosx -find metallib 2>/dev/null || true)"
  if [[ -z "$metal_tool" || -z "$metallib_tool" ]] || ! "$metal_tool" -v >/dev/null 2>&1; then
    echo "Missing Xcode Metal Toolchain required to package the native Local MLX helper." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 2
  fi

  metal_sources=()
  while IFS= read -r source_path; do
    metal_sources+=("$source_path")
  done < <(find "$mlx_metal_root" -name "*.metal" -print | sort)
  if [[ "${#metal_sources[@]}" -eq 0 ]]; then
    echo "No MLX Metal shader sources found under $mlx_metal_root." >&2
    exit 2
  fi

  rm -rf "$air_dir"
  mkdir -p "$air_dir"
  for source_path in "${metal_sources[@]}"; do
    output_name="${source_path#"$mlx_metal_root"/}"
    output_name="${output_name//\//_}"
    output_name="${output_name%.metal}.air"
    "$metal_tool" \
      -x metal \
      -Wall \
      -Wextra \
      -fno-fast-math \
      -Wno-c++17-extensions \
      -Wno-c++20-extensions \
      -c "$source_path" \
      -I"$mlx_metal_root" \
      -o "$air_dir/$output_name"
  done

  "$metallib_tool" "$air_dir"/*.air -o "$NATIVE_LOCAL_MODEL_BUILD_DIR/default.metallib"
  cp "$NATIVE_LOCAL_MODEL_BUILD_DIR/default.metallib" "$NATIVE_LOCAL_MODEL_BUILD_DIR/mlx.metallib"
}

build_native_local_model_helper() {
  local native_package="$ROOT_DIR/Tools/AstraLocalModelNative"
  local native_args=(--package-path "$native_package" --product "astra-local-model-native")
  local native_build_dir

  if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    native_args=(-c release "${native_args[@]}")
  fi

  swift build "${native_args[@]}"
  native_build_dir="$(swift build "${native_args[@]}" --show-bin-path)"
  NATIVE_LOCAL_MODEL_BUILD_DIR="$native_build_dir"
  NATIVE_LOCAL_MODEL_BINARY="$native_build_dir/astra-local-model-native"
  build_native_local_model_metallib "$native_package"
}

tool_binary_path() {
  local tool_product="$1"
  if [[ "$tool_product" == "astra-local-model" && "$LOCAL_MODEL_BACKEND" == "mlx" ]]; then
    printf '%s\n' "$NATIVE_LOCAL_MODEL_BINARY"
  else
    printf '%s\n' "$BUILD_DIR/$tool_product"
  fi
}

swift build "${SWIFT_BUILD_ARGS[@]}"
for tool_product in "${TOOL_PRODUCTS[@]}"; do
  if [[ "$tool_product" == "astra-local-model" && "$LOCAL_MODEL_BACKEND" == "mlx" ]]; then
    continue
  fi
  swift build "${SWIFT_BUILD_ARGS[@]}" --product "$tool_product"
done
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [[ "$LOCAL_MODEL_BACKEND" == "mlx" ]]; then
  build_native_local_model_helper
fi

if [[ "$REQUIRE_ARM64" == "1" ]]; then
  verify_arm64_binary "$BUILD_BINARY"
  for tool_product in "${TOOL_PRODUCTS[@]}"; do
    verify_arm64_binary "$(tool_binary_path "$tool_product")"
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

copy_native_local_model_resources() {
  if [[ "$LOCAL_MODEL_BACKEND" != "mlx" || -z "$NATIVE_LOCAL_MODEL_BUILD_DIR" ]]; then
    return
  fi
  while IFS= read -r resource_path; do
    local resource_name
    resource_name="$(basename "$resource_path")"
    rm -rf "$BUNDLED_TOOLS_DIR/$resource_name"
    /usr/bin/ditto "$resource_path" "$BUNDLED_TOOLS_DIR/$resource_name"
  done < <(find "$NATIVE_LOCAL_MODEL_BUILD_DIR" -maxdepth 1 \( -name "*.bundle" -o -name "*.metallib" \) -print)
}

for tool_product in "${TOOL_PRODUCTS[@]}"; do
  if [[ "$tool_product" == "astra-local-model" && "$LOCAL_MODEL_BACKEND" == "mlx" ]]; then
    cp "$NATIVE_LOCAL_MODEL_BINARY" "$BUNDLED_TOOLS_DIR/$tool_product"
  else
    cp "$BUILD_DIR/$tool_product" "$BUNDLED_TOOLS_DIR/$tool_product"
  fi
  chmod +x "$BUNDLED_TOOLS_DIR/$tool_product"
done
copy_native_local_model_resources

verify_native_local_model_release_gate() {
  if [[ "$LOCAL_MODEL_BACKEND" != "mlx" ]]; then
    return
  fi
  local helper="$BUNDLED_TOOLS_DIR/astra-local-model"
  local health
  if [[ ! -f "$BUNDLED_TOOLS_DIR/default.metallib" || ! -f "$BUNDLED_TOOLS_DIR/mlx.metallib" ]]; then
    echo "Bundled local model helper is missing MLX Metal libraries." >&2
    exit 2
  fi

  health="$("$helper" --health)"
  if [[ "$health" != *'"backend":"mlx"'* ]]; then
    echo "Bundled local model helper did not report the MLX backend." >&2
    echo "$health" >&2
    exit 2
  fi

  if [[ -z "$LOCAL_MODEL_SMOKE_MODEL_DIR" ]]; then
    return
  fi

  local smoke_output
  local cold_start_ms
  smoke_output="$("$helper" --smoke \
    --model-dir "$LOCAL_MODEL_SMOKE_MODEL_DIR" \
    --model "$LOCAL_MODEL_SMOKE_MODEL" \
    --max-context-tokens "$LOCAL_MODEL_SMOKE_CONTEXT_TOKENS" \
    --max-output-tokens 1)"
  printf '%s\n' "$smoke_output" >"$APP_RESOURCES/local-model-cold-start.json"
  cold_start_ms="$(printf '%s\n' "$smoke_output" | /usr/bin/sed -n 's/.*"durationMs":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)"
  if [[ "$LOCAL_MODEL_COLD_START_MAX_MS" =~ ^[0-9]+$ && "$LOCAL_MODEL_COLD_START_MAX_MS" -gt 0 ]]; then
    if [[ -z "$cold_start_ms" ]]; then
      echo "Native local model smoke check did not report durationMs." >&2
      echo "$smoke_output" >&2
      exit 2
    fi
    if [[ "$cold_start_ms" -gt "$LOCAL_MODEL_COLD_START_MAX_MS" ]]; then
      echo "Native local model cold start exceeded gate: ${cold_start_ms}ms > ${LOCAL_MODEL_COLD_START_MAX_MS}ms." >&2
      exit 2
    fi
  fi
}

verify_native_local_model_release_gate

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

if [[ -n "$SIGN_IDENTITY" && "$ASTRA_CHANNEL" != "dev" ]]; then
  # Distributed channels (prod/beta): hardened runtime + secure timestamp so the
  # bundle can be notarized.
  /usr/bin/codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
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
