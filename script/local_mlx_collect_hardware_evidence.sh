#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_PATH="${HOME}/.astra/tools/astra-local-model"
MODEL_DIR="${HOME}/Library/Application Support/AstraDev/LocalModels/Qwen3-4B-MLX-4bit"
OUTPUT_PATH=""
OUTPUT_PATH_EXPLICIT="0"
ITERATIONS="3"
LOW_MEMORY_TIER="0"
EXPECTED_TIER=""
REQUIRED_TIER=""
DRY_RUN="0"
LOW_MEMORY_MODEL_DIR_CLEANUP=""
cleanup_low_memory_model_dir() {
  if [[ -n "$LOW_MEMORY_MODEL_DIR_CLEANUP" ]]; then
    rm -rf "$LOW_MEMORY_MODEL_DIR_CLEANUP"
  fi
}
trap cleanup_low_memory_model_dir EXIT

tier_label() {
  case "$1" in
    low_memory_8gb) printf '8 GB class' ;;
    base_16gb) printf '16 GB base-class' ;;
    pro_32gb_plus) printf '32 GB+ Pro-class' ;;
    max_32gb_plus) printf '32 GB+ Max/Ultra-class' ;;
    *) printf '%s' "$1" ;;
  esac
}

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
Usage: script/local_mlx_collect_hardware_evidence.sh [options]

Collect sustained Local MLX hardware evidence for this Mac.

Options:
  --helper PATH       astra-local-model helper path
  --model-dir PATH    installed Qwen MLX model folder
  --out PATH          evidence output JSON path; defaults to this Mac's Gate D tier file
  --require-tier ID   fail unless this Mac matches the expected Gate D tier
                      IDs: low_memory_8gb, base_16gb, pro_32gb_plus, max_32gb_plus
  --iterations N      repeated validation iterations, default 3
  --dry-run           print detected tier and collection settings without running MLX
  -h, --help          show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
      OUTPUT_PATH_EXPLICIT="1"
      shift 2
      ;;
    --require-tier)
      REQUIRED_TIER="${2:?missing --require-tier value}"
      shift 2
      ;;
    --iterations)
      ITERATIONS="${2:?missing --iterations value}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
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

if [[ ! "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]]; then
  echo "--iterations must be a positive integer" >&2
  exit 2
fi

case "$REQUIRED_TIER" in
  ""|low_memory_8gb|base_16gb|pro_32gb_plus|max_32gb_plus) ;;
  *)
    echo "Unknown --require-tier '$REQUIRED_TIER'. Use low_memory_8gb, base_16gb, pro_32gb_plus, or max_32gb_plus." >&2
    exit 2
    ;;
esac

CPU_BRAND="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'unknown')"
PHYSICAL_MEMORY_BYTES="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || printf '0')"
if [[ "$PHYSICAL_MEMORY_BYTES" =~ ^[0-9]+$ ]] && [[ "$PHYSICAL_MEMORY_BYTES" -gt 0 ]]; then
  LOW_MEMORY_THRESHOLD_BYTES=$((12 * 1024 * 1024 * 1024))
  if [[ "$PHYSICAL_MEMORY_BYTES" -lt "$LOW_MEMORY_THRESHOLD_BYTES" ]]; then
    LOW_MEMORY_TIER="1"
  fi
fi

if [[ "$OUTPUT_PATH_EXPLICIT" != "1" ]]; then
  OUTPUT_PATH="/tmp/astra-local-mlx-hardware-evidence.json"
  if [[ "$PHYSICAL_MEMORY_BYTES" =~ ^[0-9]+$ ]] && [[ "$PHYSICAL_MEMORY_BYTES" -gt 0 ]]; then
    BASE_MEMORY_THRESHOLD_BYTES=$((24 * 1024 * 1024 * 1024))
    if [[ "$LOW_MEMORY_TIER" == "1" ]]; then
      OUTPUT_PATH="/tmp/astra-local-mlx-hardware-8gb.json"
      EXPECTED_TIER="low_memory_8gb"
    elif [[ "$PHYSICAL_MEMORY_BYTES" -lt "$BASE_MEMORY_THRESHOLD_BYTES" ]]; then
      OUTPUT_PATH="/tmp/astra-local-mlx-hardware-16gb.json"
      EXPECTED_TIER="base_16gb"
    elif [[ "$CPU_BRAND" == *"Max"* || "$CPU_BRAND" == *"Ultra"* ]]; then
      OUTPUT_PATH="/tmp/astra-local-mlx-hardware-max.json"
      EXPECTED_TIER="max_32gb_plus"
    elif [[ "$CPU_BRAND" == *"Pro"* ]]; then
      OUTPUT_PATH="/tmp/astra-local-mlx-hardware-pro.json"
      EXPECTED_TIER="pro_32gb_plus"
    else
      OUTPUT_PATH="/tmp/astra-local-mlx-hardware-16gb.json"
      EXPECTED_TIER="base_16gb"
    fi
  fi
