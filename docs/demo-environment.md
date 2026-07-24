# Public Demo n8n Environment

A second, fully separate n8n instance at `https://demo-n8n.ai-automation-platform.com` that
recruiters can log into with a shared account, edit freely, and which resets to a clean
state every day at 04:00 Europe/Paris. It is entirely isolated from production
(`https://n8n.ai-automation-platform.com`): separate EC2 instance, security group, IAM role,
Elastic IP, PostgreSQL database, Docker volumes/network, encryption key, SSM parameter path,
and Nginx site.

## 1. Architecture

```
Production                              Demo
-----------------------------------     -----------------------------------
Cloudflare (Access: your email only)    Cloudflare (public)
  -> Nginx (host)                         -> Nginx (host, rate-limited)
    -> n8n container (127.0.0.1:5678)       -> n8n container (127.0.0.1:5678)
       SQLite (/home/node/.n8n volume)         PostgreSQL container (separate volume)
       real credentials/workflows/history      shared demo user, sanitized workflows,
                                                no credentials, all workflows inactive
EC2 instance A                          EC2 instance B (separate SG/IAM/EIP)
```

Terraform (`infra/main.tf`) provisions the demo stack as a second instantiation of the
same modules (`network`, `iam`, `ec2`, `ssm`) used for production, gated by
`var.n8n_demo_enabled`. Nothing is shared between the two instantiations except the
Terraform module _code_.

## 2. Why the demo can be edited, and why it resets daily

n8n Community Edition has no read-only/view-only role for shared workflows — any user who
can log in can edit or delete workflows. Rather than pretend otherwise, this design accepts
that a demo visitor can do anything a normal n8n user can do (see the threat model below)
and instead makes the blast radius bounded and short-lived: every change is wiped and
replaced with a known-good snapshot every 24 hours, and the account has no real credentials
or external system access to abuse in the first place.

## 3. How production is protected

Two independent layers:

1. **Cloudflare Access** in front of `n8n.ai-automation-platform.com`, restricted to your
   email only (manual setup — see
   [docs/aws-production-deployment.md](aws-production-deployment.md#recommended-cloudflare-access-in-front-of-the-editor)).
   Deny-by-default: only the explicit allow policy for your email can reach the hostname.
2. **n8n's own login** (owner/user management), which stays enabled independent of Access.

The demo hostname is never added to that Access application, and the demo shared account
has no path to the production hostname (separate DNS name, separate EC2 instance, separate
Nginx `server_name`, separate n8n encryption key so demo credentials — even if someone
created one — could never decrypt anything from production even if the ciphertext were
somehow copied).

## 4. Isolation inventory

| Resource                       | Production                                   | Demo                                                                                        |
| ------------------------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------- |
| EC2 instance                   | `module.ec2`                                 | `module.ec2_demo` (separate instance, separate root volume, IMDSv2 required, encrypted EBS) |
| Elastic IP                     | `module.ec2.elastic_ip`                      | `module.ec2_demo.elastic_ip`                                                                |
| Security group                 | `module.network`                             | `module.network_demo` (no ingress unless `n8n_demo_allowed_admin_cidrs` is set)             |
| IAM role/profile               | `<project>-ec2-role`                         | `<project>-demo-ec2-role` (scoped only to `/demo/*` SSM paths)                              |
| SSM parameter path             | `/linkedin-job-application-automation/env/*` | `/linkedin-job-application-automation/demo/env/*`                                           |
| Database                       | SQLite file in a Docker volume               | Dedicated PostgreSQL container + volume                                                     |
| Docker volumes                 | `linkedin-job-application-automation-n8n-*`  | `n8n-demo-data`, `n8n-demo-postgres-data`                                                   |
| Docker network/Compose project | plain `docker run` (no Compose project)      | Compose project `n8n-demo`, network `n8n-demo-net`                                          |
| Encryption key                 | `N8N_ENCRYPTION_KEY` in prod SSM             | Different `N8N_ENCRYPTION_KEY` in demo SSM — **never the same value**                       |
| Nginx site                     | `linkedin-job-application-automation`        | `n8n-demo` (`deploy/nginx/n8n-demo.conf`)                                                   |
| Hostname                       | `n8n.ai-automation-platform.com`             | `demo-n8n.ai-automation-platform.com`                                                       |
| User accounts                  | your personal owner account                  | one shared `DEMO_USER_EMAIL` / `DEMO_USER_PASSWORD`                                         |

The demo IAM role (`infra/modules/iam`, instantiated with `name_suffix = "-demo"` and
`path_prefix = "/linkedin-job-application-automation/demo"`) can only read SSM parameters
under its own demo path plus `AmazonSSMManagedInstanceCore` (required for SSM Run Command
deploys, same as production). It has no S3, EC2, Secrets Manager, or production SSM access
— confirm with `aws iam list-attached-role-policies` and
`aws iam list-role-policies` against the role Terraform outputs.

## 5. Threat model (untrusted demo visitors)

Assume every demo visitor may try to: edit/delete/create workflows, run Code nodes, probe
`$env`, hit the filesystem or network, attempt DoS, or interfere with another visitor's
session (there's only one shared account, so "another visitor's session" really means
"another visitor's edits" — there is no session isolation between visitors; this is called
out explicitly rather than hidden).

Mitigations in place (`.env.demo.example`, `docker-compose.demo.yml`,
`deploy/nginx/n8n-demo.conf`):

- All imported workflows forced inactive; verified twice (once in `build_demo_seed.sh`,
  once independently by `validate_demo_workflows.py` before anything is even shipped to the
  instance).
- Zero credentials in the demo database (`build_demo_seed.sh` fails the build if
  `credentials_entity` is non-empty after import).
- `N8N_COMMUNITY_PACKAGES_ENABLED=false` — no arbitrary npm package installation.
- `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` — blocks `$env` access from Code/Function nodes where
  n8n supports it for the pinned version.
- `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true` and `N8N_RESTRICT_FILE_ACCESS_TO=/tmp/n8n-demo-files`
  — confines any file node/Code node filesystem access to a dedicated, non-persistent bind
  mount (`./tmp`), where supported.
- No AWS credentials in the container (compose file never mounts `~/.aws`, never sets
  `AWS_*` env vars); IMDSv2 with `http_put_response_hop_limit = 1` on the demo EC2 instance
  means even a container that discovered the gateway IP cannot reach the metadata endpoint
  from inside Docker's default bridge network (hop count exhausted before reaching the host
  loopback route to `169.254.169.254`).
- Demo EC2 IAM role has no useful application permissions (section 4).
- Container CPU/memory limits (`deploy.resources.limits`) and Docker log rotation
  (`max-size: 10m`, `max-file: 3`) on both containers.
- Nginx rate limiting (`limit_req_zone ... rate=5r/s` with burst 15) and connection limiting
  (`limit_conn ... 20`) on the demo vhost only.
- `EXECUTIONS_DATA_PRUNE=true` / `EXECUTIONS_DATA_MAX_AGE=24` keeps execution history from
  growing unbounded between resets.
- Docker socket is never mounted; no broad host directory mounts (only `./imports` read-only
  and a dedicated `./tmp`).
- Public signup: n8n Community Edition's owner/user setup is a one-time bootstrap (see
  section 8) — there's no open "sign up" endpoint exposed once the owner account exists, so
  visitors get exactly the one shared account and cannot create their own persistent users
  through the UI.
- Webhook execution: webhook nodes are imported like any other node (their `webhookId` is
  stripped and regenerated by n8n on import), and since all workflows are inactive, their
  webhook URLs are not registered/reachable until someone in the demo activates that
  workflow — at which point it is scoped to the demo instance's own resources only, and gets
  wiped at the next daily reset regardless.

None of this claims the demo is fully sandboxed against a determined attacker running
arbitrary JS in a Code node inside the container — it is a portfolio demo, not a
multi-tenant SaaS sandbox. The point is that even a fully "successful" attack from inside
the container has nothing of value to reach (no credentials, no AWS access, no path to
production) and doesn't survive past the next 04:00 reset.

## 6. Secrets and how they're stored

Every demo secret lives in AWS SSM Parameter Store as `SecureString`, under
`/linkedin-job-application-automation/demo/env/<KEY>` (see `infra/modules/ssm`, instantiated
for demo with `path_prefix = "/linkedin-job-application-automation/demo"`). Notable keys:

- `N8N_ENCRYPTION_KEY` — demo-only, must differ from production's.
- `DB_POSTGRESDB_PASSWORD` — demo-only Postgres password.
- `DEMO_USER_EMAIL` / `DEMO_USER_PASSWORD` — the shared login recruiters use.

