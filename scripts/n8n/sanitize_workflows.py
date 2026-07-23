#!/usr/bin/env python3
"""Sanitize n8n workflow exports before they are ever transferred to the
public demo instance.

Input: a directory of workflow JSON files produced by
    n8n export:workflow --all --separate --output=<dir>
(one file per workflow, the shape n8n's CLI actually writes for the pinned
1.102.4 image).

Output: a directory of sanitized workflow JSON files, safe to hand to
scripts/n8n/validate_demo_workflows.py and then import into the demo instance.

Fails closed: any workflow file that contains something that looks like a
secret but isn't safely auto-redactable (see sanitization_common.py) aborts
the whole run with a non-zero exit code instead of silently publishing it.
Never prints workflow contents to stdout/stderr (CI-safe).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sanitization_common import (  # noqa: E402
    REDACTED,
    SENSITIVE_KEYS_NORMALIZED,
    load_config,
    load_workflow_files,
    normalize_key,
    scan_for_unsafe_content,
    write_stable_json,
)


class SanitizationError(Exception):
    """Raised when the sanitizer finds something it refuses to auto-fix."""


class Counters:
    def __init__(self) -> None:
        self.files_processed = 0
        self.workflows_processed = 0
        self.nodes_processed = 0
        self.credential_refs_removed = 0
        self.fields_redacted = 0
        self.webhook_ids_removed = 0
        self.domains_replaced = 0
        self.validation_failures: list[str] = []

    def as_dict(self) -> dict:
        return {
            "files_processed": self.files_processed,
            "workflows_processed": self.workflows_processed,
            "nodes_processed": self.nodes_processed,
            "credential_refs_removed": self.credential_refs_removed,
            "fields_redacted": self.fields_redacted,
            "webhook_ids_removed": self.webhook_ids_removed,
            "domains_replaced": self.domains_replaced,
            "validation_failures": self.validation_failures,
        }


def replace_domains_in_strings(obj: Any, replacement_values: dict, counters: Counters) -> Any:
    """Deep-copy `obj`, replacing any configured domain substring found in a
    string leaf with its configured replacement. Deterministic, not a guess."""
    if isinstance(obj, str):
        new_val = obj
        for domain, replacement in replacement_values.items():
            if domain and domain in new_val:
                new_val = new_val.replace(domain, replacement)
                counters.domains_replaced += 1
        return new_val
    if isinstance(obj, dict):
        return {k: replace_domains_in_strings(v, replacement_values, counters) for k, v in obj.items()}
    if isinstance(obj, list):
        return [replace_domains_in_strings(v, replacement_values, counters) for v in obj]
    return obj


def redact_sensitive_keys(obj: Any, counters: Counters) -> Any:
    """Deep-copy `obj`, redacting values of structurally-sensitive keys.

    Two matching modes, both structural (never a blind substring match on
    the string *content*):
      1. dict key itself normalizes to a known-sensitive name
         -> redact that key's string value.
      2. n8n "fixedCollection" header/param pattern: {"name": X, "value": Y}
         -> if X normalizes to a known-sensitive name, redact Y.
    """
    if isinstance(obj, dict):
        # Pattern 2: {"name": ..., "value": ...} pairs used for HTTP headers,
        # query params, etc. in n8n node parameters.
        if (
            set(obj.keys()) >= {"name", "value"}
            and isinstance(obj.get("name"), str)
            and normalize_key(obj["name"]) in SENSITIVE_KEYS_NORMALIZED
        ):
            new_obj = dict(obj)
            if isinstance(new_obj.get("value"), str):
                new_obj["value"] = REDACTED
                counters.fields_redacted += 1
            return {k: redact_sensitive_keys(v, counters) if k != "value" else v for k, v in new_obj.items()}

        result = {}
        for k, v in obj.items():
            if normalize_key(k) in SENSITIVE_KEYS_NORMALIZED and isinstance(v, str):
                result[k] = REDACTED
                counters.fields_redacted += 1
            else:
                result[k] = redact_sensitive_keys(v, counters)
        return result
    if isinstance(obj, list):
        return [redact_sensitive_keys(v, counters) for v in obj]
    return obj


def sanitize_workflow(data: dict, filename: str, config: dict, counters: Counters) -> dict:
    if not isinstance(data, dict):
        raise SanitizationError(f"{filename}: expected a JSON object, got {type(data).__name__}")

    workflow = dict(data)

    # 1. Force inactive.
    workflow["active"] = False

    # 2-4. Strip execution/runtime/ownership metadata that must not transfer.
    for key in (
        "pinData",
        "staticData",
        "versionId",
        "id",
        "meta",
        "tags",
        "shared",
        "ownedBy",
        "homeProject",
        "sharedWithProjects",
        "usedCredentials",
    ):
        workflow.pop(key, None)

    nodes = workflow.get("nodes", [])
    if not isinstance(nodes, list):
        raise SanitizationError(f"{filename}: 'nodes' is not a list")

    new_nodes = []
    for node in nodes:
        if not isinstance(node, dict):
            raise SanitizationError(f"{filename}: node entry is not an object")
        node = dict(node)
        counters.nodes_processed += 1

        creds = node.pop("credentials", None)
        if creds:
            counters.credential_refs_removed += len(creds) if isinstance(creds, dict) else 1

        if "webhookId" in node:
            del node["webhookId"]
            counters.webhook_ids_removed += 1

        if "parameters" in node:
            node["parameters"] = redact_sensitive_keys(node["parameters"], counters)
            node["parameters"] = replace_domains_in_strings(
                node["parameters"], config.get("replacement_values", {}), counters
            )

        new_nodes.append(node)

    workflow["nodes"] = new_nodes

    # Also sweep top-level string fields (e.g. workflow name/notes) for
    # configured domain replacements.
    workflow = replace_domains_in_strings(workflow, config.get("replacement_values", {}), counters)

    problems = scan_for_unsafe_content(workflow, config, workflow.get("name", filename))
    if problems:
        raise SanitizationError(
            f"{filename}: refusing to sanitize, found {len(problems)} unresolved risk(s):\n"
            + "\n".join(f"  - {p}" for p in problems)
        )

    return workflow


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "config" / "n8n-demo-sanitization.json",
    )
    parser.add_argument("--summary-out", type=Path, default=None)
    args = parser.parse_args()

    config = load_config(args.config)
    counters = Counters()

    try:
        files = load_workflow_files(args.input)
    except ValueError as exc:
        print(f"sanitize_workflows: {exc}", file=sys.stderr)
        return 1

    if not files:
        print("sanitize_workflows: no workflow JSON files found in input directory", file=sys.stderr)
        return 1

    args.output.mkdir(parents=True, exist_ok=True)

    for path, data in files:
        counters.files_processed += 1
        try:
            sanitized = sanitize_workflow(data, path.name, config, counters)
        except SanitizationError as exc:
            counters.validation_failures.append(str(exc))
            print(f"sanitize_workflows: FAILED on {path.name}", file=sys.stderr)
            print(str(exc), file=sys.stderr)
            return 1
        counters.workflows_processed += 1
        write_stable_json(sanitized, args.output / path.name)

    summary = counters.as_dict()
    summary_json = json.dumps(summary, indent=2, sort_keys=True)
    if args.summary_out:
        args.summary_out.write_text(summary_json + "\n", encoding="utf-8")
    print(summary_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
