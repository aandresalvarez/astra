#!/usr/bin/env python3
"""Independent standard-library verifier for ASTRA feedback V1 golden bytes."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from collections import OrderedDict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
TIMESTAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")
GOLDENS = ["request", "receipt", "status-local", "status-remote", "status-read-request", "error"]


def utf16_key(value: str) -> bytes:
    return value.encode("utf-16-be")


def normalized(value: Any, path: str = "$", key: str | None = None) -> Any:
    if value is None:
        raise ValueError(f"{path}: null is forbidden in V1")
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        if abs(value) > 9_007_199_254_740_991:
            raise ValueError(f"{path}: integer exceeds interoperable range")
        return value
    if isinstance(value, float):
        raise ValueError(f"{path}: floating point is forbidden")
    if isinstance(value, str):
        value.encode("utf-8")
        if value != unicodedata.normalize("NFC", value) or "\r" in value:
            raise ValueError(f"{path}: string is not NFC/LF normalized")
        if key in {"createdAt", "receivedAt", "updatedAt", "decidedAt", "start", "end", "reviewedAt", "nextRetryAt", "statusCredentialExpiresAt"}:
            if not TIMESTAMP.fullmatch(value):
                raise ValueError(f"{path}: timestamp does not use UTC milliseconds")
        return value
    if isinstance(value, list):
        return [normalized(item, f"{path}[{index}]") for index, item in enumerate(value)]
    if isinstance(value, dict):
        result: OrderedDict[str, Any] = OrderedDict()
        for member in sorted(value, key=utf16_key):
            result[member] = normalized(value[member], f"{path}.{member}", member)
        return result
    raise TypeError(f"{path}: unsupported JSON type {type(value)!r}")


def canonical_bytes(value: Any) -> bytes:
    text = json.dumps(
        normalized(value),
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
    )
    return text.encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(name: str) -> tuple[bytes, Any]:
    data = (FIXTURES / f"{name}.json").read_bytes()
    return data, json.loads(data.decode("utf-8"))


def pick(value: dict[str, Any], keys: list[str]) -> dict[str, Any]:
    return {key: value[key] for key in keys if key in value}


def project_payload_v1(payload: dict[str, Any]) -> dict[str, Any]:
    projected = pick(payload, [
        "formatVersion", "reportID", "createdAt", "statement", "build",
        "platform", "evidenceWindow", "consent", "taskID", "runID",
        "runtimeSnapshot", "evidence",
    ])
    projected["statement"] = pick(projected["statement"], [
        "intendedOutcome", "actualResult", "expectedResult", "workBlocked",
    ])
    projected["build"] = pick(projected["build"], [
        "version", "build", "channel", "gitCommit", "buildDate", "source",
    ])
    projected["platform"] = pick(projected["platform"], ["macOSVersion", "architecture"])
    projected["evidenceWindow"] = pick(projected["evidenceWindow"], ["start", "end"])
    consent = pick(projected["consent"], ["version", "evidenceSelections"])
    consent["evidenceSelections"] = [
        pick(item, ["artifactID", "disclosureClass", "included", "reviewedAt"])
        for item in consent["evidenceSelections"]
    ]
    projected["consent"] = consent
    if "runtimeSnapshot" in projected:
        runtime = pick(projected["runtimeSnapshot"], [
            "runtimeID", "providerVersion", "executableFound", "readiness",
            "failureCategory", "unavailableReason", "exitCode", "stopReason",
            "stream", "sandboxState", "policyState", "sanitizedSummary",
        ])
        if "stream" in runtime:
            runtime["stream"] = pick(runtime["stream"], [
                "rawLines", "parsedEvents", "textEvents", "failedEvents",
            ])
        projected["runtimeSnapshot"] = runtime
    evidence = pick(projected["evidence"], [
        "formatVersion", "artifacts", "omissions", "warnings",
        "redactionPolicyVersion", "totalByteCount", "archiveSHA256",
    ])
    evidence["artifacts"] = [
        {
            **pick(item, [
                "artifactID", "kind", "disclosureClass", "relativePath",
                "mediaType", "byteCount", "sha256", "redaction",
            ]),
            "redaction": pick(item["redaction"], [
                "replacements", "secretPatterns", "pathPatterns", "contactPatterns",
            ]),
        }
        for item in evidence["artifacts"]
    ]
    evidence["omissions"] = [
        pick(item, ["artifactID", "kind", "reason", "detail"])
        for item in evidence["omissions"]
    ]
    evidence["warnings"] = [
        pick(item, ["code", "artifactID", "message"])
        for item in evidence["warnings"]
    ]
    projected["evidence"] = evidence
    return projected


def verify_golden(name: str) -> Any:
    data, value = read_json(name)
    if canonical_bytes(value) != data:
        raise ValueError(f"{name}.json does not contain canonical bytes")
    expected = (FIXTURES / f"{name}.sha256").read_text(encoding="ascii")
    if sha256(data) != expected:
        raise ValueError(f"{name}.sha256 does not match")
    return value


def verify_request(request: dict[str, Any]) -> None:
    payload = request["payload"]
    payload_hash = sha256(canonical_bytes(project_payload_v1(payload)))
    if payload_hash != request["payloadSHA256"]:
        raise ValueError("payloadSHA256 does not cover canonical payload bytes")
    expected_payload_hash = (FIXTURES / "payload.sha256").read_text(encoding="ascii")
    if payload_hash != expected_payload_hash:
        raise ValueError("payload.sha256 does not match")

    artifacts = payload["evidence"]["artifacts"]
    ordered = sorted(artifacts, key=lambda item: (item["relativePath"].encode("utf-8"), item["artifactID"].encode("utf-8")))
    if artifacts != ordered:
        raise ValueError("evidence artifacts are not in canonical order")

    lines = [
        "astra-feedback-digest-v1",
        f"formatVersion={request['formatVersion']}",
        f"payloadSHA256={request['payloadSHA256']}",
        f"redactionPolicyVersion={payload['evidence']['redactionPolicyVersion']}",
        f"evidenceArchiveSHA256={request.get('evidenceArchiveSHA256', '-')}",
    ]
    lines.extend(f"artifact={item['artifactID']}:{item['sha256']}" for item in artifacts)
    digest = sha256(("\n".join(lines) + "\n").encode("utf-8"))
    if digest != request["canonicalDigestSHA256"]:
        raise ValueError("canonicalDigestSHA256 does not match V1 framing")


def main() -> None:
    documents = {name: verify_golden(name) for name in GOLDENS}
    verify_request(documents["request"])
    print("feedback V1 fixtures verified: " + ", ".join(GOLDENS))


if __name__ == "__main__":
    main()
