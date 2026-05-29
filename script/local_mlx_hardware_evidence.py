#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

GIB = 1024**3
RECOMMENDED_MODEL = "Qwen/Qwen3-4B-MLX-4bit"
MINIMUM_SUSTAINED_ITERATIONS = 3

ALL_TIERS = [
    ("low_memory_8gb", "8 GB class"),
    ("base_16gb", "16 GB base-class"),
    ("pro_32gb_plus", "32 GB+ Pro-class"),
    ("max_32gb_plus", "32 GB+ Max/Ultra-class"),
]

REQUIRED_TIERS = [
    ("pro_32gb_plus", "32 GB+ Pro-class"),
]

OUTPUT_HINTS = {
    "low_memory_8gb": "/tmp/astra-local-mlx-hardware-8gb.json",
    "base_16gb": "/tmp/astra-local-mlx-hardware-16gb.json",
    "pro_32gb_plus": "/tmp/astra-local-mlx-hardware-pro.json",
    "max_32gb_plus": "/tmp/astra-local-mlx-hardware-max.json",
}


def parse_json_payload(text, label):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            payload, _ = decoder.raw_decode(text[index:])
            return payload
        except json.JSONDecodeError:
            continue
    raise ValueError(f"{label}: no JSON object found")


def chip_class(profile):
    value = str(profile.get("chipClass") or "").strip().lower()
    if value:
        return value
    brand = str(profile.get("cpuBrand") or "").lower()
    if "ultra" in brand:
        return "ultra"
    if "max" in brand:
        return "max"
    if "pro" in brand:
        return "pro"
    return "base"


def number_or_none(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def tier_for(profile):
    if not profile.get("isAppleSilicon", False):
        return None
    memory_bytes = number_or_none(profile.get("physicalMemoryBytes"))
    if memory_bytes is None or memory_bytes <= 0:
        return None
    memory_gb = memory_bytes / GIB
    if memory_gb < 12:
        return "low_memory_8gb"
    if memory_gb < 24:
        return "base_16gb"
    chip = chip_class(profile)
    if chip in ("max", "ultra"):
        return "max_32gb_plus"
    if chip == "pro":
        return "pro_32gb_plus"
    return "base_16gb"


def positive_int(value):
    try:
        return int(value or 0) > 0
    except (TypeError, ValueError):
        return False


def int_at_least(value, minimum):
    try:
        return int(value or 0) >= minimum
    except (TypeError, ValueError):
        return False


def sample_covers_tier(sample, tier):
    sample_tier = tier_for(sample.get("profile") or {})
    if sample_tier != tier:
        return False
    outcome = sample.get("outcome")
    if tier == "low_memory_8gb":
        return outcome == "blocked_as_expected"
    return (
        outcome == "passed"
        and int_at_least(sample.get("iterations"), MINIMUM_SUSTAINED_ITERATIONS)
        and positive_int(sample.get("durationSeconds"))
        and passed_sample_has_inference_telemetry(sample)
    )


def positive_number(value):
    numeric = number_or_none(value)
    return numeric is not None and numeric > 0


def passed_sample_has_inference_telemetry(sample):
    profile = sample.get("profile") or {}
    return (
        str(profile.get("model") or "").strip() == RECOMMENDED_MODEL
        and str(profile.get("backend") or "").strip().lower() == "mlx"
        and positive_int(profile.get("inputTokens"))
        and positive_int(profile.get("outputTokens"))
        and positive_int(profile.get("durationMs"))
        and positive_int(profile.get("firstTokenLatencyMs"))
        and positive_number(profile.get("tokensPerSecond"))
    )


def load_samples(paths):
    samples = []
    for path in paths:
        payload = parse_json_payload(Path(path).read_text(encoding="utf-8"), path)
        if payload.get("schemaVersion") != 1:
            raise ValueError(f"{path}: unsupported schemaVersion {payload.get('schemaVersion')}")
        loaded = payload.get("samples")
        if not isinstance(loaded, list):
            raise ValueError(f"{path}: samples must be an array")
        samples.extend(loaded)
    return samples


def print_next_steps(missing, names):
    if not missing:
        return
    print("")
    print("Next hardware collection:")
    print("  - Preview this Mac's detected tier and output path first:")
    print("    script/local_mlx_collect_hardware_evidence.sh --dry-run")
    for tier in missing:
        output = OUTPUT_HINTS.get(tier, "/tmp/astra-local-mlx-hardware-evidence.json")
        print(f"  - {names.get(tier, tier)}: run script/local_mlx_collect_hardware_evidence.sh --require-tier {tier} --out {output}")


def sample_is_non_covering(sample):
    required_ids = {tier for tier, _ in REQUIRED_TIERS}
    sample_tier = tier_for(sample.get("profile", {}))
    if sample_tier is None:
        return True
    if sample_tier not in required_ids:
        return False
    return not any(sample_covers_tier(sample, tier) for tier, _ in REQUIRED_TIERS)


def main():
    parser = argparse.ArgumentParser(
        description="Inspect Local MLX sustained hardware validation evidence for Gate D."
    )
    parser.add_argument("evidence", nargs="+", help="Hardware evidence JSON bundle(s)")
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit non-zero when any required Gate D hardware tier is missing.",
    )
    parser.add_argument(
        "--require-tier",
        choices=[tier for tier, _ in ALL_TIERS],
        help="Exit non-zero when the specified hardware tier is not covered.",
    )
    args = parser.parse_args()

    try:
        samples = load_samples(args.evidence)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    covered = [
        tier
        for tier, _ in REQUIRED_TIERS
        if any(sample_covers_tier(sample, tier) for sample in samples)
    ]
    missing = [tier for tier, _ in REQUIRED_TIERS if tier not in covered]
    non_covering = [sample for sample in samples if sample_is_non_covering(sample)]
    names = dict(ALL_TIERS)

    print(f"Local MLX hardware evidence samples: {len(samples)}")
    if args.require_tier:
        print(f"Required tier: {names[args.require_tier]}")
    print("Covered tiers:")
    for tier in covered:
        print(f"  - {names[tier]}")
    print("Missing tiers:")
    if missing:
        for tier in missing:
            print(f"  - {names[tier]}")
    else:
        print("  - none")
    print("Non-covering samples:")
    if non_covering:
        print(f"  - {len(non_covering)} sample(s) did not satisfy Gate D evidence rules")
        print(f"  - passed hardware samples must run at least {MINIMUM_SUSTAINED_ITERATIONS} iterations with {RECOMMENDED_MODEL} and include mlx backend, tokens, duration, first-token latency, and throughput")
    else:
        print("  - none")
    print_next_steps(missing, names)

    if args.require_tier and not any(sample_covers_tier(sample, args.require_tier) for sample in samples):
        return 1
    if missing and args.require_complete:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
