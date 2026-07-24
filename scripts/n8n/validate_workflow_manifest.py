#!/usr/bin/env python3
"""Validate a repository-managed workflow manifest before it is seeded into n8n.

Used by:
  - CI `validate` jobs, as a static pre-flight gate.
  - deploy/scripts/seed-n8n-workflows.sh, as a pre-import gate on the remote host
    (the same file runs unmodified there; stdlib only, no dependencies).

A manifest is the source of truth for which workflow JSON files under a given
directory are repository-managed. It exists so seeding can be idempotent and
scoped: only files listed in the manifest are imported/verified, and every
manifest entry must resolve to exactly one workflow file with a matching,
unique, deterministic `id`.

Exit codes: 0 on success, 1 on any validation failure. Errors are printed to
stderr, one per line, and are collected (not fail-fast) so a single run
reports every problem at once.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class ManifestError(Exception):
    pass


def load_manifest(manifest_path: Path) -> dict[str, Any]:
    if not manifest_path.is_file():
        raise ManifestError(f"manifest not found: {manifest_path}")
    try:
        raw = manifest_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ManifestError(f"could not read manifest {manifest_path}: {exc}") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestError(f"manifest {manifest_path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ManifestError(f"manifest {manifest_path} must be a JSON object")
    return data


def validate(manifest_path: Path, workflow_dir: Path) -> list[str]:
    errors: list[str] = []

    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as exc:
        return [str(exc)]

    entries = manifest.get("workflows")
    if not isinstance(entries, list) or len(entries) == 0:
        errors.append(f"manifest {manifest_path} has no workflow entries")
        return errors

    if not workflow_dir.is_dir():
        errors.append(f"workflow directory not found: {workflow_dir}")
        return errors

    disk_files = sorted(p for p in workflow_dir.glob("*.json") if p.name != manifest_path.name)
    if not disk_files:
        errors.append(f"no workflow JSON files found in {workflow_dir}")
        return errors

    seen_manifest_ids: dict[str, str] = {}
    seen_file_ids: dict[str, str] = {}

    for i, entry in enumerate(entries):
        ctx = f"manifest entry #{i}"
        if not isinstance(entry, dict):
            errors.append(f"{ctx} is not an object")
            continue

        entry_id = entry.get("id")
        file_name = entry.get("file")
        name = entry.get("name")

        if not entry_id or not isinstance(entry_id, str):
            errors.append(f"{ctx} ({name or file_name or '?'}) is missing a non-empty string 'id'")
            continue
        if not file_name or not isinstance(file_name, str):
            errors.append(f"{ctx} (id={entry_id}) is missing a non-empty string 'file'")
            continue

        if entry_id in seen_manifest_ids:
            errors.append(
                f"duplicate workflow id '{entry_id}' in manifest "
                f"(entries for '{seen_manifest_ids[entry_id]}' and '{file_name}')"
            )
        else:
            seen_manifest_ids[entry_id] = file_name

        workflow_path = workflow_dir / file_name
        if not workflow_path.is_file():
            errors.append(f"manifest entry id={entry_id} references missing file: {workflow_path}")
            continue

        try:
            workflow_json = json.loads(workflow_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"{workflow_path} is not valid JSON: {exc}")
            continue

        if not isinstance(workflow_json, dict):
            errors.append(f"{workflow_path} must contain a JSON object")
            continue

        file_id = workflow_json.get("id")
        if not file_id or not isinstance(file_id, str):
            errors.append(f"{workflow_path} has no deterministic 'id' field")
            continue

        if file_id != entry_id:
            errors.append(
                f"{workflow_path} id '{file_id}' does not match manifest id '{entry_id}'"
            )

        if file_id in seen_file_ids:
            errors.append(
                f"duplicate workflow id '{file_id}' on disk "
                f"(files '{seen_file_ids[file_id]}' and '{file_name}')"
            )
        else:
            seen_file_ids[file_id] = file_name

    manifest_files = {e.get("file") for e in entries if isinstance(e, dict) and e.get("file")}
    disk_names = {p.name for p in disk_files}
    unmanaged = sorted(disk_names - manifest_files)
    if unmanaged:
        errors.append(
            "workflow file(s) present on disk but not listed in the manifest "
            f"(will be left untouched, not seeded): {', '.join(unmanaged)}"
        )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--workflow-dir", required=True, type=Path)
    args = parser.parse_args()

    errors = validate(args.manifest, args.workflow_dir)
    if errors:
        for err in errors:
            # The "unmanaged file" case is informational, not fatal.
            prefix = "WARN" if err.startswith("workflow file(s) present") else "ERROR"
            print(f"{prefix}: {err}", file=sys.stderr)
        fatal = [e for e in errors if not e.startswith("workflow file(s) present")]
        return 1 if fatal else 0

    print(f"OK: manifest {args.manifest} validated against {args.workflow_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
