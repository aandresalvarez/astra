#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_NAME="ASTRA"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DOWNLOAD_URL_PREFIX="${ASTRA_DOWNLOAD_URL_PREFIX:-https://github.com/susom/astra/releases/latest/download/}"
RELEASE_MODE="${ASTRA_RELEASE_MODE:-internal}"
REQUIRE_LOCAL_MLX_GA_EVIDENCE="${ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE:-0}"
LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY="${ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY:-0}"

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

require_readable_file() {
  local label="$1"
  local path="$2"
  if [[ ! -f "$path" || ! -r "$path" ]]; then
    echo "Local MLX GA evidence file is not readable for $label: $path" >&2
    exit 2
  fi
}

local_mlx_evidence_help() {
  cat >&2 <<'HELP'
Local MLX GA evidence requires either:
  - ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/path/to/astra-local-mlx-validation-bundle.json
  - or separate ASTRA_LOCAL_MLX_RELEASE_EVIDENCE, ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE, and ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES/ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE inputs.

Preview evidence collection before running live tests:
  script/local_mlx_collect_release_evidence.sh --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" --dry-run
  script/local_mlx_collect_hardware_evidence.sh --dry-run
  script/local_mlx_validation_bundle.py --dry-run \
    --release-candidate /tmp/astra-local-mlx-release-evidence.json \
    --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
    --hardware /tmp/astra-local-mlx-hardware-pro.json \
    --out /tmp/astra-local-mlx-validation-bundle.json

When merging existing bundles, write to a new output path first:
  script/local_mlx_validation_bundle.py --dry-run \
    --bundle /tmp/astra-local-mlx-validation-bundle.json \
    --out /tmp/astra-local-mlx-validation-bundle-merged.json
HELP
}

if [[ "$REQUIRE_LOCAL_MLX_GA_EVIDENCE" != "0" && "$REQUIRE_LOCAL_MLX_GA_EVIDENCE" != "1" ]]; then
  echo "Unknown ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE '$REQUIRE_LOCAL_MLX_GA_EVIDENCE'. Use 0 or 1." >&2
  exit 2
fi

if [[ "$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY" != "0" && "$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY" != "1" ]]; then
  echo "Unknown ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY '$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY'. Use 0 or 1." >&2
  exit 2
fi

if [[ "$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY" == "1" && "$REQUIRE_LOCAL_MLX_GA_EVIDENCE" != "1" ]]; then
  echo "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY requires ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1." >&2
  exit 2
fi

if [[ "$REQUIRE_LOCAL_MLX_GA_EVIDENCE" == "1" ]]; then
  if [[ -n "${ASTRA_LOCAL_MLX_RELEASE_BUILD_ID:-}" ]]; then
    LOCAL_MLX_RELEASE_BUILD_ID="$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"
  else
    require_env ASTRA_VERSION
    require_env ASTRA_BUILD
    LOCAL_MLX_RELEASE_BUILD_ID="${ASTRA_VERSION}+${ASTRA_BUILD}"
  fi
  LOCAL_MLX_READINESS_ARGS=(--require-complete --require-clean-evidence --require-build-id "$LOCAL_MLX_RELEASE_BUILD_ID")
  if [[ -n "${ASTRA_LOCAL_MLX_VALIDATION_BUNDLE:-}" ]]; then
    require_readable_file ASTRA_LOCAL_MLX_VALIDATION_BUNDLE "$ASTRA_LOCAL_MLX_VALIDATION_BUNDLE"
    LOCAL_MLX_READINESS_ARGS+=(--bundle "$ASTRA_LOCAL_MLX_VALIDATION_BUNDLE")
  fi
  if [[ -n "${ASTRA_LOCAL_MLX_RELEASE_EVIDENCE:-}" ]]; then
    require_readable_file ASTRA_LOCAL_MLX_RELEASE_EVIDENCE "$ASTRA_LOCAL_MLX_RELEASE_EVIDENCE"
    LOCAL_MLX_READINESS_ARGS+=(--release-candidate "$ASTRA_LOCAL_MLX_RELEASE_EVIDENCE")
  fi
  if [[ -n "${ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE:-}" ]]; then
    require_readable_file ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE "$ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE"
    LOCAL_MLX_READINESS_ARGS+=(--beta-soak "$ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE")
  fi
  if [[ -n "${ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES:-}" ]]; then
    IFS=':' read -r -a LOCAL_MLX_HARDWARE_EVIDENCE_PATHS <<< "$ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES"
    for evidence_path in "${LOCAL_MLX_HARDWARE_EVIDENCE_PATHS[@]}"; do
      if [[ -z "$evidence_path" ]]; then
        echo "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES contains an empty path." >&2
        exit 2
      fi
      require_readable_file ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES "$evidence_path"
      LOCAL_MLX_READINESS_ARGS+=(--hardware "$evidence_path")
    done
  fi
  if [[ -n "${ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE:-}" ]]; then
    require_readable_file ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE "$ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE"
    LOCAL_MLX_READINESS_ARGS+=(--hardware "$ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE")
  fi
  if [[ -z "${ASTRA_LOCAL_MLX_VALIDATION_BUNDLE:-}" ]]; then
    LOCAL_MLX_MISSING_EVIDENCE=()
    if [[ -z "${ASTRA_LOCAL_MLX_RELEASE_EVIDENCE:-}" ]]; then
      LOCAL_MLX_MISSING_EVIDENCE+=(ASTRA_LOCAL_MLX_RELEASE_EVIDENCE)
    fi
    if [[ -z "${ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE:-}" ]]; then
      LOCAL_MLX_MISSING_EVIDENCE+=(ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE)
    fi
    if [[ -z "${ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES:-}" && -z "${ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE:-}" ]]; then
      LOCAL_MLX_MISSING_EVIDENCE+=(ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES or ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE)
    fi
    if [[ "${#LOCAL_MLX_MISSING_EVIDENCE[@]}" -gt 0 ]]; then
      echo "Missing Local MLX GA evidence input(s): ${LOCAL_MLX_MISSING_EVIDENCE[*]}" >&2
      local_mlx_evidence_help
      exit 2
    fi
  fi
  "$ROOT_DIR/script/local_mlx_release_readiness.py" "${LOCAL_MLX_READINESS_ARGS[@]}"
fi

if [[ "$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY" == "1" ]]; then
  echo "Local MLX GA evidence preflight passed."
  exit 0
fi

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
ASTRA_LOCAL_MODEL_BACKEND="${ASTRA_LOCAL_MODEL_BACKEND:-mlx}" \
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
if [[ "$RELEASE_MODE" == "internal" ]]; then
  echo
  echo "Internal release note:"
  echo "  This build is ad-hoc signed and Sparkle-signed, but not Apple notarized."
  echo "  First install may require a manual Gatekeeper approval on each Mac."
fi
