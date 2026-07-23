#!/usr/bin/env python3
"""Second, independent gate over sanitized workflow files before they are
imported into the public demo instance. Deliberately separate from
sanitize_workflows.py so a bug in the sanitizer does not also blind the
check that is supposed to catch it.

Exits non-zero (and prints a machine-readable JSON report to stdout) if any
sanitized workflow:
  - is active
  - still references a credential
  - still has a webhookId
  - contains a production hostname/IP/email from the denylist
  - contains what looks like a hard-coded secret, Bearer/Basic auth header,
    private key block, or other high-confidence secret pattern
  - references the AWS metadata endpoint
  - references a dangerous filesystem path or a suspicious shell command
  - uses $env expressions
  - has pinData / staticData left over
Never prints workflow contents, only file names and problem descriptions.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sanitization_common import (  # noqa: E402
    ENV_EXPRESSION_PATTERN,
    iter_dicts,
    iter_strings,
    load_config,
    load_workflow_files,
    scan_for_unsafe_content,
)


def validate_workflow(data: Any, filename: str, config: dict) -> list[str]:
    problems: list[str] = []

    if not isinstance(data, dict):
        return [f"{filename}: not a JSON object"]

    label = data.get("name", filename)

    if data.get("active") is not False:
        problems.append(f"{filename}: workflow '{label}' is not explicitly inactive (active={data.get('active')!r})")

    for leftover in ("pinData", "staticData", "shared", "ownedBy", "homeProject", "sharedWithProjects"):
        if data.get(leftover):
            problems.append(f"{filename}: leftover '{leftover}' field was not stripped")

    nodes = data.get("nodes", [])
    if isinstance(nodes, list):
        for node in nodes:
            if not isinstance(node, dict):
                problems.append(f"{filename}: non-object node entry")
                continue
            node_name = node.get("name", "<unnamed node>")
            if "credentials" in node and node["credentials"]:
                problems.append(f"{filename}: node '{node_name}' still references a credential")
            if "webhookId" in node:
                problems.append(f"{filename}: node '{node_name}' still has a webhookId")
    else:
        problems.append(f"{filename}: 'nodes' is not a list")

    for d in iter_dicts(data):
        creds = d.get("credentials") if isinstance(d, dict) else None
        if creds and d is not data:
            # Already caught per-node above; this also catches any
            # unexpected credential-shaped structure elsewhere in the file.
            if "nodes" not in d:
                problems.append(f"{filename}: unexpected credential-shaped structure found outside 'nodes'")

    for s in iter_strings(data):
        if ENV_EXPRESSION_PATTERN.search(s):
            problems.append(f"{filename}: workflow '{label}' contains a $env expression")

    problems.extend(scan_for_unsafe_content(data, config, f"{filename} ({label})"))

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "config" / "n8n-demo-sanitization.json",
    )
    parser.add_argument("--report-out", type=Path, default=None)
    args = parser.parse_args()

    config = load_config(args.config)

    try:
        files = load_workflow_files(args.input)
    except ValueError as exc:
        print(f"validate_demo_workflows: {exc}", file=sys.stderr)
        return 1

    if not files:
        print("validate_demo_workflows: no sanitized workflow files found", file=sys.stderr)
        return 1

    all_problems: list[str] = []
    for path, data in files:
        all_problems.extend(validate_workflow(data, path.name, config))

    report = {
        "files_checked": len(files),
        "problems_found": len(all_problems),
        "problems": all_problems,
    }
    report_json = json.dumps(report, indent=2, sort_keys=True)
    if args.report_out:
        args.report_out.write_text(report_json + "\n", encoding="utf-8")
    print(report_json)

    return 1 if all_problems else 0


if __name__ == "__main__":
    sys.exit(main())
