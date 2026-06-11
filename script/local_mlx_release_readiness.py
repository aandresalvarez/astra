#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

GIB = 1024**3
RECOMMENDED_MODEL = "Qwen/Qwen3-4B-MLX-4bit"
MINIMUM_SUSTAINED_ITERATIONS = 3

REQUIRED_RELEASE_MODES = [
    ("local_chat", "Private Local Chat live e2e"),
    ("local_agent_read_only", "Local Agent read-only live e2e"),
]

REQUIRED_BETA_TOOLS = [
    "task.write_output",
    "workspace.write_file",
    "shell.exec",
    "network.fetch",
    "browser.click",
    "browser.type",
]

READ_ONLY_TOOLS = {
    "workspace.read_file",
    "workspace.list_files",
    "workspace.search",
    "task.list_outputs",
    "task.read_output",
    "browser.read_page",
    "browser.analyze",
    "jira.search",
    "github.search",
    "google_drive.search",
    "google_drive.read",
    "gmail.search",
    "gmail.read",
    "slack.search",
    "slack.thread",
}

ALL_HARDWARE_TIERS = [
    ("low_memory_8gb", "8 GB class"),
    ("base_16gb", "16 GB base-class"),
    ("pro_32gb_plus", "32 GB+ Pro-class"),
    ("max_32gb_plus", "32 GB+ Max/Ultra-class"),
]

REQUIRED_HARDWARE_TIERS = [
    ("pro_32gb_plus", "32 GB+ Pro-class"),
]

