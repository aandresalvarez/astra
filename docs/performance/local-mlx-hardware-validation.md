# Local MLX Hardware Validation

Gate D requires sustained Local MLX evidence from at least the 32 GB+ Pro-class
Apple Silicon tier before general availability. Other tiers (8 GB, 16 GB
base-class, 32 GB+ Max/Ultra) are protected by runtime guards and unit tests
but are not required for GA hardware validation.

## Required Tier

- 32 GB+ Pro-class Apple Silicon: sustained run must pass with at least
  3 sustained iterations.

## Optional Tiers

Evidence from these tiers can be collected opportunistically when hardware is
available. Other tiers are protected by runtime guards and unit tests.

- 8 GB class Apple Silicon: expected block or heavy warning is acceptable.
- 16 GB base-class Apple Silicon: sustained run should pass.
- 32 GB+ Max/Ultra-class Apple Silicon: sustained run should pass.

One-shot smoke samples are useful during development, but they do not satisfy
Gate D.

## Run On Each Mac

Install the recommended Qwen model first from Runtime settings:

```text
Qwen/Qwen3-4B-MLX-4bit
```

On 8 GB Macs, the validation records the expected low-memory block before
loading a model, so an installed model folder is not required for that tier.

Then run:

```bash
script/local_mlx_collect_hardware_evidence.sh
```

To check what the wrapper will collect before launching MLX, run:

```bash
script/local_mlx_collect_hardware_evidence.sh --dry-run
```

The dry run prints the detected Gate D tier, evidence output path, helper path,
model folder, and iteration count without requiring the model folder or running
the sustained validation test.

When collecting a specific missing tier, pass `--require-tier` so the command
fails immediately if it is accidentally run on the wrong Mac class:

```bash
script/local_mlx_collect_hardware_evidence.sh \
  --require-tier base_16gb \
  --out /tmp/astra-local-mlx-hardware-16gb.json
```

Without `--out`, the wrapper writes to this Mac's Gate D tier file:
`/tmp/astra-local-mlx-hardware-8gb.json`,
`/tmp/astra-local-mlx-hardware-16gb.json`,
`/tmp/astra-local-mlx-hardware-pro.json`, or
`/tmp/astra-local-mlx-hardware-max.json`.

Before launching live validation on 16 GB+ Macs, the wrapper checks that the
selected model folder contains `config.json`, tokenizer files, and non-empty
model weights. Missing assets fail immediately with setup guidance instead of
starting the Swift test runner.

After writing the evidence, the wrapper runs
`script/local_mlx_hardware_evidence.py --require-tier ...` for this Mac's
detected tier. If the generated sample is missing required MLX telemetry or
does not cover the expected tier, the wrapper exits non-zero immediately.

Use flags only when the helper, model folder, output path, or iteration count
differs from the defaults:

```bash
script/local_mlx_collect_hardware_evidence.sh \
  --helper "$HOME/.astra/tools/astra-local-model" \
  --model-dir "$HOME/Library/Application Support/AstraDev/LocalModels/Qwen3-4B-MLX-4bit" \
  --out /tmp/astra-local-mlx-hardware-evidence.json \
  --iterations 3
```

With the example command above, the command appends a signed-by-shape JSON
evidence bundle to:

```text
/tmp/astra-local-mlx-hardware-evidence.json
```

For auditability, the wrapper runs the sustained validation test with these
environment values:

```bash
RUN_E2E=1
RUN_E2E_RUNTIME=local_mlx
RUN_E2E_LOCAL_MLX_HARDWARE=1
RUN_E2E_LOCAL_MLX_HARDWARE_ITERATIONS=3
ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_OUT=/tmp/astra-local-mlx-hardware-evidence.json
REAL_LOCAL_MLX_HELPER="$HOME/.astra/tools/astra-local-model"
REAL_LOCAL_MLX_MODEL_DIR="$HOME/Library/Application Support/AstraDev/LocalModels/Qwen3-4B-MLX-4bit"
swift test --filter localMLXSustainedHardwareValidationEndToEnd
```

## Merge Evidence

On the release-validation Mac:

1. Open ASTRA Dev settings.
2. Go to Runtime, Local MLX, Hardware.
3. Click `Import Evidence`.
4. Paste or copy the JSON bundle from the other Mac first if needed.
5. Repeat until Coverage says all required Mac tiers are covered.

The same JSON can be copied from ASTRA with `Copy Evidence`.

ASTRA accepts either raw evidence JSON or JSON pasted from notes, chat, or a
Markdown code fence. The importer extracts the first JSON object before
validating the evidence schema.

For release handoff, prefer the Runtime settings `Copy Validation Bundle` and
`Import Validation Bundle` controls. The bundle carries release-candidate,
beta-soak, and hardware evidence together so a release-validation Mac can merge
all Local MLX evidence in one import.

To assemble the same bundle from evidence files in the repo, run:

