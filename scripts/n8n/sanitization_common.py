"""Shared helpers for scripts/n8n/sanitize_workflows.py and validate_demo_workflows.py.

Kept dependency-free (stdlib only) so it runs unmodified in CI, on the
production/demo EC2 hosts, and under pytest.
"""
from __future__ import annotations

import ipaddress
import json
import re
from pathlib import Path
from typing import Any, Iterable

# Sensitive parameter/header key names. Matching is done on a *normalized*
# key (lowercased, separators stripped) so "client_secret", "clientSecret"
# and "Client-Secret" all match, while "tokenLimit" or "apiKeyName" do NOT
# match "token"/"apiKey" — normalization matches on equality, not substring,
# so legitimate keys that merely contain a sensitive word are left alone.
SENSITIVE_KEYS = [
    "authorization",
    "proxy-authorization",
    "x-api-key",
    "api-key",
    "api_key",
    "apikey",
    "password",
    "passwd",
    "secret",
    "client_secret",
    "clientSecret",
    "access_token",
    "accessToken",
    "refresh_token",
    "refreshToken",
    "token",
    "bearer",
    "private_key",
    "privateKey",
    "webhook_secret",
    "signing_secret",
]


def normalize_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.lower())


SENSITIVE_KEYS_NORMALIZED = {normalize_key(k) for k in SENSITIVE_KEYS}

REDACTED = "[REDACTED]"

# High-confidence secret *value* shapes. These are used by the validator
# (and by the sanitizer's fail-closed pre-check) to catch secrets that were
# NOT caught by key-based redaction, e.g. a hard-coded value in a generic
# "value" field. Deliberately narrow to avoid false-positives on ordinary
# workflow expressions such as {{$json.token}}.
SECRET_VALUE_PATTERNS = {
    "aws_access_key_id": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "private_key_block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "bearer_header_value": re.compile(r"\bBearer\s+[A-Za-z0-9\-_.=]{10,}\b"),
    "basic_auth_header_value": re.compile(r"\bBasic\s+[A-Za-z0-9+/=]{10,}\b"),
    "generic_long_secret_assignment": re.compile(
        r"(?i)\b(secret|password|token|api[_-]?key)\b\s*[:=]\s*['\"][A-Za-z0-9\-_./+=]{12,}['\"]"
    ),
    "slack_token": re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"),
    "generic_jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
}

AWS_METADATA_PATTERNS = [
    re.compile(r"169\.254\.169\.254"),
    re.compile(r"\bfd00:ec2::254\b"),
]

DANGEROUS_PATH_PATTERNS = [
    re.compile(r"(?<![\w./])/etc/(?:passwd|shadow|ssh)\b"),
    re.compile(r"(?<![\w./])~?/\.ssh/"),
    re.compile(r"(?<![\w./])/root/"),
    re.compile(r"(?<![\w./])/proc/self/environ"),
]

SUSPICIOUS_SHELL_PATTERNS = [
    re.compile(r"\brm\s+-rf\s+/"),
    re.compile(r"\bcurl\b[^\n]*169\.254\.169\.254"),
    re.compile(r"\bwget\b[^\n]*169\.254\.169\.254"),
    re.compile(r":\(\)\s*\{\s*:\|:&\s*\};:"),  # fork bomb
]

ENV_EXPRESSION_PATTERN = re.compile(r"\$env(?:\.|(?:\[)|\s*\[)")

PRIVATE_IP_NETWORKS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
]

IPV4_PATTERN = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")


def is_private_ip(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return any(ip in net for net in PRIVATE_IP_NETWORKS)


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    cfg.setdefault("blocked_domains", [])
    cfg.setdefault("blocked_ip_addresses", [])
    cfg.setdefault("blocked_email_addresses", [])
    cfg.setdefault("blocked_patterns", [])
    cfg.setdefault("allowed_values", [])
    cfg.setdefault("replacement_values", {})
    return cfg


def load_workflow_files(input_dir: Path) -> list[tuple[Path, Any]]:
    """Load every *.json file. Raises ValueError (fail closed) on the first
    malformed file, naming the file so the pipeline failure is actionable."""
    files = sorted(input_dir.glob("*.json"))
    results = []
    for f in files:
        try:
            with f.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Malformed JSON in {f}: {exc}") from exc
        results.append((f, data))
    return results


def iter_dicts(node: Any) -> Iterable[dict]:
    """Yield every dict found anywhere within a nested JSON structure."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from iter_dicts(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_dicts(item)


def iter_strings(node: Any):
    """Yield every string leaf found anywhere within a nested JSON structure."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from iter_strings(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_strings(item)


def write_stable_json(obj: Any, path: Path) -> None:
    with path.open("w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")


def scan_for_unsafe_content(obj: Any, config: dict, label: str) -> list[str]:
    """Shared risk scan used by both the sanitizer (fail-closed pre-check)
    and the validator (independent second gate). Returns human-readable
    problem descriptions; a non-empty list must abort the pipeline."""
    problems: list[str] = []
    allowed = set(config.get("allowed_values", []))

    for s in iter_strings(obj):
        if s in allowed:
            continue

        for pat_label, pattern in SECRET_VALUE_PATTERNS.items():
            if pattern.search(s):
                problems.append(f"{label}: possible hard-coded secret ({pat_label})")

        for domain in config.get("blocked_domains", []):
            if domain and domain in s and domain not in config.get("replacement_values", {}):
                problems.append(f"{label}: blocked domain '{domain}' with no configured replacement")

        for pattern in AWS_METADATA_PATTERNS:
            if pattern.search(s):
                problems.append(f"{label}: AWS metadata endpoint reference")

        for pattern in DANGEROUS_PATH_PATTERNS:
            if pattern.search(s):
                problems.append(f"{label}: dangerous filesystem path reference")

        for pattern in SUSPICIOUS_SHELL_PATTERNS:
            if pattern.search(s):
                problems.append(f"{label}: suspicious shell command pattern")

        for ip in IPV4_PATTERN.findall(s):
            if ip in allowed or ip in config.get("replacement_values", {}):
                continue
            if is_private_ip(ip) and ip not in config.get("blocked_ip_addresses", []):
                problems.append(f"{label}: private IP address '{ip}' found")
            elif ip in config.get("blocked_ip_addresses", []):
                problems.append(f"{label}: blocked IP address '{ip}' found")

        for pattern_str in config.get("blocked_patterns", []):
            if pattern_str and pattern_str in s:
                problems.append(f"{label}: blocked pattern matched")

        for email in config.get("blocked_email_addresses", []):
            if email and email in s:
                problems.append(f"{label}: blocked email address found")

    return problems
