#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_PATH="${HOME}/.astra/tools/astra-local-model"
MODEL_DIR="${HOME}/Library/Application Support/AstraDev/LocalModels/Qwen3-4B-MLX-4bit"
OUTPUT_PATH="/tmp/astra-local-mlx-release-evidence.json"
BETA_OUTPUT_PATH="/tmp/astra-local-agent-beta-soak-evidence.json"
BUILD_ID="${ASTRA_LOCAL_MLX_RELEASE_BUILD_ID:-}"
INCLUDE_HIGH_RISK=0
DRY_RUN=0

validate_model_assets() {
  local model_dir="$1"
  if [[ ! -f "$model_dir/config.json" ]]; then
    echo "Local MLX model folder is missing config.json: $model_dir" >&2
    return 1
  fi
  if [[ ! -f "$model_dir/tokenizer.json" && ! -f "$model_dir/tokenizer.model" ]]; then
    echo "Local MLX model folder is missing tokenizer.json or tokenizer.model: $model_dir" >&2
    return 1
  fi
  if ! find "$model_dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.bin" \) -size +0c -print -quit | grep -q .; then
    echo "Local MLX model folder is missing non-empty model weights (.safetensors or .bin): $model_dir" >&2
    return 1
  fi
}

usage() {
  cat <<'USAGE'
Usage: script/local_mlx_collect_release_evidence.sh [options]

Collect build-bound Local MLX release-candidate evidence for this Mac.

Options:
  --build-id ID      required release build id, usually ASTRA_VERSION+ASTRA_BUILD
  --helper PATH      astra-local-model helper path
  --model-dir PATH   installed Qwen MLX model folder
  --out PATH         release evidence output JSON path
  --beta-out PATH    beta-soak evidence output JSON path
  --include-high-risk-tools
                    also collect opt-in high-risk Local Agent beta evidence
  --dry-run          print collection settings without running Local MLX tests
  -h, --help         show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-id)
      BUILD_ID="${2:?missing --build-id value}"
      shift 2
      ;;
    --helper)
      HELPER_PATH="${2:?missing --helper value}"
      shift 2
      ;;
    --model-dir)
      MODEL_DIR="${2:?missing --model-dir value}"
      shift 2
      ;;
    --out)
      OUTPUT_PATH="${2:?missing --out value}"
      shift 2
      ;;
    --beta-out)
      BETA_OUTPUT_PATH="${2:?missing --beta-out value}"
      shift 2
      ;;
    --include-high-risk-tools)
      INCLUDE_HIGH_RISK=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

BUILD_ID="$(printf '%s' "$BUILD_ID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$BUILD_ID" && -n "${ASTRA_VERSION:-}" && -n "${ASTRA_BUILD:-}" ]]; then
  BUILD_ID="${ASTRA_VERSION}+${ASTRA_BUILD}"
fi
if [[ -z "$BUILD_ID" ]]; then
  echo "Missing release build id." >&2
  echo "Pass --build-id, set ASTRA_LOCAL_MLX_RELEASE_BUILD_ID, or set ASTRA_VERSION and ASTRA_BUILD." >&2
  exit 2
fi

if [[ "$OUTPUT_PATH" == "$BETA_OUTPUT_PATH" ]]; then
  echo "--out and --beta-out must be different files because they use different evidence schemas." >&2
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Local MLX release evidence collection dry run"
  echo "Release build id: $BUILD_ID"
  echo "Release evidence output: $OUTPUT_PATH"
  echo "Beta-soak evidence output: $BETA_OUTPUT_PATH"
  echo "Helper path: $HELPER_PATH"
  echo "Model folder: $MODEL_DIR"
  if [[ "$INCLUDE_HIGH_RISK" == "1" ]]; then
    echo "High-risk Local Agent beta tools: included"
    echo "High-risk tests: task.write_output, workspace.write_file, shell.exec, network.fetch, browser.click, browser.type"
  else
    echo "High-risk Local Agent beta tools: not included"
  fi
  echo "Run without --dry-run to collect build-bound release-candidate evidence."
  exit 0