```bash
script/local_mlx_validation_bundle.py \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-pro.json \
  --out /tmp/astra-local-mlx-validation-bundle.json
```

To preview the merged sample counts before writing a bundle, add `--dry-run`.

```bash
script/local_mlx_validation_bundle.py \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-pro.json \
  --out /tmp/astra-local-mlx-validation-bundle.json \
  --dry-run
```

## Inspect Evidence Files

Before importing a bundle, or after collecting several bundles, inspect coverage
from the repo:

```bash
script/local_mlx_hardware_evidence.py /tmp/astra-local-mlx-hardware-evidence.json
```

The inspector accepts raw JSON files and JSON copied into notes, email, chat,
or Markdown code fences.
When tiers are missing, it prints the exact
`script/local_mlx_collect_hardware_evidence.sh --dry-run` preview first, then
the `script/local_mlx_collect_hardware_evidence.sh --require-tier ... --out
...` command to run on each missing Mac class. The required-tier guard prevents
mislabeling evidence by writing a Pro or Max sample to the 8 GB or 16 GB output
path.

For release validation, require complete hardware coverage:

```bash
script/local_mlx_hardware_evidence.py --require-complete /tmp/astra-local-mlx-hardware-evidence.json
```

The command exits non-zero while any required tier is missing.

## Inspect Release Readiness

After collecting release-candidate, beta-soak, and hardware evidence, inspect
all Local MLX release gates together. For final release validation, use the
same build identity that release packaging will require. By default, that is
`ASTRA_VERSION+ASTRA_BUILD`:

```bash
export ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="0.1.0+1"
```

To collect build-bound Private Local Chat and Local Agent read-only
release-candidate evidence on this Mac, run. If `--build-id` is omitted, the
wrapper derives the build id from `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID`, or from
`ASTRA_VERSION` plus `ASTRA_BUILD`:

```bash
script/local_mlx_collect_release_evidence.sh \
  --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"
```

Before launching the live tests, the wrapper checks that the selected model
folder contains `config.json`, a tokenizer file, and non-empty model weights.
Incomplete folders fail immediately with guidance to install Qwen 3 4B from
Runtime settings or pass a complete MLX model folder.

The wrapper replaces the release-candidate and beta-soak output files at the
start of a non-dry-run collection. This keeps new build-bound evidence clean
and prevents stale samples from older local-model experiments from blocking
`--require-clean-evidence`. `--out` and `--beta-out` must be different files
because the release-candidate and beta-soak payloads use different schemas.

To preview the build id, output files, helper path, model folder, and high-risk
scope without launching Local MLX tests, run:

```bash
script/local_mlx_collect_release_evidence.sh \
  --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --dry-run
```

Use flags only when the helper, model folder, or output path differs from the
defaults:

```bash
script/local_mlx_collect_release_evidence.sh \
  --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --helper "$HOME/.astra/tools/astra-local-model" \
  --model-dir "$HOME/Library/Application Support/AstraDev/LocalModels/Qwen3-4B-MLX-4bit" \
  --out /tmp/astra-local-mlx-release-evidence.json
```

To also collect the opt-in high-risk Local Agent beta evidence required by
Gate C, add `--include-high-risk-tools`. This runs the approval-gated
`task.write_output`, `workspace.write_file`, `shell.exec`, `network.fetch`,
`browser.click`, and `browser.type` live tests and writes those samples to the
beta-soak evidence file:

```bash
script/local_mlx_collect_release_evidence.sh \
  --build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --include-high-risk-tools \
  --beta-out /tmp/astra-local-agent-beta-soak-evidence.json
```

```bash
script/local_mlx_release_readiness.py \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-evidence.json
```

Repeat `--hardware` when Gate D evidence comes from separate Mac-specific
files:

```bash
script/local_mlx_release_readiness.py --require-complete \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-8gb.json \
  --hardware /tmp/astra-local-mlx-hardware-16gb.json \
  --hardware /tmp/astra-local-mlx-hardware-pro.json \
  --hardware /tmp/astra-local-mlx-hardware-max.json
```

`script/local_mlx_collect_release_evidence.sh` prints this same tier-specific
readiness command after it writes release-candidate evidence.

For release validation, require Gates A-D to have complete evidence:

```bash
script/local_mlx_release_readiness.py --require-complete \
  --require-clean-evidence \
  --require-build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --release-candidate /tmp/astra-local-mlx-release-evidence.json \
  --beta-soak /tmp/astra-local-agent-beta-soak-evidence.json \
  --hardware /tmp/astra-local-mlx-hardware-evidence.json
```

Release packaging uses clean-evidence mode. A validation set can be useful for
investigation while still containing non-covering samples, but those samples
must be removed or replaced before the GA packaging preflight passes.

For packaging with tier-specific files, pass the hardware files as a
colon-separated list:

