import json

import pytest
from sanitize_workflows import Counters, SanitizationError, sanitize_workflow, main as sanitize_main


BASE_CONFIG = {
    "blocked_domains": ["n8n.ai-automation-platform.com"],
    "blocked_ip_addresses": [],
    "blocked_email_addresses": [],
    "blocked_patterns": [],
    "allowed_values": [],
    "replacement_values": {"n8n.ai-automation-platform.com": "demo-n8n.ai-automation-platform.invalid"},
}


def make_workflow(nodes, active=True, extra=None):
    wf = {
        "name": "Test Workflow",
        "active": active,
        "nodes": nodes,
        "connections": {},
        "settings": {},
    }
    if extra:
        wf.update(extra)
    return wf


def test_active_workflow_becomes_inactive():
    wf = make_workflow([], active=True)
    result = sanitize_workflow(wf, "wf.json", BASE_CONFIG, Counters())
    assert result["active"] is False


def test_credential_references_removed():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {},
        "credentials": {"httpHeaderAuth": {"id": "12", "name": "Some Credential"}},
    }
    counters = Counters()
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, counters)
    assert "credentials" not in result["nodes"][0]
    assert counters.credential_refs_removed == 1


def test_webhook_id_removed():
    node = {
        "name": "Webhook",
        "type": "n8n-nodes-base.webhook",
        "parameters": {"path": "abc"},
        "webhookId": "11111111-1111-1111-1111-111111111111",
    }
    counters = Counters()
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, counters)
    assert "webhookId" not in result["nodes"][0]
    assert counters.webhook_ids_removed == 1


def test_pin_data_removed():
    wf = make_workflow([], extra={"pinData": {"SomeNode": [{"json": {"secret": "x"}}]}})
    result = sanitize_workflow(wf, "wf.json", BASE_CONFIG, Counters())
    assert "pinData" not in result


def test_nested_http_header_redacted():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {
            "sendHeaders": True,
            "headerParameters": {
                "parameters": [
                    {"name": "Authorization", "value": "Bearer super-secret-token-value"},
                    {"name": "X-Custom", "value": "not-sensitive"},
                ]
            },
        },
    }
    counters = Counters()
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, counters)
    headers = result["nodes"][0]["parameters"]["headerParameters"]["parameters"]
    assert headers[0]["value"] == "[REDACTED]"
    assert headers[1]["value"] == "not-sensitive"
    assert counters.fields_redacted >= 1


def test_code_node_content_preserved_when_clean():
    node = {
        "name": "Code",
        "type": "n8n-nodes-base.code",
        "parameters": {"jsCode": "return items.map(i => ({ json: { total: i.json.amount * 2 } }));"},
    }
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())
    assert result["nodes"][0]["parameters"]["jsCode"] == node["parameters"]["jsCode"]


def test_expressions_preserved():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"values": {"string": [{"name": "id", "value": "={{$json.id}}"}]}},
    }
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())
    assert result["nodes"][0]["parameters"]["values"]["string"][0]["value"] == "={{$json.id}}"


def test_legitimate_token_named_field_not_redacted():
    # "tokenLimit" must NOT be treated as sensitive just because it contains "token".
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"tokenLimit": 4096, "apiKeyName": "not-a-secret-value"},
    }
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())
    assert result["nodes"][0]["parameters"]["tokenLimit"] == 4096
    assert result["nodes"][0]["parameters"]["apiKeyName"] == "not-a-secret-value"


def test_production_url_replaced():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {"url": "https://n8n.ai-automation-platform.com/webhook/abc"},
    }
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())
    assert "n8n.ai-automation-platform.com" not in result["nodes"][0]["parameters"]["url"]
    assert "demo-n8n.ai-automation-platform.invalid" in result["nodes"][0]["parameters"]["url"]


def test_hardcoded_api_key_fails_closed():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"note": 'api_key: "sk-live-abcdefghijklmnop1234567890"'},
    }
    with pytest.raises(SanitizationError):
        sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())


def test_private_key_block_fails_closed():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"note": "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJ..."},
    }
    with pytest.raises(SanitizationError):
        sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, Counters())


def test_arrays_and_nested_structures_are_walked():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {
            "assignments": {
                "assignments": [
                    {"id": "1", "name": "password", "value": "hunter2", "type": "string"},
                    {"id": "2", "name": "count", "value": 3, "type": "number"},
                ]
            }
        },
    }
    counters = Counters()
    result = sanitize_workflow(make_workflow([node]), "wf.json", BASE_CONFIG, counters)
    assignments = result["nodes"][0]["parameters"]["assignments"]["assignments"]
    assert assignments[0]["value"] == "[REDACTED]"
    assert assignments[1]["value"] == 3
    assert counters.fields_redacted >= 1


def test_malformed_json_fails_closed(tmp_path):
    input_dir = tmp_path / "in"
    output_dir = tmp_path / "out"
    input_dir.mkdir()
    (input_dir / "broken.json").write_text("{not valid json")
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(BASE_CONFIG))

    import sys as _sys

    old_argv = _sys.argv
    try:
        _sys.argv = [
            "sanitize_workflows.py",
            "--input",
            str(input_dir),
            "--output",
            str(output_dir),
            "--config",
            str(config_path),
        ]
        rc = sanitize_main()
    finally:
        _sys.argv = old_argv

    assert rc == 1
    assert not list(output_dir.glob("*.json"))


def test_end_to_end_sanitize_writes_stable_json(tmp_path):
    input_dir = tmp_path / "in"
    output_dir = tmp_path / "out"
    input_dir.mkdir()
    wf = make_workflow(
        [
            {
                "name": "Webhook",
                "type": "n8n-nodes-base.webhook",
                "parameters": {"path": "abc"},
                "webhookId": "11111111-1111-1111-1111-111111111111",
                "credentials": {"httpHeaderAuth": {"id": "1", "name": "cred"}},
            }
        ],
        active=True,
    )
    (input_dir / "wf1.json").write_text(json.dumps(wf))
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(BASE_CONFIG))

    import sys as _sys

    old_argv = _sys.argv
    try:
        _sys.argv = [
            "sanitize_workflows.py",
            "--input",
            str(input_dir),
            "--output",
            str(output_dir),
            "--config",
            str(config_path),
        ]
        rc = sanitize_main()
    finally:
        _sys.argv = old_argv

    assert rc == 0
    out_file = output_dir / "wf1.json"
    assert out_file.exists()
    data = json.loads(out_file.read_text())
    assert data["active"] is False
    assert "webhookId" not in data["nodes"][0]
    assert "credentials" not in data["nodes"][0]
