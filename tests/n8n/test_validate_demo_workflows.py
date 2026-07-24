
from validate_demo_workflows import validate_workflow

BASE_CONFIG = {
    "blocked_domains": ["n8n.ai-automation-platform.com"],
    "blocked_ip_addresses": ["10.0.5.5"],
    "blocked_email_addresses": ["owner@ai-automation-platform.com"],
    "blocked_patterns": [],
    "allowed_values": [],
    "replacement_values": {"n8n.ai-automation-platform.com": "demo-n8n.ai-automation-platform.invalid"},
}


def make_sanitized_workflow(nodes, active=False, extra=None):
    wf = {"name": "Test Workflow", "active": active, "nodes": nodes, "connections": {}}
    if extra:
        wf.update(extra)
    return wf


def test_active_true_is_rejected():
    problems = validate_workflow(make_sanitized_workflow([], active=True), "wf.json", BASE_CONFIG)
    assert any("not explicitly inactive" in p for p in problems)


def test_clean_inactive_workflow_passes():
    node = {"name": "Set", "type": "n8n-nodes-base.set", "parameters": {"value": "hello"}}
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert problems == []


def test_credential_reference_is_rejected():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {},
        "credentials": {"httpHeaderAuth": {"id": "1", "name": "cred"}},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("still references a credential" in p for p in problems)


def test_webhook_id_is_rejected():
    node = {"name": "Webhook", "type": "n8n-nodes-base.webhook", "parameters": {}, "webhookId": "abc"}
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("still has a webhookId" in p for p in problems)


def test_pin_data_leftover_is_rejected():
    wf = make_sanitized_workflow([], extra={"pinData": {"Node": [{"json": {}}]}})
    problems = validate_workflow(wf, "wf.json", BASE_CONFIG)
    assert any("pinData" in p for p in problems)


def test_env_expression_is_rejected():
    node = {"name": "Set", "type": "n8n-nodes-base.set", "parameters": {"value": "={{$env.SECRET_KEY}}"}}
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("$env expression" in p for p in problems)


def test_production_domain_without_replacement_is_rejected():
    config = dict(BASE_CONFIG)
    config["blocked_domains"] = ["n8n.ai-automation-platform.com"]
    config["replacement_values"] = {}
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {"url": "https://n8n.ai-automation-platform.com/webhook/abc"},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", config)
    assert any("blocked domain" in p for p in problems)


def test_bearer_token_value_is_rejected():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {"headerParameters": {"parameters": [{"name": "X-Custom", "value": "Bearer abcdef123456ghijkl"}]}},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("hard-coded secret" in p for p in problems)


def test_private_key_block_is_rejected():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"note": "-----BEGIN PRIVATE KEY-----\nMIIEvQ..."},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("hard-coded secret" in p for p in problems)


def test_aws_metadata_reference_is_rejected():
    node = {
        "name": "HTTP Request",
        "type": "n8n-nodes-base.httpRequest",
        "parameters": {"url": "http://169.254.169.254/latest/meta-data/"},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("AWS metadata" in p for p in problems)


def test_dangerous_shell_command_is_rejected():
    node = {
        "name": "Execute Command",
        "type": "n8n-nodes-base.executeCommand",
        "parameters": {"command": "rm -rf /"},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("suspicious shell command" in p for p in problems)


def test_legitimate_expression_with_word_token_is_not_rejected():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"value": "={{$json.tokenCount}} items processed"},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert problems == []


def test_nested_array_private_ip_is_rejected():
    node = {
        "name": "Set",
        "type": "n8n-nodes-base.set",
        "parameters": {"assignments": {"assignments": [{"name": "host", "value": "10.0.5.5"}]}},
    }
    problems = validate_workflow(make_sanitized_workflow([node]), "wf.json", BASE_CONFIG)
    assert any("IP address" in p for p in problems)