```bash
ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1 \
ASTRA_LOCAL_MLX_RELEASE_BUILD_ID="$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
ASTRA_LOCAL_MLX_RELEASE_EVIDENCE=/tmp/astra-local-mlx-release-evidence.json \
ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE=/tmp/astra-local-agent-beta-soak-evidence.json \
ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES=/tmp/astra-local-mlx-hardware-8gb.json:/tmp/astra-local-mlx-hardware-16gb.json:/tmp/astra-local-mlx-hardware-pro.json:/tmp/astra-local-mlx-hardware-max.json \
script/release_update.sh
```

To run only the Local MLX GA evidence preflight without building release
assets, add `ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY=1`. This evidence-only
mode requires either `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID` or
`ASTRA_VERSION` plus `ASTRA_BUILD` for the build-bound evidence identity, but
it does not require Sparkle signing variables.
If required evidence inputs are missing, `script/release_update.sh` reports all
missing Local MLX evidence variables together and prints the dry-run collection
commands to preview before collecting live evidence. Its bundle help mirrors
the safer merge workflow: separate release, beta, and hardware files assemble
`/tmp/astra-local-mlx-validation-bundle.json`, while existing bundle merges use
`/tmp/astra-local-mlx-validation-bundle-merged.json`.

If all evidence has already been assembled into one validation bundle, set
`ASTRA_LOCAL_MLX_VALIDATION_BUNDLE`. The release preflight also accepts
supplemental evidence variables alongside a validation bundle, so a bundle can
be combined with newer release-candidate, beta-soak, or hardware files without
rebuilding the bundle first. Hardware evidence from
`ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES` and `ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE`
is aggregated when both are set.

If you copied a combined validation bundle from ASTRA, inspect that one file
directly. The same `--require-build-id` check applies to release-candidate
samples inside the bundle:

```bash
script/local_mlx_release_readiness.py --require-complete \
  --require-build-id "$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" \
  --bundle /tmp/astra-local-mlx-validation-bundle.json
```

Repeat `--bundle` when evidence was copied from multiple ASTRA installs.

The command exits non-zero while any release-candidate mode, build-bound
release-candidate mode, beta tool, or required hardware tier is missing. When
`--require-build-id` is present, release-candidate samples from older builds are
treated as missing; rerun the live Local Chat and Local Agent read-only
release-candidate tests with the same `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID` before
packaging a new build.

Like the app importer, the release-readiness inspector accepts raw JSON or the
first JSON object copied from notes, email, chat, or a Markdown code fence.
When hardware tiers are missing, it prints the exact
`script/local_mlx_collect_hardware_evidence.sh --dry-run` preview first, then
the `script/local_mlx_collect_hardware_evidence.sh --require-tier ... --out
...` command to run on each missing Mac class. When release-candidate evidence is missing or was
collected for a different build, it prints the dry-run preview and the
`script/local_mlx_collect_release_evidence.sh --build-id
"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID" --out
/tmp/astra-local-mlx-release-evidence.json` command. When beta evidence is
missing, it prints the same wrapper with `--include-high-risk-tools`,
`--dry-run`, and `--beta-out /tmp/astra-local-agent-beta-soak-evidence.json`.
When separate release, beta, and hardware files are provided, it also prints
the validation-bundle dry-run guidance and the exact
`script/local_mlx_validation_bundle.py` command that assembles
`/tmp/astra-local-mlx-validation-bundle.json` for Runtime settings import. When
one or more bundles are provided without separate evidence files, the suggested
merge output is `/tmp/astra-local-mlx-validation-bundle-merged.json` so
validators do not read and write the same bundle while combining cross-Mac
evidence. The bundle builder also rejects non-dry-run writes where `--out`
points at an input `--bundle`; write a new bundle, inspect it, then import or
rename it. When Gates A-D are complete, it prints the exact
`script/release_update.sh` Local MLX GA preflight command to run before
building release assets.

## Gate D Check

Gate D stays blocked until:

- `LocalModelHardwareValidationMatrix.requiredTiers` are all covered.
- Each non-8 GB passed hardware sample proves real MLX inference with
  `Qwen/Qwen3-4B-MLX-4bit` by including `mlx` backend, input/output token
  counts, duration, first-token latency, and throughput. Imported samples from
  another model, or samples missing this telemetry, remain visible but do not
  cover their hardware tier.
- Private Local Chat release-candidate evidence exists.
- Local Agent read-only release-candidate evidence exists.
- Release-candidate evidence was collected with `Qwen/Qwen3-4B-MLX-4bit`.
- Local Agent beta-soak evidence was collected with
  `Qwen/Qwen3-4B-MLX-4bit`.
- Private Local Chat and Local Agent read-only release-candidate evidence is
  build-bound with `ASTRA_LOCAL_MLX_RELEASE_BUILD_ID`. Use
  `script/local_mlx_collect_release_evidence.sh` to collect it.
- The focused Local MLX regression suite is green.

Use this focused verification after merging evidence:

```bash
swift test --filter LocalModelRuntime
git diff --check
./script/build_and_run.sh --verify
```
