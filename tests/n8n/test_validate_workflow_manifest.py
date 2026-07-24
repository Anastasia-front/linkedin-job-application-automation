import json
from validate_workflow_manifest import validate

def write_json(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


def make_workflow(tmp_path, filename, workflow_id, name="Test Workflow"):
    write_json(tmp_path / filename, {"id": workflow_id, "name": name, "nodes": []})


def make_manifest(tmp_path, entries, filename="manifest.json"):
    manifest_path = tmp_path / filename
    write_json(manifest_path, {"environment": "production", "workflows": entries})
    return manifest_path


# 1. No workflow files found.
def test_no_workflow_files_found(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    manifest = make_manifest(tmp_path, [{"id": "abc123", "file": "missing.json", "name": "X"}])

    errors = validate(manifest, workflow_dir)

    assert any("no workflow JSON files found" in e for e in errors)


# 2. Invalid JSON workflow.
def test_invalid_json_workflow(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    (workflow_dir / "broken.json").write_text("{not valid json", encoding="utf-8")
    manifest = make_manifest(tmp_path, [{"id": "abc123", "file": "broken.json", "name": "X"}])

    errors = validate(manifest, workflow_dir)

    assert any("is not valid JSON" in e for e in errors)


# 3. Duplicate workflow IDs in the repository.
def test_duplicate_workflow_ids(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    make_workflow(workflow_dir, "one.json", "dup-id")
    make_workflow(workflow_dir, "two.json", "dup-id")
    manifest = make_manifest(
        tmp_path,
        [
            {"id": "dup-id", "file": "one.json", "name": "One"},
            {"id": "dup-id", "file": "two.json", "name": "Two"},
        ],
    )

    errors = validate(manifest, workflow_dir)

    assert any("duplicate workflow id" in e for e in errors)


# 4. Workflow missing deterministic ID.
def test_workflow_missing_deterministic_id(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    write_json(workflow_dir / "no-id.json", {"name": "No Id", "nodes": []})
    manifest = make_manifest(tmp_path, [{"id": "expected-id", "file": "no-id.json", "name": "No Id"}])

    errors = validate(manifest, workflow_dir)

    assert any("has no deterministic 'id' field" in e for e in errors)


def test_manifest_entry_missing_id_field(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    make_workflow(workflow_dir, "one.json", "abc123")
    manifest = make_manifest(tmp_path, [{"file": "one.json", "name": "X"}])

    errors = validate(manifest, workflow_dir)

    assert any("missing a non-empty string 'id'" in e for e in errors)


def test_manifest_references_missing_file(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    # Another real file must exist so validation reaches the per-entry check
    # instead of short-circuiting on "no workflow JSON files found" first.
    make_workflow(workflow_dir, "other.json", "other-id")
    manifest = make_manifest(tmp_path, [{"id": "abc123", "file": "does-not-exist.json", "name": "X"}])

    errors = validate(manifest, workflow_dir)

    assert any("references missing file" in e for e in errors)


def test_valid_manifest_passes_with_no_fatal_errors(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    make_workflow(workflow_dir, "one.json", "abc123", "One")
    manifest = make_manifest(tmp_path, [{"id": "abc123", "file": "one.json", "name": "One"}])

    errors = validate(manifest, workflow_dir)

    assert errors == []


def test_unmanaged_file_is_a_warning_not_a_fatal_error(tmp_path):
    workflow_dir = tmp_path / "workflows"
    workflow_dir.mkdir()
    make_workflow(workflow_dir, "managed.json", "abc123", "Managed")
    make_workflow(workflow_dir, "unmanaged.json", "def456", "Unmanaged")
    manifest = make_manifest(tmp_path, [{"id": "abc123", "file": "managed.json", "name": "Managed"}])

    errors = validate(manifest, workflow_dir)

    assert len(errors) == 1
    assert "not listed in the manifest" in errors[0]
    assert "unmanaged.json" in errors[0]