fi

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "Local MLX helper is not executable: $HELPER_PATH" >&2
  echo "Build and install ASTRA Dev first, then retry." >&2
  exit 2
fi

if [[ ! -d "$MODEL_DIR" ]]; then
  echo "Local MLX model folder does not exist: $MODEL_DIR" >&2
  echo "Install Qwen 3 4B from ASTRA Runtime settings first, or pass --model-dir." >&2
  exit 2
fi
validate_model_assets "$MODEL_DIR" || {
  echo "Install Qwen 3 4B from ASTRA Runtime settings first, or pass a complete MLX model folder." >&2
  exit 2
}

mkdir -p "$(dirname "$OUTPUT_PATH")"
mkdir -p "$(dirname "$BETA_OUTPUT_PATH")"
rm -f "$OUTPUT_PATH" "$BETA_OUTPUT_PATH"
cd "$ROOT_DIR"

RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="$BUILD_ID" \
ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT="$OUTPUT_PATH" \
REAL_LOCAL_MLX_HELPER="$HELPER_PATH" \
REAL_LOCAL_MLX_MODEL_DIR="$MODEL_DIR" \
swift test --filter workerTextResponseEndToEnd

RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
RUN_E2E_LOCAL_MLX_AGENT=1 \
ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="$BUILD_ID" \
ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT="$OUTPUT_PATH" \
ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT="$BETA_OUTPUT_PATH" \
REAL_LOCAL_MLX_HELPER="$HELPER_PATH" \
REAL_LOCAL_MLX_MODEL_DIR="$MODEL_DIR" \
swift test --filter localMLXAgentReadOnlyToolLoopEndToEnd

if [[ "$INCLUDE_HIGH_RISK" == "1" ]]; then
  export RUN_E2E=1
  export RUN_E2E_RUNTIME=local_mlx
  export RUN_E2E_LOCAL_MLX_AGENT=1
  export RUN_E2E_LOCAL_MLX_AGENT_HIGH_RISK=1
  export ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="$BUILD_ID"
  export ASTRA_LOCAL_MLX_RELEASE_EVIDENCE_OUT="$OUTPUT_PATH"
  export ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE_OUT="$BETA_OUTPUT_PATH"
  export REAL_LOCAL_MLX_HELPER="$HELPER_PATH"
  export REAL_LOCAL_MLX_MODEL_DIR="$MODEL_DIR"

  swift test --filter localMLXAgentTaskOutputWriteApprovalEndToEnd
  swift test --filter localMLXAgentWorkspaceWriteApprovalEndToEnd
  swift test --filter localMLXAgentShellExecApprovalEndToEnd
  swift test --filter localMLXAgentNetworkFetchApprovalEndToEnd
  swift test --filter localMLXAgentBrowserClickApprovalEndToEnd
  swift test --filter localMLXAgentBrowserTypeApprovalEndToEnd
fi

echo "Local MLX release-candidate evidence written to: $OUTPUT_PATH"
echo "Local Agent beta-soak evidence written to: $BETA_OUTPUT_PATH"
if [[ "$INCLUDE_HIGH_RISK" != "1" ]]; then
  echo "High-risk Local Agent beta evidence was not collected."
  echo "To collect it, rerun with --include-high-risk-tools after confirming scoped approvals are acceptable on this Mac."
fi
echo "Inspect readiness with:"
echo "  script/local_mlx_release_readiness.py --require-complete --require-build-id \"$BUILD_ID\" \\"
echo "    --release-candidate \"$OUTPUT_PATH\" \\"
echo "    --beta-soak \"$BETA_OUTPUT_PATH\" \\"
echo "    --hardware /tmp/astra-local-mlx-hardware-8gb.json \\"
echo "    --hardware /tmp/astra-local-mlx-hardware-16gb.json \\"
echo "    --hardware /tmp/astra-local-mlx-hardware-pro.json \\"
echo "    --hardware /tmp/astra-local-mlx-hardware-max.json"
