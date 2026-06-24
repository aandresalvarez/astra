#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_BIN="${DOCKER_BIN:-docker}"
TOOL="${ASTRA_WORKSPACE_TOOL:-$ROOT/.build/debug/astra-workspace}"
TAG="${ASTRA_DOCKER_WORKSPACE_SMOKE_IMAGE:-astra-workspace-smoke:local}"

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  echo "docker_workspace_smoke: Docker CLI not found: $DOCKER_BIN" >&2
  exit 127
fi

if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  echo "docker_workspace_smoke: Docker daemon is not available" >&2
  exit 1
fi

cd "$ROOT"
if [[ "$TOOL" = "$ROOT/.build/debug/astra-workspace" ]]; then
  swift build --product astra-workspace >/dev/null
fi
if [[ ! -x "$TOOL" ]]; then
  echo "docker_workspace_smoke: astra-workspace helper is not executable: $TOOL" >&2
  exit 127
fi

TMPDIR="$(mktemp -d)"
cleanup() {
  "$DOCKER_BIN" rm -f astra-workspace-smoke >/dev/null 2>&1 || true
  "$DOCKER_BIN" image rm "$TAG" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

WORKSPACE="$TMPDIR/workspace"
GCLOUD="$TMPDIR/gcloud"
DOCKER_CONFIG_DIR="$TMPDIR/docker-client"
IMAGE_CONTEXT="$TMPDIR/image"
mkdir -p "$WORKSPACE" "$GCLOUD" "$DOCKER_CONFIG_DIR" "$IMAGE_CONTEXT"
printf '%s\n' "workspace-ok" > "$WORKSPACE/marker.txt"
printf '%s\n' '{"client_id":"astra-smoke","client_secret":"redacted","refresh_token":"redacted","type":"authorized_user"}' \
  > "$GCLOUD/application_default_credentials.json"
printf '%s\n' '{"auths":{}}' > "$DOCKER_CONFIG_DIR/config.json"

cat > "$IMAGE_CONTEXT/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.20
RUN mkdir -p /opt/workspace/.venv/bin /workspace \
  && printf '#!/bin/sh\nprintf "dbt-core: smoke\\n"\n' > /opt/workspace/.venv/bin/dbt \
  && chmod +x /opt/workspace/.venv/bin/dbt
WORKDIR /workspace
DOCKERFILE

"$DOCKER_BIN" build -t "$TAG" "$IMAGE_CONTEXT" >/dev/null

MOUNTS_JSON="[{\"hostPath\":\"$WORKSPACE\",\"containerPath\":\"/workspace\",\"access\":\"rw\",\"role\":\"workspace\"},{\"hostPath\":\"$GCLOUD\",\"containerPath\":\"/root/.config/gcloud\",\"access\":\"ro\",\"role\":\"credential\"}]"
CONTAINER_ENV_JSON='{"CLOUDSDK_CONFIG":"/root/.config/gcloud","GOOGLE_APPLICATION_CREDENTIALS":"/root/.config/gcloud/application_default_credentials.json"}'

export ASTRA_WORKSPACE_DOCKER_EXECUTABLE="$DOCKER_BIN"
export ASTRA_WORKSPACE_DOCKER_IMAGE="$TAG"
export ASTRA_WORKSPACE_DOCKER_CONTAINER="astra-workspace-smoke"
export ASTRA_WORKSPACE_DOCKER_WORKDIR="/workspace"
export ASTRA_WORKSPACE_DOCKER_NETWORK="bridge"
export ASTRA_WORKSPACE_DOCKER_MOUNTS="$MOUNTS_JSON"
export ASTRA_WORKSPACE_DOCKER_ENV="$CONTAINER_ENV_JSON"
export ASTRA_WORKSPACE_TASK_ID="docker-smoke-task"
export ASTRA_WORKSPACE_RUN_ID="docker-smoke-run"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

SUCCESS_COMMAND='pwd && command -v dbt && dbt --version && test -r $GOOGLE_APPLICATION_CREDENTIALS && cat /workspace/marker.txt && printf container-write > /workspace/container-write.txt && cat /workspace/container-write.txt'
FAILURE_COMMAND='printf expected-failure >&2; exit 17'

OUTPUT="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_shell\",\"arguments\":{\"command\":\"$SUCCESS_COMMAND\",\"timeout_seconds\":30}}}" \
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_shell\",\"arguments\":{\"command\":\"$FAILURE_COMMAND\",\"timeout_seconds\":30}}}" \
  | "$TOOL"
)"
NORMALIZED_OUTPUT="$(printf '%s' "$OUTPUT" | sed 's#\\/#/#g')"

require_output() {
  local needle="$1"
  if ! grep -Fq "$needle" <<<"$NORMALIZED_OUTPUT"; then
    echo "docker_workspace_smoke: expected output not found: $needle" >&2
    echo "$OUTPUT" >&2
    exit 1
  fi
}

require_output '"name":"workspace_shell"'
require_output '/workspace'
require_output '/opt/workspace/.venv/bin/dbt'
require_output 'dbt-core: smoke'
require_output 'workspace-ok'
require_output 'container-write'
require_output 'exit_code: 17'
require_output 'expected-failure'

if [[ "$(cat "$WORKSPACE/container-write.txt")" != "container-write" ]]; then
  echo "docker_workspace_smoke: container write did not reach the mounted workspace" >&2
  exit 1
fi

echo "docker_workspace_smoke: passed"
