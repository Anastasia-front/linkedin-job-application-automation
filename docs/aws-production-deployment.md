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

`.github/workflows/deploy.yml`

Required GitHub repository variables:

- `AWS_REGION=eu-central-1`
- `N8N_INSTANCE_ID=<Terraform instance_id output>`

Required GitHub secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

The workflow is manual-only. It sends `deploy/scripts/deploy-n8n.sh` through AWS SSM Run Command.

Deployment order on EC2:

1. verify/install AWS CLI, Docker, jq, curl, and Nginx
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

## Rollback

If final container or Nginx health checks fail, the script stops/removes only the failed replacement container, restarts the previous image as the stable container, keeps both persistent volumes, validates localhost and HTTPS health, and exits non-zero so GitHub records the deployment as failed.

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
