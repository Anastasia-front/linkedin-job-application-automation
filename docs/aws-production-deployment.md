# AWS Production Deployment

This project runs n8n at:

https://n8n.ai-automation-platform.com

## Architecture

Cloudflare proxied DNS routes to a dedicated EC2 Elastic IP. Nginx listens on ports 80 and 443, terminates the Cloudflare Origin Certificate, and proxies to n8n on `127.0.0.1:5678`. Port 5678 is never publicly exposed.

## Terraform

Terraform lives in `infra/` and creates:

- EC2 instance
- persistent Elastic IP and association
- security group
- IAM role and instance profile
- narrow SSM read policy for the instance
- SSM SecureString parameters for n8n environment values
- SSM SecureString parameters for the Cloudflare Origin Certificate and private key

The default AWS region is `eu-central-1`.

Do not commit real `terraform.tfvars` files. Use `infra/terraform.tfvars.example` as the shape only.

## SSM Parameters

Application environment:

`/linkedin-job-application-automation/env/`

Required production values include:

- `NODE_ENV=production`
- `N8N_HOST=n8n.ai-automation-platform.com`
- `N8N_PROTOCOL=https`
- `N8N_PORT=5678`
- `N8N_EDITOR_BASE_URL=https://n8n.ai-automation-platform.com/`
- `WEBHOOK_URL=https://n8n.ai-automation-platform.com/`
- `N8N_PROXY_HOPS=1`
- `N8N_ENCRYPTION_KEY=<stable strong value>`

Keep `N8N_ENCRYPTION_KEY` stable. Losing or rotating it without a migration plan can make saved n8n credentials unusable.

TLS parameters:

- `/linkedin-job-application-automation/nginx/origin_certificate`
- `/linkedin-job-application-automation/nginx/origin_private_key`

Terraform stores both TLS values with `value_wo` and `value_wo_version`. Increment the matching version variable when rotating either secret.

## Persistence

The deployment uses Docker named volumes:

- `linkedin-job-application-automation-n8n-data` mounted at `/home/node/.n8n`
- `linkedin-job-application-automation-n8n-files` mounted at `/home/node/.n8n-files`

The project currently uses n8n's default SQLite storage. This is acceptable for a small single-instance deployment when the `/home/node/.n8n` volume is persistent, but it is not a high-availability database design. Do not delete or recreate these volumes during deployment or rollback.

## Nginx

The Nginx config is `deploy/nginx/linkedin-job-application-automation.conf`.

It:

- rejects unknown hosts with default servers
- redirects HTTP to HTTPS
- serves `n8n.ai-automation-platform.com`
- proxies to `http://127.0.0.1:5678`
- supports WebSocket upgrades
- disables proxy buffering
- uses long read/send timeouts for workflows and event connections

The deployment installs TLS files at:

- `/etc/nginx/ssl/n8n.ai-automation-platform.com/origin_certificate.pem`
- `/etc/nginx/ssl/n8n.ai-automation-platform.com/origin_private_key.pem`

Certificate permissions are `0644`; private-key permissions are `0600`.

## Cloudflare

Manual DNS record:

- Type: `A`
- Name: `n8n`
- Target: Terraform `elastic_ip` output
- Proxy status: `Proxied`

SSL/TLS mode must be `Full (strict)`.

Enable Always Use HTTPS if it is not already enabled for the zone.

The Origin Certificate must cover `n8n.ai-automation-platform.com`. A wildcard `*.ai-automation-platform.com` certificate is also acceptable if that is the certificate strategy for the zone.

Cloudflare may return 526 when the origin certificate is expired, invalid, or does not match the hostname. Direct browser access to the Elastic IP is not supported because Nginx routes by hostname and the Cloudflare Origin CA certificate is intended for Cloudflare-to-origin traffic. Direct `curl` to the origin may not trust the certificate without Cloudflare in front.

## Deployment

GitHub Actions workflow:

`.github/workflows/deploy-production.yml`