HARDWARE_OUTPUT_HINTS = {
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


def load_samples(path, label):
    payload = parse_json_payload(Path(path).read_text(encoding="utf-8"), label)
    if payload.get("schemaVersion") != 1:
        raise ValueError(f"{label}: unsupported schemaVersion {payload.get('schemaVersion')}")
    samples = payload.get("samples")
    if not isinstance(samples, list):
        raise ValueError(f"{label}: samples must be an array")
    return samples


def load_sample_files(paths, label):
    samples = []
    for path in paths or []:
        samples.extend(load_samples(path, label))
    return samples


def load_combined_bundle(path):
    payload = parse_json_payload(Path(path).read_text(encoding="utf-8"), "combined validation bundle")
    if payload.get("schemaVersion") != 1:
        raise ValueError(f"combined validation bundle: unsupported schemaVersion {payload.get('schemaVersion')}")
    release_samples = payload.get("releaseCandidateSamples")
    beta_samples = payload.get("betaSoakSamples")
    hardware_samples = payload.get("hardwareSamples")
    if not isinstance(release_samples, list):
        raise ValueError("combined validation bundle: releaseCandidateSamples must be an array")
    if not isinstance(beta_samples, list):
        raise ValueError("combined validation bundle: betaSoakSamples must be an array")
    if not isinstance(hardware_samples, list):
        raise ValueError("combined validation bundle: hardwareSamples must be an array")
    return release_samples, beta_samples, hardware_samples


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


def hardware_tier(profile):
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


def hardware_sample_covers(sample, tier):
    if hardware_tier(sample.get("profile") or {}) != tier:
        return False
    outcome = sample.get("outcome")
    if tier == "low_memory_8gb":
        return outcome == "blocked_as_expected"
    return (
        outcome == "passed"
        and int_at_least(sample.get("iterations"), MINIMUM_SUSTAINED_ITERATIONS)
        and positive_int(sample.get("durationSeconds"))
        and passed_hardware_sample_has_inference_telemetry(sample)
    )


def positive_number(value):
    numeric = number_or_none(value)
    return numeric is not None and numeric > 0


def passed_hardware_sample_has_inference_telemetry(sample):
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


def inspect_release(samples, required_build_id=None):
    covered = [
        mode
        for mode, _ in REQUIRED_RELEASE_MODES
        if any(
            sample.get("mode") == mode
            and release_sample_is_usable(sample, required_build_id=required_build_id)
            for sample in samples
        )
    ]
    build_bound_covered = [
        mode
        for mode, _ in REQUIRED_RELEASE_MODES
        if any(
            sample.get("mode") == mode
            and release_sample_is_usable(sample, required_build_id=required_build_id)
            and str(sample.get("buildIdentifier") or "").strip()
            for sample in samples
        )
    ]
    missing = [mode for mode, _ in REQUIRED_RELEASE_MODES if mode not in covered]
    build_bound_missing = [
        mode
        for mode, _ in REQUIRED_RELEASE_MODES
        if mode not in build_bound_covered
    ]
    non_covering = [
        sample
        for sample in samples
        if not release_sample_is_usable(sample, required_build_id=required_build_id)
    ]
    return covered, missing, build_bound_covered, build_bound_missing, non_covering


def release_sample_is_usable(sample, required_build_id=None):
    usable = (
        sample.get("outcome") == "passed"
        and str(sample.get("model") or "").strip() == RECOMMENDED_MODEL
        and str(sample.get("modelDirectory") or "").strip()
        and str(sample.get("helperPath") or "").strip()
        and positive_int(sample.get("inputTokens"))
        and positive_int(sample.get("outputTokens"))
        and str(sample.get("stopReason") or "").strip()
        and str(sample.get("marker") or "").strip()
    )
    if not usable:
        return False
    if required_build_id:
        return str(sample.get("buildIdentifier") or "").strip() == required_build_id
    return True


def inspect_beta(samples):
    completed = [
        sample
        for sample in samples
        if beta_sample_counts_for_gate_c(sample)
    ]
    covered_tools = [
        tool
        for tool in REQUIRED_BETA_TOOLS
        if any(tool in successful_tools(sample) for sample in completed)
    ]
    has_read_only = any(
        any(tool in READ_ONLY_TOOLS for tool in successful_tools(sample))
        and all(tool not in REQUIRED_BETA_TOOLS for tool in successful_tools(sample))
        for sample in completed
    )
    non_covering = [
        sample
        for sample in samples
        if not beta_sample_counts_for_gate_c(sample)
        and not beta_sample_is_expected_approval_checkpoint(sample)
    ]
    missing = []
    if not has_read_only:
        missing.append("read-only Local Agent workflow")
    missing.extend(tool for tool in REQUIRED_BETA_TOOLS if tool not in covered_tools)
    return has_read_only, covered_tools, missing, non_covering


def beta_sample_has_covering_shape(sample):
    tools = sample.get("successfulTools")
    return (
        sample.get("outcome") == "completed"
        and isinstance(tools, list)
        and all(isinstance(tool, str) for tool in tools)
    )


def beta_sample_counts_for_gate_c(sample):
    return (
        beta_sample_has_covering_shape(sample)
        and str(sample.get("model") or "").strip() == RECOMMENDED_MODEL
    )


def beta_sample_is_expected_approval_checkpoint(sample):
    tools = sample.get("successfulTools")
    return (
        sample.get("outcome") == "approval_required"
        and str(sample.get("model") or "").strip() == RECOMMENDED_MODEL
        and str(sample.get("stopReason") or "").strip() == "permission_approval_required"
        and isinstance(tools, list)
        and len(tools) == 0
    )


def successful_tools(sample):
    tools = sample.get("successfulTools") or []
    if not isinstance(tools, list):
        return []
    return [tool for tool in tools if isinstance(tool, str)]


def inspect_hardware(samples):
    covered = [
        tier
        for tier, _ in REQUIRED_HARDWARE_TIERS
        if any(hardware_sample_covers(sample, tier) for sample in samples)
    ]
    missing = [tier for tier, _ in REQUIRED_HARDWARE_TIERS if tier not in covered]
    required_ids = {tier for tier, _ in REQUIRED_HARDWARE_TIERS}
    non_covering = [
        sample
        for sample in samples
        if (
            hardware_tier(sample.get("profile", {})) is None
            or (
                hardware_tier(sample.get("profile", {})) in required_ids
                and not any(hardware_sample_covers(sample, tier) for tier, _ in REQUIRED_HARDWARE_TIERS)
            )
        )
    ]
    return covered, missing, non_covering


def print_named_list(title, values, names=None):
    print(f"{title}:")
    if values:
        for value in values:
            print(f"  - {names.get(value, value) if names else value}")
    else:
        print("  - none")


def print_hardware_next_steps(missing, names):
    if not missing:
        return
    print("")
    print("Next hardware collection:")
    print("  - Preview this Mac's detected tier and output path first:")
    print("    script/local_mlx_collect_hardware_evidence.sh --dry-run")
    for tier in missing:
        output = HARDWARE_OUTPUT_HINTS.get(tier, "/tmp/astra-local-mlx-hardware-evidence.json")
        print(f"  - {names.get(tier, tier)}: run script/local_mlx_collect_hardware_evidence.sh --require-tier {tier} --out {output}")


def print_release_next_step(release_missing, build_bound_missing):
    if not release_missing and not build_bound_missing:
        return
    print("")
    print("Next release-candidate collection:")
    print("  - Preview the build id, helper, model folder, and output path first:")
    print("    script/local_mlx_collect_release_evidence.sh \\")
    print("      --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" \\")
    print("      --dry-run")
    print("  - Run the build-bound Local Chat and Local Agent read-only evidence wrapper:")
    print("    script/local_mlx_collect_release_evidence.sh \\")
    print("      --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" \\")
    print("      --out /tmp/astra-local-mlx-release-evidence.json")


def print_beta_next_step(missing, release_paths):
    if not missing:
        return
    print("")
    print("Next beta collection:")
    print("  - Preview high-risk Local Agent beta collection first:")
    print("    script/local_mlx_collect_release_evidence.sh \\")
    print("      --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" \\")
    print("      --include-high-risk-tools \\")
    print("      --dry-run")
    print("  - Run the Local Agent beta evidence wrapper with high-risk tools enabled:")
    print("    script/local_mlx_collect_release_evidence.sh \\")
    print("      --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" \\")
    print("      --include-high-risk-tools \\")
    print("      --beta-out /tmp/astra-local-agent-beta-soak-evidence.json")
    if release_paths:
        print("  - Reuse the same release-candidate evidence path when inspecting readiness:")
        print(f"    --release-candidate {shell_quote(release_paths[0])}")


def shell_quote(value):
    return "'" + str(value).replace("'", "'\"'\"'") + "'"


def print_bundle_next_step(bundle_paths, release_paths, beta_paths, hardware_paths):
    bundle_paths = bundle_paths or []
    release_paths = release_paths or []
    beta_paths = beta_paths or []
    hardware_paths = hardware_paths or []
    if not bundle_paths and (not release_paths or not beta_paths or not hardware_paths):
        return

    args = []
    for path in bundle_paths:
        args.extend(["--bundle", path])
    for path in release_paths:
        args.extend(["--release-candidate", path])
    for path in beta_paths:
        args.extend(["--beta-soak", path])
    for path in hardware_paths:
        args.extend(["--hardware", path])
    args.extend(["--out", safe_bundle_output_path(bundle_paths, release_paths, beta_paths, hardware_paths)])

    print("")
    print("Bundle evidence for Runtime settings import:")
    print("  # Preview merged sample counts first by adding --dry-run to this command.")
    print("  script/local_mlx_validation_bundle.py \\")
    for index in range(0, len(args), 2):
        suffix = " \\" if index + 2 < len(args) else ""
        print(f"    {args[index]} {shell_quote(args[index + 1])}{suffix}")


def safe_bundle_output_path(bundle_paths, release_paths, beta_paths, hardware_paths):
    default_output = Path("/tmp/astra-local-mlx-validation-bundle.json")
    if bundle_paths and not release_paths and not beta_paths and not hardware_paths:
        return "/tmp/astra-local-mlx-validation-bundle-merged.json"
    return str(default_output)


def print_release_preflight_next_step(args, required_build_id):
    bundle_paths = args.bundle or []
    release_paths = args.release_candidate or []
    beta_paths = args.beta_soak or []
    hardware_paths = args.hardware or []
    if len(bundle_paths) == 1 and not release_paths and not beta_paths and not hardware_paths:
        print("")
        print("Release packaging preflight:")
        print("  ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1 \\")
        print("  ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1 \\")
        if required_build_id:
            print(f"  ASTRA_LOCAL_MLX_RELEASE_BUILD_ID={shell_quote(required_build_id)} \\")
        print(f"  ASTRA_LOCAL_MLX_VALIDATION_BUNDLE={shell_quote(bundle_paths[0])} \\")
        print("  script/release_update.sh")
        return

    if bundle_paths or len(release_paths) != 1 or len(beta_paths) != 1:
        print("")
        print("Release packaging preflight:")
        print("  # First run the bundle command above, then use the single bundle for packaging:")
        print("  ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1 \\")
        print("  ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1 \\")
        if required_build_id:
            print(f"  ASTRA_LOCAL_MLX_RELEASE_BUILD_ID={shell_quote(required_build_id)} \\")
        print("  ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/tmp/astra-local-mlx-validation-bundle.json \\")
        print("  script/release_update.sh")
        return

    if not hardware_paths:
        return

    print("")
    print("Release packaging preflight:")
    print("  ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1 \\")
    print("  ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1 \\")
    if required_build_id:
        print(f"  ASTRA_LOCAL_MLX_RELEASE_BUILD_ID={shell_quote(required_build_id)} \\")
    print(f"  ASTRA_LOCAL_MLX_RELEASE_EVIDENCE={shell_quote(release_paths[0])} \\")
    print(f"  ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE={shell_quote(beta_paths[0])} \\")
    print(f"  ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES={shell_quote(':'.join(hardware_paths))} \\")
    print("  script/release_update.sh")


def main():
    parser = argparse.ArgumentParser(
        description="Inspect combined Local MLX release-readiness evidence."
    )
    parser.add_argument(
        "--bundle",
        action="append",
        help="Combined Local MLX validation bundle JSON. May be repeated.",
    )
    parser.add_argument(
        "--release-candidate",
        action="append",
        help="Release-candidate evidence JSON. May be repeated.",
    )
    parser.add_argument(
        "--beta-soak",
        action="append",
        help="Local Agent beta-soak evidence JSON. May be repeated.",
    )
    parser.add_argument(
        "--hardware",
        action="append",
        help="Sustained hardware evidence JSON. May be repeated for multi-Mac Gate D evidence.",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit non-zero unless Gates A-D have complete evidence.",
    )
    parser.add_argument(
        "--require-clean-evidence",
        action="store_true",
        help="Exit non-zero when any imported sample fails the release evidence rules.",
    )
    parser.add_argument(
        "--require-build-id",
        help="Only count release-candidate evidence recorded for this build identifier.",
    )
    args = parser.parse_args()

    try:
        release_samples = []
        beta_samples = []
        hardware_samples = []

        for bundle in args.bundle or []:
            bundle_release, bundle_beta, bundle_hardware = load_combined_bundle(bundle)
            release_samples.extend(bundle_release)
            beta_samples.extend(bundle_beta)
            hardware_samples.extend(bundle_hardware)

        if not args.bundle:
            missing = [
                name
                for name, value in (
                    ("--release-candidate", args.release_candidate),
                    ("--beta-soak", args.beta_soak),
                    ("--hardware", args.hardware),
                )
                if not value
            ]
            if missing:
                raise ValueError(f"missing required evidence argument(s): {', '.join(missing)}")

        release_samples.extend(load_sample_files(args.release_candidate, "release-candidate evidence"))
        beta_samples.extend(load_sample_files(args.beta_soak, "beta-soak evidence"))
        hardware_samples.extend(load_sample_files(args.hardware, "hardware evidence"))
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    required_build_id = (args.require_build_id or "").strip()
    (
        release_covered,
        release_missing,
        build_bound_release_covered,
        build_bound_release_missing,
        non_covering_release,
    ) = inspect_release(
        release_samples,
        required_build_id=required_build_id or None
    )
    has_read_only, beta_tools, beta_missing, non_covering_beta = inspect_beta(beta_samples)
    hardware_covered, hardware_missing, non_covering_hardware = inspect_hardware(hardware_samples)

    mode_names = dict(REQUIRED_RELEASE_MODES)
    tier_names = dict(ALL_HARDWARE_TIERS)

    gate_a_complete = "local_chat" in release_covered
    gate_b_complete = "local_agent_read_only" in release_covered
    gate_c_complete = not beta_missing
    gate_d_complete = (
        gate_c_complete
        and not release_missing
        and not build_bound_release_missing
        and not hardware_missing
    )
    clean_evidence = (
        not non_covering_release
        and not non_covering_beta
        and not non_covering_hardware
    )
    all_complete = gate_a_complete and gate_b_complete and gate_c_complete and gate_d_complete

    print("Local MLX release readiness")
    print(f"Gate A Local Chat preview: {'passed' if gate_a_complete else 'in_progress'}")
    print(f"Gate B Local Agent developer flag: {'passed' if gate_b_complete else 'in_progress'}")
    print(f"Gate C Local Agent beta: {'passed' if gate_c_complete else 'in_progress'}")
    print(f"Gate D General availability: {'passed' if gate_d_complete else 'in_progress'}")
    print("")
    print(f"Release-candidate samples: {len(release_samples)}")
    if required_build_id:
        print(f"Required release build id: {required_build_id}")
    print_named_list("Covered release modes", release_covered, mode_names)
    print_named_list("Missing release modes", release_missing, mode_names)
    print_named_list("Covered build-bound release modes", build_bound_release_covered, mode_names)
    print_named_list("Missing build-bound release modes", build_bound_release_missing, mode_names)
    print("Non-covering release-candidate samples:")
    if non_covering_release:
        print(f"  - {len(non_covering_release)} sample(s) did not satisfy Gate A/B evidence rules")
        print(f"  - release-candidate samples must use {RECOMMENDED_MODEL} and include model folder, helper path, tokens, stop reason, and marker")
    else:
        print("  - none")
    print_release_next_step(release_missing, build_bound_release_missing)
    print("")
    print(f"Beta-soak samples: {len(beta_samples)}")
    print(f"Read-only Local Agent workflow: {'covered' if has_read_only else 'missing'}")
    print_named_list("Covered high-risk beta tools", beta_tools)
    print_named_list("Missing beta coverage", beta_missing)
    print("Non-covering beta-soak samples:")
    if non_covering_beta:
        print(f"  - {len(non_covering_beta)} sample(s) did not satisfy Gate C evidence rules")
        print(f"  - beta-soak samples must complete with {RECOMMENDED_MODEL} or be expected approval checkpoints")
    else:
        print("  - none")
    print_beta_next_step(beta_missing, args.release_candidate or [])
    print("")
    print(f"Hardware samples: {len(hardware_samples)}")
    print_named_list("Covered hardware tiers", hardware_covered, tier_names)
    print_named_list("Missing hardware tiers", hardware_missing, tier_names)
    print("Non-covering hardware samples:")
    if non_covering_hardware:
        print(f"  - {len(non_covering_hardware)} sample(s) did not satisfy Gate D evidence rules")
        print(f"  - passed hardware samples must run at least {MINIMUM_SUSTAINED_ITERATIONS} iterations with {RECOMMENDED_MODEL} and include mlx backend, tokens, duration, first-token latency, and throughput")
    else:
        print("  - none")
    print_hardware_next_steps(hardware_missing, tier_names)
    print_bundle_next_step(args.bundle, args.release_candidate, args.beta_soak, args.hardware)
    if all_complete:
        print_release_preflight_next_step(args, required_build_id)

    if args.require_complete and not all_complete:
        return 1
    if args.require_clean_evidence and not clean_evidence:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
