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
- `DEPLOY_ARTIFACTS_BUCKET=<Terraform deploy_artifacts_bucket output>` — used to transfer the
  workflow manifest tar during seeding (see [Workflow seeding](#workflow-seeding) below);
  provisioned by `infra/modules/s3`

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
`manifest.json` into a tar and uploads it to a private S3 bucket
(`infra/modules/s3`, `DEPLOY_ARTIFACTS_BUCKET`, under a `production/` prefix), then triggers
`deploy/scripts/seed-n8n-workflows.sh` on the production host via the existing SSM mechanism,
passing only the small S3 object URI through the SSM command (not the tar itself). The host
downloads the tar with `aws s3 cp` using its own IAM role, which can only read the
`production/*` prefix of that bucket (never `demo/*`) — the S3 upload is not a new inbound
network path, and CI deletes the object again right after the SSM step finishes (a bucket
lifecycle rule expires anything left over after 1 day as a backstop).

This exists because AWS SSM RunCommand documents (parameters + script content combined) have
a hard **~97KB** total size limit (`MaxDocumentSizeExceeded`); a base64-encoded tar of this
repo's workflow JSON files is already well over that on its own. Everything else this
pipeline sends over SSM (the seeding script itself, the Nginx config, the deploy scripts) is
small enough to stay embedded directly in the SSM command, as before — only the workflow tar
needed to move to S3.

`deploy/scripts/seed-n8n-workflows.sh` itself:

1. waits for the production container to be healthy,
2. `docker cp`s each manifest-listed file into the container,
3. runs `n8n import:workflow --separate --input=<dir>` (confirmed at runtime via
   `n8n import:workflow --help` against whatever image is actually running — the flags are
   never guessed, which matters because the pinned version now changes regularly; see
   [Keeping n8n updated](#keeping-n8n-updated) below),
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

## Keeping n8n updated

The pinned n8n image tag is never `latest` — n8n's own docs recommend pinning a specific
version in production, and this repo enforces it (CI and the deploy scripts always resolve
to a concrete `X.Y.Z` tag). Instead, staying current is automated:

- **[`n8n-version.txt`](../n8n-version.txt)** at the repo root is the single source of truth:
  one line, the currently-pinned version (e.g. `2.32.5`). Every other place that needs the
  full image reference (`docker-compose.yml`, `docker-compose.demo.yml`,
  `.github/workflows/deploy-production.yml`'s and `refresh-demo.yml`'s `workflow_dispatch`
  default / push fallback, `scripts/n8n/build_demo_seed.sh`'s fallback) is kept in sync with
  it by the workflow below rather than hand-edited independently.
- **[`.github/workflows/update-n8n-version.yml`](../.github/workflows/update-n8n-version.yml)**
  runs daily (`0 6 * * *` UTC) plus on manual dispatch. It queries the Docker Hub tags API for
  `n8nio/n8n`, filters to plain stable `X.Y.Z` tags (excluding `next`/`beta`/nightly channels
  and architecture-suffixed variants), and compares the newest one against
  `n8n-version.txt`. If newer, it bumps every reference above, runs the same validation the
  `validate` CI job runs (`bash -n`, shellcheck, YAML parse, both compose files' `config`,
  pytest), and opens a pull request — it never merges or deploys anything itself.
- **Merging that PR is what actually ships the new version**: `deploy-production.yml` already
  runs on every push to `main` (this includes the `seed-production-workflows` and
  `verify-production` steps, so a bad version bump fails the deployment and is visible
  immediately, not silently). `refresh-demo.yml` picks up the new pinned version on its next
  scheduled run.
- **Before merging**, read the PR body's links — n8n's
  [release notes](https://docs.n8n.io/changelog/release-notes-2.x/) and
  [update guide](https://docs.n8n.io/deploy/host-n8n/keep-n8n-running/update-n8n/) — since a
  major-version bump can include breaking changes (changed CLI flags, new required env vars,
  node behavior changes) that no amount of automated validation catches with certainty.
  `seed-n8n-workflows.sh` independently re-checks `n8n import:workflow --help` against
  whatever image is actually running on every deploy, so CLI flag drift specifically fails
  loudly rather than silently breaking workflow seeding — but that's a narrower guarantee
  than "this version has no breaking changes for you."
- To bump manually instead of waiting for the scheduled check: trigger
  `update-n8n-version.yml` via `workflow_dispatch`, or edit `n8n-version.txt` and the same
  literal fallbacks by hand in one PR.
- To deploy a specific version once without changing the pin (e.g. to test a release
  candidate): use `deploy-production.yml`'s `workflow_dispatch` with an explicit `n8n_image`
  input — this does not touch `n8n-version.txt`, so the next scheduled/automatic deploy goes
  back to the pinned version.