fi

if [[ -z "$EXPECTED_TIER" ]]; then
  BASE_MEMORY_THRESHOLD_BYTES=$((24 * 1024 * 1024 * 1024))
  if [[ "$LOW_MEMORY_TIER" == "1" ]]; then
    EXPECTED_TIER="low_memory_8gb"
  elif [[ "$PHYSICAL_MEMORY_BYTES" =~ ^[0-9]+$ && "$PHYSICAL_MEMORY_BYTES" -lt "$BASE_MEMORY_THRESHOLD_BYTES" ]]; then
    EXPECTED_TIER="base_16gb"
  elif [[ "$CPU_BRAND" == *"Max"* || "$CPU_BRAND" == *"Ultra"* ]]; then
    EXPECTED_TIER="max_32gb_plus"
  elif [[ "$CPU_BRAND" == *"Pro"* ]]; then
    EXPECTED_TIER="pro_32gb_plus"
  else
    EXPECTED_TIER="base_16gb"
  fi
fi

if [[ -n "$REQUIRED_TIER" && "$EXPECTED_TIER" != "$REQUIRED_TIER" ]]; then
  echo "This Mac is $(tier_label "$EXPECTED_TIER") ($EXPECTED_TIER), not $(tier_label "$REQUIRED_TIER") ($REQUIRED_TIER)." >&2
  echo "Run this collection command on the required hardware tier, or omit --require-tier for exploratory local evidence." >&2
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Local MLX hardware collection dry run"
  echo "Detected Gate D tier: $(tier_label "$EXPECTED_TIER") ($EXPECTED_TIER)"
  if [[ -n "$REQUIRED_TIER" ]]; then
    echo "Required Gate D tier: $(tier_label "$REQUIRED_TIER") ($REQUIRED_TIER)"
  fi
  echo "CPU brand: $CPU_BRAND"
  echo "Physical memory bytes: $PHYSICAL_MEMORY_BYTES"
  echo "Evidence output: $OUTPUT_PATH"
  echo "Helper path: $HELPER_PATH"
  echo "Model folder: $MODEL_DIR"
  echo "Iterations: $ITERATIONS"
  if [[ "$LOW_MEMORY_TIER" == "1" ]]; then
    echo "This tier records the expected low-memory block without loading a model."
  else
    echo "Run without --dry-run to collect sustained MLX evidence for this tier."
  fi
  exit 0
fi

if [[ "$LOW_MEMORY_TIER" == "1" ]]; then
  echo "This Mac is below the sustained Local MLX memory target."
  echo "Collecting expected low-memory block evidence without requiring an installed model."
  if [[ ! -d "$MODEL_DIR" ]]; then
    LOW_MEMORY_MODEL_DIR_CLEANUP="$(mktemp -d "${TMPDIR:-/tmp}/astra-local-mlx-empty-model.XXXXXX")"
    MODEL_DIR="$LOW_MEMORY_MODEL_DIR_CLEANUP"
    echo "Using temporary empty model folder for expected low-memory block evidence: $MODEL_DIR"
  fi
else
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
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
cd "$ROOT_DIR"

RUN_E2E=1 \
RUN_E2E_RUNTIME=local_mlx \
RUN_E2E_LOCAL_MLX_HARDWARE=1 \
RUN_E2E_LOCAL_MLX_HARDWARE_ITERATIONS="$ITERATIONS" \
ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_OUT="$OUTPUT_PATH" \
REAL_LOCAL_MLX_HELPER="$HELPER_PATH" \
REAL_LOCAL_MLX_MODEL_DIR="$MODEL_DIR" \
swift test --filter localMLXSustainedHardwareValidationEndToEnd

echo "Local MLX hardware evidence written to: $OUTPUT_PATH"
script/local_mlx_hardware_evidence.py --require-tier "$EXPECTED_TIER" "$OUTPUT_PATH"
echo "Inspect coverage with:"
echo "  script/local_mlx_hardware_evidence.py \"$OUTPUT_PATH\""
