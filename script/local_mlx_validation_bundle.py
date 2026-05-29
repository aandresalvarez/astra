#!/usr/bin/env python3
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


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


def deduplicated_samples(samples):
    seen = set()
    unique = []
    for sample in samples:
        key = json.dumps(sample, sort_keys=True, separators=(",", ":"))
        if key in seen:
            continue
        seen.add(key)
        unique.append(sample)
    return unique


def same_file(first, second):
    try:
        return Path(first).expanduser().resolve() == Path(second).expanduser().resolve()
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Create a combined Local MLX validation bundle from evidence files."
    )
    parser.add_argument(
        "--bundle",
        action="append",
        help="Existing combined validation bundle JSON. May be repeated to merge bundles.",
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
        "--out",
        help="Output bundle path. Defaults to stdout.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print merged evidence sample counts without writing a bundle.",
    )
    args = parser.parse_args()

    if args.out and not args.dry_run:
        for bundle in args.bundle or []:
            if same_file(args.out, bundle):
                print(
                    "error: --out must not point to the same file as an input --bundle. "
                    "Write to a new bundle path, then import or rename it after inspection.",
                    file=sys.stderr,
                )
                return 2

    try:
        release_samples = []
        beta_samples = []
        hardware_samples = []
        for bundle in args.bundle or []:
            bundle_release, bundle_beta, bundle_hardware = load_combined_bundle(bundle)
            release_samples.extend(bundle_release)
            beta_samples.extend(bundle_beta)
            hardware_samples.extend(bundle_hardware)
        release_samples.extend(load_sample_files(args.release_candidate, "release-candidate evidence"))
        beta_samples.extend(load_sample_files(args.beta_soak, "beta-soak evidence"))
        hardware_samples.extend(load_sample_files(args.hardware, "hardware evidence"))
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    release_samples = deduplicated_samples(release_samples)
    beta_samples = deduplicated_samples(beta_samples)
    hardware_samples = deduplicated_samples(hardware_samples)

    if not release_samples and not beta_samples and not hardware_samples:
        print("error: no Local MLX evidence samples provided", file=sys.stderr)
        return 2

    sample_summary = (
        "Bundle samples: "
        f"{len(release_samples)} release-candidate, "
        f"{len(beta_samples)} beta-soak, "
        f"{len(hardware_samples)} hardware."
    )
    if args.dry_run:
        print("Local MLX validation bundle dry run")
        print(sample_summary)
        if args.out:
            print(f"Bundle output would be written to: {Path(args.out)}")
        else:
            print("Bundle output would be written to stdout.")
        return 0

    payload = {
        "schemaVersion": 1,
        "exportedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "releaseCandidateSamples": release_samples,
        "betaSoakSamples": beta_samples,
        "hardwareSamples": hardware_samples,
    }
    output = json.dumps(payload, indent=2, sort_keys=True) + "\n"

    if args.out:
        output_path = Path(args.out)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output, encoding="utf-8")
        print(f"Local MLX validation bundle written to: {output_path}")
        print(sample_summary)
    else:
        print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