Required GitHub repository variables:

- `AWS_REGION=eu-central-1`
- `N8N_INSTANCE_ID=<Terraform instance_id output>`
- `N8N_PROD_DOMAIN=n8n.ai-automation-platform.com`

Required GitHub secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

The workflow runs automatically on every push to `main`, and can also be run manually
(`workflow_dispatch`, with `n8n_image`/`previous_image` inputs). It sends
`deploy/scripts/deploy-n8n.sh` through AWS SSM Run Command — never SSH.

Deployment order on EC2 (`deploy-production` job):

1. verify/install the official AWS CLI v2, Docker, jq, curl, and Nginx
2. retrieve application parameters from `/linkedin-job-application-automation/env` only
3. retrieve TLS certificate and private key individually with `aws ssm get-parameter --with-decryption`
4. validate PEM markers and install TLS files atomically
5. install and test Nginx configuration
6. preserve Docker volumes and previous image information
7. pull the requested pinned n8n image
8. start a candidate container on `127.0.0.1:5679`
9. check `http://127.0.0.1:5679/health`
10. replace the production container on `127.0.0.1:5678`
11. check `http://127.0.0.1:5678/health`
12. reload Nginx
13. check `https://n8n.ai-automation-platform.com/health` through local Nginx resolution
14. prune obsolete images