TLS material for the demo hostname is stored the same way production's is:
`/linkedin-job-application-automation/demo/nginx/origin_certificate` and
`.../origin_private_key` (Cloudflare Origin CA cert/key for `demo-n8n.ai-automation-platform.com`).

`deploy/scripts/deploy-n8n-demo.sh` renders these into `/opt/n8n-demo/.env.demo` on the demo
host the same way `deploy/scripts/deploy-n8n.sh` renders production's `.env` — and refuses
to proceed if a nginx-path parameter or a multiline value ever ends up in the env file
(same defense-in-depth check as production).

## 7. How workflow sanitization works

Pipeline (all in `.github/workflows/deploy.yml`, job `sanitize-and-validate-workflows`):

1. **Export** — `docker exec` into the production n8n container and run
   `n8n export:workflow --all --separate --output=<dir>` (verified against
   `n8n export:workflow --help` on the pinned image first; the job fails rather than
   guessing if `--separate`/`--output` aren't advertised). Only workflow JSON is exported —
   this CLI command never touches credentials or the database file.
2. **Sanitize** — `scripts/n8n/sanitize_workflows.py`:
   - forces every workflow `active: false`
   - strips `pinData`, `staticData`, `versionId`, `id`, `meta`, `tags`, ownership/shared
     fields
   - removes every node's `credentials` block and `webhookId`
   - redacts values keyed by a normalized sensitive-key list (`password`, `secret`, `token`,
     `apiKey`, `authorization`, etc. — see `scripts/n8n/sanitization_common.py`), matching on
     the **key name**, not a blind substring search, so `tokenLimit` or `apiKeyName` are left
     alone while `Authorization: Bearer ...` header values are redacted
   - replaces configured production domains with placeholder values
     (`config/n8n-demo-sanitization.json`)
   - **fails closed**: if it finds something that looks like a hard-coded secret, a private
     key block, an AWS metadata reference, a private IP, or a dangerous shell/file pattern
     that it did _not_ already know how to safely redact, it aborts the whole run rather than
     guessing
3. **Validate** — `scripts/n8n/validate_demo_workflows.py` is a second, independent script
   (not just a second function) that re-inspects the sanitizer's _output_ for the same class
   of problems, plus `active: true`, leftover credentials/webhookIds, and `$env` expressions.
   A non-empty problem list fails the pipeline before anything reaches the demo host.

Raw production exports are never uploaded as a GitHub Actions artifact and never leave the
job's own runner workspace — export, sanitize, and validate all happen in the same job, and
the raw + sanitized temp files are deleted at the end of that job regardless of outcome
(`if: always()` cleanup step). Only the already-sanitized, already-validated tarball is
uploaded as a 1-day-retention artifact so the next job can hand it to the demo host.

## 8. Demo user provisioning

n8n Community Edition's CLI does not expose a documented, version-stable
`user-management:create` command for the pinned image, and the maintained mechanism for
bootstrapping the very first (owner) account is the REST endpoint used by the n8n setup
wizard itself: `POST /rest/owner/setup` with `email`/`firstName`/`lastName`/`password`.
`scripts/n8n/build_demo_seed.sh` calls this once, right after a fresh database is created and
n8n has run its migrations, using `DEMO_USER_EMAIL`/`DEMO_USER_PASSWORD` from
`.env.demo`. Because the daily reset restores the **database snapshot** taken after that
step, the user is _not_ recreated on every reset — it comes back for free as part of the
seed restore.

## 9. Clean seed build (`scripts/n8n/build_demo_seed.sh`)

Runs on the demo EC2 host (delivered by `deploy/scripts/deploy-n8n-demo.sh`, or directly via
the `build-demo-seed` CI job). Summary of what it does, in order: acquire a `flock` lock →
start Postgres → drop/recreate the `n8n` database → start n8n (let migrations run) → ensure
the shared owner account exists → import sanitized workflows from `/opt/n8n-demo/imports` →
verify zero active workflows and zero credential rows (hard-fails the build otherwise) →
truncate execution history → stop n8n → `pg_dump -Fc` → validate with `pg_restore --list` →
atomically install the new dump as `demo-seed.dump` (after first copying the current one to
`demo-seed.previous.dump`) → write non-sensitive `metadata.json` → restart n8n → health check.
Seed files live at `/opt/n8n-demo/seed/{demo-seed.dump,demo-seed.previous.dump}`,
`root:root 0600`.

**Workflow seeding here differs from production's** (see
[docs/aws-production-deployment.md](aws-production-deployment.md#workflow-seeding)):
production seeds from a fixed `workflows/manifest.json` in the repo, but the demo's
workflow set is _derived daily_ from whatever is currently in production — the
`sanitize-and-validate-workflows` CI job exports it, strips credentials/secrets
(`scripts/n8n/sanitize_workflows.py`), and independently re-validates the result
(`scripts/n8n/validate_demo_workflows.py`) before it ever reaches this host. Because the
demo database is dropped and recreated from scratch on every build (see above), there is no
"existing workflow" to accidentally duplicate — but the actual `n8n import:workflow` /
`export:workflow` calls, and the post-import verification that every expected id landed
exactly once, are done by the same `deploy/scripts/seed-n8n-workflows.sh` production uses
(given a manifest built on the fly from the sanitized files' own ids), so the two
environments share one seeding implementation instead of two.

To refresh the seed manually (e.g. after editing workflows in the repo without a full
deploy):

```bash
aws ssm send-command --region eu-central-1 --instance-ids "$N8N_DEMO_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands='["/opt/n8n-demo/scripts/build_demo_seed.sh"]'
```

Or, with an SSM Session Manager shell open on the demo host: `sudo /opt/n8n-demo/scripts/build_demo_seed.sh`.

## 10. Daily reset (`scripts/n8n/reset_demo.sh`)

Installed as `/usr/local/sbin/reset-n8n-demo.sh`, scheduled by
`n8n-demo-reset.timer`/`.service` (systemd, created by `infra/userdata-demo.tftpl` at
first boot; Ubuntu 24.04's systemd fully supports the `OnCalendar=... Europe/Paris` timezone
suffix, so no `CRON_TZ` workaround is needed).

It **never contacts production** and never re-exports anything — it only restores the
already-validated `demo-seed.dump`: acquire lock → validate seed exists/non-empty →
`pg_restore --list` structural check on the file itself (before touching any container) →
stop demo n8n → terminate Postgres connections → drop/recreate the database → `pg_restore`
→ start n8n → health-check with retries. If the primary seed restore or the health check
fails, it captures `docker compose logs` for both containers and retries once from
`demo-seed.previous.dump`; if that also fails, it stops n8n and exits non-zero rather than
serve a partially-restored public instance.

To reset manually:

```bash
aws ssm send-command --region eu-central-1 --instance-ids "$N8N_DEMO_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands='["/usr/local/sbin/reset-n8n-demo.sh"]'
```

Or on the host directly: `sudo /usr/local/sbin/reset-n8n-demo.sh`.

### Changing the daily reset time

`n8n_demo_reset_hour` / `n8n_demo_reset_timezone` in `infra/variables.tf` feed
`infra/userdata-demo.tftpl`'s `OnCalendar=` line. Cloud-init only runs on first boot, so
changing these Terraform variables after the instance already exists requires either
recreating the instance or manually editing
`/etc/systemd/system/n8n-demo-reset.timer` on the host and running
`sudo systemctl daemon-reload && sudo systemctl restart n8n-demo-reset.timer`.

## 11. Inspecting logs

```bash
systemctl status n8n-demo-reset.timer
systemctl list-timers n8n-demo-reset.timer
journalctl -u n8n-demo-reset.service
sudo tail -f /var/log/n8n-demo-reset.log
docker compose -p n8n-demo --env-file /opt/n8n-demo/.env.demo -f /opt/n8n-demo/docker-compose.yml ps
docker compose -p n8n-demo --env-file /opt/n8n-demo/.env.demo -f /opt/n8n-demo/docker-compose.yml logs --tail=100 n8n
docker compose -p n8n-demo --env-file /opt/n8n-demo/.env.demo -f /opt/n8n-demo/docker-compose.yml logs --tail=100 postgres
```

`/var/log/n8n-demo-reset.log` and the Nginx demo access/error logs are rotated by
`/etc/logrotate.d/n8n-demo` (weekly, 8 rotations for the reset log; daily, 14 rotations for
Nginx). Neither the reset script nor the Nginx config logs request bodies or Authorization
headers.

## 12. Disabling public demo access

Fastest (reversible in seconds), from the demo host:

```bash
sudo systemctl stop nginx
```

Or block at the edge: in Cloudflare, pause the `demo-n8n` DNS record (toggle proxy off and
point it somewhere inert) or add a Cloudflare Access "block all" application over
`demo-n8n.ai-automation-platform.com`.

To tear down the instance entirely: set `n8n_demo_enabled = false` in `terraform.tfvars` and
`terraform apply` (destroys the demo EC2 instance, its EIP, security group, IAM role, and
SSM parameters — production is untouched because it lives in entirely separate resources).

## 13. Rotating demo credentials

1. Generate a new `DEMO_USER_PASSWORD` (and/or email) and update the SSM parameter:
   `aws ssm put-parameter --name /linkedin-job-application-automation/demo/env/DEMO_USER_PASSWORD --type SecureString --overwrite --value '<new>'`
   (or change it in `terraform.tfvars`' `n8n_demo_env_values` and `terraform apply`).
2. Re-run the deploy pipeline (or just `deploy-n8n-demo.sh` via SSM) so `.env.demo` picks up
   the new value.
3. Run `build_demo_seed.sh` again so the _seeded_ database's owner account password matches
   — otherwise the daily reset will keep restoring the old password.

## 14. Rotating the demo encryption key

Changing `N8N_ENCRYPTION_KEY` invalidates any credentials already encrypted with the old
key. Since demo credentials should never exist in the first place (section 5), rotation is
low-risk:

1. Generate a new key (`openssl rand -hex 32`) and update
   `/linkedin-job-application-automation/demo/env/N8N_ENCRYPTION_KEY` in SSM (or
   `n8n_demo_env_values` + `terraform apply`).
2. Re-deploy the demo stack and re-run `build_demo_seed.sh` to produce a fresh seed under the
   new key. Do not attempt to reuse the old seed with a new key.

## 15. Recovering from a broken seed

`reset_demo.sh` already retries automatically from `demo-seed.previous.dump` (section 10).
If both are broken:

```bash
sudo /opt/n8n-demo/scripts/build_demo_seed.sh   # rebuilds from imports/, if present
```

If `/opt/n8n-demo/imports` is empty (e.g. it was already consumed by a prior successful
build), re-run the `sanitize-and-validate-workflows` + `deploy-demo` + `build-demo-seed` jobs
from GitHub Actions (`deploy_demo: true`) to re-populate it from a fresh production export.

## 16. Testing without touching production

- `python3 -m pytest tests/n8n -q` — sanitizer/validator unit tests, no AWS/network required.
- `docker compose -f docker-compose.demo.yml --env-file .env.demo.example config` — validates
  the demo Compose file locally (copy `.env.demo.example` to `.env.demo` first).
- `bash -n scripts/n8n/*.sh deploy/scripts/*.sh && shellcheck scripts/n8n/*.sh deploy/scripts/*.sh`
- `terraform -chdir=infra validate` after `terraform -chdir=infra init -backend=false`.
- A full local integration test (build a throwaway Postgres+n8n Compose stack, import a
  fixture workflow, take a seed, mutate it, run `reset_demo.sh` against it, assert the
  mutation is gone) is described but not automated in CI in this change — it requires a
  Docker daemon, which this environment did not have available; see "Validation results" in
  the final report for exactly what _was_ run.

## 17. Cloudflare: what remains manual

No Cloudflare Terraform provider is configured in this repository (only `hashicorp/aws`).
Manual steps for the demo hostname, mirroring production's existing manual-DNS pattern
(`infra/outputs.tf`'s `cloudflare_dns_instruction`, now with a `demo_cloudflare_dns_instruction`
counterpart):

1. DNS: `A` record `demo-n8n` → the `demo_elastic_ip` Terraform output, Proxy status
   **Proxied**.
2. SSL/TLS mode: `Full (strict)` (same zone-level setting as production).
3. **Do not** add `demo-n8n.ai-automation-platform.com` to the Cloudflare Access application
   that protects production — the demo must stay reachable without authentication.
4. Optional: a Cloudflare rate-limiting rule at the edge as defense-in-depth on top of the
   Nginx-level limits already in `deploy/nginx/n8n-demo.conf`.

## 18. Required configuration

See the final report / PR description for the full list of Terraform variables, GitHub
Actions variables/secrets, and SSM parameter paths. Nothing here should ever contain a
production secret value.

## 19. Known limitations of n8n Community Edition

- No true read-only or view-only sharing role — any authenticated user can edit/delete any
  workflow. This is why the daily reset exists; it is not a workaround for a bug, it's the
  intended mitigation for a real product limitation.
- No first-class multi-tenant session isolation — all demo visitors share one account and
  can see/overwrite each other's in-progress edits until the next reset.
- No documented, version-stable CLI for creating additional users; the owner-setup REST
  endpoint is the closest stable mechanism (section 8).
- `$env` blocking, community-package disabling, and file-access restriction env vars are
  supported by the pinned 1.102.4 image (confirmed via this repo's own existing production
  `terraform.tfvars.example`, which already sets several of them), but **verify against
  `docker run --rm docker.n8n.io/n8nio/n8n:1.102.4 --help` / the n8n changelog** before
  bumping the pinned version — these flags have changed across n8n major versions.

## 20. Runbook

**Demo does not start after reset** — `journalctl -u n8n-demo-reset.service` and
`/var/log/n8n-demo-reset.log` for the failure point; `docker compose ... logs --tail=100 n8n`.
If both seeds are broken, see section 15.

**Seed is invalid** — `pg_restore --list /opt/n8n-demo/seed/demo-seed.dump`; if it errors,
rebuild with `build_demo_seed.sh` (section 9).

**PostgreSQL restore fails** — check `docker compose ... logs postgres`; verify
`DB_POSTGRESDB_USER`/`DATABASE` in `.env.demo` match what the seed was dumped with.

**Demo password no longer works** — the daily reset restores whatever password was baked
into the _seed_, not whatever is currently in `.env.demo`. Follow section 13 fully (update
SSM, redeploy, rebuild seed) rather than just updating SSM.

**Imported workflows are missing** — check `/opt/n8n-demo/imports` was non-empty at the time
`build_demo_seed.sh` ran; re-run the CI pipeline to re-export/sanitize/transfer.

**Workflow validation blocks deployment** — read `validate_demo_workflows.py`'s JSON report
in the Action logs; it names the file and the specific problem category. Fix the underlying
workflow (or add a narrowly-scoped, reviewed entry to `config/n8n-demo-sanitization.json`'s
`allowed_values`) — do not bypass the check.

**Production workflow export fails** — usually means `n8n export:workflow --help` on the
currently-pinned image no longer advertises `--all`/`--separate`/`--output`; the job fails
loudly rather than guessing. Check the n8n changelog for the new flag names and update
`.github/workflows/refresh-demo.yml`'s export step.

**SSM command fails** — `aws ssm get-command-invocation` output is printed to the job log
(stderr only, no workflow content); check the demo/prod instance is `Online` in
`aws ssm describe-instance-information`.

**`ssh ... port 22 Operation timed out`** — expected, not a fault. See section 21: this
architecture disables SSH entirely and uses SSM Run Command / SSM Session Manager instead. A
port-22 timeout only proves the security group has no port-22 ingress rule (by design); it
says nothing about whether nginx, Docker, or n8n are healthy. Use the diagnostics in section
21, or the `verify-demo` job's remote-diagnostics step in `refresh-demo.yml`, instead of
retrying SSH or opening port 22.

**Cloudflare 521 ("Web server is down") on `demo-n8n.ai-automation-platform.com`** — 521
means Cloudflare could not establish a TCP connection to the origin on port 443 at all (as
opposed to a 502/504, which would mean it connected but got a bad/slow response). Work
through, in order, via SSM (never SSH — section 21):

1. Is the instance actually running? `aws ec2 describe-instances --instance-ids
"$N8N_DEMO_INSTANCE_ID"` (state `running`) and `aws ssm describe-instance-information`
   (`PingStatus: Online` — if it's not Online, SSM itself can't reach it either, which also
   explains why deploys/resets would be silently failing).
2. Is nginx running and listening on `0.0.0.0:443`? `systemctl status nginx --no-pager` and
   `ss -lntp | grep :443` on the host (via SSM Session Manager or `ssm-run.sh`).
3. Does `nginx -t` pass? A bad reload from a broken `deploy/nginx/n8n-demo.conf` push would
   leave the last-known-good config running (nginx refuses to reload on `-t` failure) — but
   check anyway; if nginx itself isn't running at all (crashed, never started), `-t` alone
   won't tell you that.
4. Is the demo n8n container up and healthy? `docker compose -p n8n-demo --env-file
/opt/n8n-demo/.env.demo -f /opt/n8n-demo/docker-compose.yml ps` and `docker logs
--tail=200 <container>`.
5. Does `curl -fsS http://127.0.0.1:5678/health` succeed _on the host_? If not, this is an
   n8n/container problem, not a network/nginx problem — check container logs and whether the
   Postgres seed restore (section 10) actually completed.
6. Does `curl -fkSs https://127.0.0.1/` succeed on the host (bypassing Cloudflare
   entirely)? If yes but the public hostname still 521s, the problem is between Cloudflare
   and the origin (security group, Elastic IP association, or DNS), not the host itself.
7. Does the demo security group (`module.network_demo` in Terraform) allow inbound 80/443
   from Cloudflare's IP ranges (or `0.0.0.0/0`, since Cloudflare's ranges change)? Compare
   against `infra/modules/network`'s demo instantiation.
8. Does the DNS `A`/`CNAME` record for `demo-n8n` actually point at the current demo Elastic
   IP? An instance replacement (e.g. `terraform apply` recreating `module.ec2_demo`) changes
   the Elastic IP association but not necessarily a stale DNS record if it was ever
   hand-edited outside Terraform.
9. Are the Cloudflare Origin Certificate/key present and valid on the host?
   `/etc/nginx/ssl/demo-n8n.ai-automation-platform.com/{origin_certificate,origin_private_key}.pem`
   — an expired or missing origin cert makes nginx fail TLS negotiation, which Cloudflare
   also reports as 521.

`refresh-demo.yml`'s `verify-demo` job now runs steps 2–5 automatically (via SSM, with
`|| true` only on the diagnostic commands themselves — never on the actual pass/fail health
checks) every time it runs, specifically so a 521 report comes with an immediate, in-the-Action-log
answer to "which of these is it" instead of requiring someone to SSH in (which doesn't work)
or manually SSM in under time pressure.

**Nginx returns 502** — n8n container is down or unhealthy; `docker compose ps`,
`docker compose logs n8n`, confirm `127.0.0.1:5678` is listening.

**Health check fails** — confirm you're hitting `/health` (not `/healthz`, which does not
exist on this pinned image) and that Nginx's `location = /health` block is present and not
shadowed by a stricter `location /` rate limit.

## 21. Accessing hosts: SSM, not SSH

Neither the production nor the demo security group has an inbound rule for port 22. This is
deliberate — CI/CD deploys entirely over AWS SSM Run Command (`deploy/scripts/ssm-run.sh`),
never SSH, so there is no reason to keep a port open whose only purpose would be interactive
human access, and every open port is attack surface. **An `ssh ... port 22 ... Operation
timed out` is the expected, correct result of trying to SSH into either host** — it proves
the security group has no port-22 ingress, nothing more. It is not a health signal for
nginx, Docker, or n8n; do not "fix" it by adding a port-22 rule.

For interactive access (debugging, one-off commands, following logs live), use AWS SSM
Session Manager, which tunnels a shell over the same IAM/SSM path CI already uses — no
inbound port required at all:

```bash
aws ssm start-session --region eu-central-1 --target "$N8N_DEMO_INSTANCE_ID"
# or, for production:
aws ssm start-session --region eu-central-1 --target "$N8N_INSTANCE_ID"
```

This requires the AWS CLI (`v2`, see the Session Manager plugin install docs) and the same
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (or an assumable role) CI uses, with
`ssm:StartSession` permission against the target instance.

For a single non-interactive command without opening a session, prefer
`aws ssm send-command` (see the examples throughout this doc) or
`deploy/scripts/ssm-run.sh <region> <instance-id> <script> <stdout-file>` locally, which is
the exact same helper CI uses and gives you its retry/timeout/error-surfacing behavior
instead of hand-rolling `send-command`/`get-command-invocation` polling.

If you have a personal shell alias or function pointing `ssh ...` at either host's IP (for
example, one left over from before this project moved to SSM-only access), replace it with
an `aws ssm start-session` alias instead — that alias lives in your own shell config
(`~/.bashrc`/`~/.zshrc`), not in this repository, so it isn't something this repo's tooling
can detect or fix for you.