A separate `seed-production-workflows` job then runs after `deploy-production` and before
`verify-production` — see [Workflow seeding](#workflow-seeding) below.

## Rollback

If final container or Nginx health checks fail, the script stops/removes only the failed replacement container, restarts the previous image as the stable container, keeps both persistent volumes, validates localhost and HTTPS health, and exits non-zero so GitHub records the deployment as failed.

## Workflow seeding

Production workflows are seeded automatically from this repository — never imported by hand
through the n8n UI.

**Where they live**: [`workflows/`](../workflows) at the repo root, one JSON file per
workflow (the same files this README's screenshots come from), plus
[`workflows/manifest.json`](../workflows/manifest.json), which is the source of truth for
_which_ files are repository-managed and their deterministic n8n workflow `id`.

**Deterministic IDs**: every managed workflow JSON file has a stable top-level `"id"` field
that must exactly match its manifest entry. `scripts/n8n/validate_workflow_manifest.py`
enforces this (run in CI, and locally — see below): it fails the build on duplicate ids,
missing files, id/file mismatches, or a workflow with no id at all.

**How seeding works**: the CI `seed-production-workflows` job packages `workflows/*.json` +
`manifest.json` into a tar, transfers it to the production host over the existing SSM
mechanism (base64-embedded in the SSM command, same pattern as the Nginx config transfer —
no S3, no new infrastructure), and runs `deploy/scripts/seed-n8n-workflows.sh` there. That
script:

1. waits for the production container to be healthy,
2. `docker cp`s each manifest-listed file into the container,
3. runs `n8n import:workflow --separate --input=<dir>` (confirmed via
   `n8n import:workflow --help` on the pinned `1.102.4` image — the flags are not guessed),
4. **verifies** the result with `n8n export:workflow --all --separate`, checking that every
   manifest id exists in the container's database exactly once.

**What happens on repeated deployment**: nothing is duplicated. n8n's CLI import persists
workflows by an upsert keyed on the JSON's `id` — an existing workflow with a matching id is
updated in place, not duplicated. The seeding script does not simply trust this: it always
re-verifies afterwards (step 4 above) and fails the deployment if any manifest id is missing
or appears more than once. Only files listed in the manifest are ever touched — any
workflow a human created directly in the n8n UI, with an id not in the manifest, is left
alone.

**Credential handling**: workflow JSON files may reference credentials by id/name, but no
credential _values_ are ever stored in the repository or created by this pipeline. Seeding
only calls `n8n import:workflow` / `export:workflow`, never anything that touches
`credentials_entity`. If a workflow references a credential that doesn't exist on the
target instance, the workflow still imports (inactive nodes referencing a missing
credential are an n8n-side warning, not an import failure) — check the n8n editor after a
first-time seed of a new workflow to confirm any credential references resolve, and wire
them up once, by hand, in the UI (this is the one credential-related manual step; the
underlying credential _value_ never needs to touch a JSON file or repository afterward).
Executions and user accounts are never touched by seeding.

**Adding a new workflow**: export it from n8n (`n8n export:workflow --id=<id>` or via the
editor), drop the JSON file into `workflows/`, add an entry to `workflows/manifest.json`
with its `id`, `file`, and `name`. Run the validator locally (below) before pushing.

**Updating an existing workflow**: edit/export the same file in place, keeping its `id`
unchanged. The next deployment's seed step will upsert it.

**Verifying seeded workflows**:

- In CI: the `seed-production-workflows` job fails the whole deployment if verification
  fails, and the deployment summary reports the seeded workflow count.
- Manually, via SSM (no SSH — see [docs/demo-environment.md](demo-environment.md) for why
  SSH is disabled): `aws ssm start-session --region eu-central-1 --target <instance-id>`,
  then `docker exec linkedin-job-application-automation-n8n n8n export:workflow --all`.

**Running the seeder locally** (against a local n8n container, for testing):

```bash
docker inspect linkedin-job-application-automation-n8n >/dev/null # container must be running
deploy/scripts/seed-n8n-workflows.sh \
  --container linkedin-job-application-automation-n8n \
  --workflow-dir workflows \
  --manifest workflows/manifest.json \
  --environment production
```

**Validating the manifest locally** (no Docker required):

```bash
python3 scripts/n8n/validate_workflow_manifest.py \
  --manifest workflows/manifest.json --workflow-dir workflows
```

Demo workflow seeding works differently — see
[docs/demo-environment.md](demo-environment.md#9-clean-seed-build-scriptsn8nbuild_demo_seedsh) — because
the demo's whole database is rebuilt from scratch daily from a _sanitized_ export of
whatever is currently in production, not from a fixed manifest.

## Health Endpoint

Use `/health` for local and external monitoring:

- `http://127.0.0.1:5678/health`
- `https://n8n.ai-automation-platform.com/health`

This is the endpoint to add later to `status.ai-automation-platform.com`.

## Editor Security

n8n owner/user authentication must remain enabled. Do not set `N8N_USER_MANAGEMENT_DISABLED=true` in production.

Optional stronger designs:

- Keep `n8n.ai-automation-platform.com` public with n8n authentication so webhook paths remain public.
- Future stronger split: protect `n8n.ai-automation-platform.com` with Cloudflare Access for the editor, and expose public webhooks on a separate `hooks.ai-automation-platform.com` hostname.

Do not place a blanket Cloudflare Access policy in front of webhook paths unless every external integration can authenticate through it.

### Recommended: Cloudflare Access in front of the editor

Cloudflare Access cannot be provisioned from this repository (no Cloudflare Terraform provider is configured; see [docs/demo-environment.md](demo-environment.md) for why). Configure it manually in the Cloudflare dashboard for defense-in-depth on top of n8n's own login:

1. Zero Trust → Access → Applications → Add an application → Self-hosted.
2. Application domain: `n8n.ai-automation-platform.com` (root path `/`, so both the editor and webhooks live behind it — if any webhook consumer cannot authenticate through Access, exclude only that specific path with a `Bypass` policy rather than removing Access entirely).
3. Identity providers: restrict to the one IdP you use for your own login (e.g. One-time PIN to your own email, or Google/GitHub SSO).
4. Policy: Action `Allow`, Include → Emails → your email only. Everything else denies by default (Access is deny-by-default; there is no separate "deny all" rule to add).
5. Session duration: 24h is reasonable for a personal instance; shorter if you want to re-auth more often.
6. Do not add this application/policy to `demo-n8n.ai-automation-platform.com` — the demo is deliberately public. See [docs/demo-environment.md](demo-environment.md).
