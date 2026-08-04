# Kamal deployment design — encounter-engine

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-05
**Depends on:** the Merb→Rails 8 migration (branch `modernize/rails`, PR #2). This work branches
from it and must be rebased if that PR changes before merging.

## Goal

Deploy encounter-engine — a Rails 8 / Ruby 3.3 game engine for real-world urban games — to a single
Ubuntu VM on Azure, using Kamal 2, with PostgreSQL in a container and point-in-time recovery to
Azure Blob. One instance serves every community, against the app's current per-instance
`TZ`/`DEFAULT_LOCALE` model.

## Decisions already taken

| Decision | Choice | Why |
|---|---|---|
| Deploy tool | Kamal 2 | Zero-downtime cutover and run-migrations-once come free; both are what bite during a live game |
| Topology | One instance for all communities | Less operational surface. Revisit when per-game locale/timezone lands |
| Database | PostgreSQL in a container | Fits the project's free/low-maintenance ethos |
| Backups | wal-g → Azure Blob, PITR | Smallest tool giving genuine point-in-time recovery with a short enough restore path to rehearse |
| Registry | GHCR | Free for this repo, authenticates from Actions with the built-in token |
| Mail | Gmail SMTP | Adequate for this volume; swappable, since it is only secrets |
| VM | Provided by the owner; Ansible configures it | Owner controls the Azure account |
| TLS | kamal-proxy + Let's Encrypt on an owner-supplied domain | `force_ssl` makes TLS mandatory for the app to respond at all |

## The target host (verified 2026-08-05, not assumed)

`mezin.eu` — an Azure VM, `AzurePublicCloud` / `westeurope`, hostname `web`, public IP
`23.100.7.86`, Ubuntu 22.04.5, x86_64.

| | |
|---|---|
| CPU / RAM | **1 vCPU, 1.9 GB total, ~1.1 GB available** |
| Disk | 30 GB, 17 GB free |
| Swap | 2 GB, already configured |
| Docker | **not installed** |
| Access | user `mezinster`, passwordless sudo |
| sshd | `0.0.0.0:22`, publicly reachable |
| Ports 80 / 443 / 5432 | free |

**This is not a dedicated VM. It is a working utility host**, and the deployment is a new tenant
that must not disturb the neighbours:

| Service | Port | Note |
|---|---|---|
| `danted` SOCKS proxy | `0.0.0.0:1080` | enabled; plausibly load-bearing for the owner's own access |
| Squid-family proxies | 3128, 3129, 3130, 8080, 8081 | |
| `inreach` / `inreach-kate` | outbound | live APRS forwarders run from `~/iR-APRSISD` |
| Postfix | 25, localhost only | |
| Apache | — | installed but **disabled and inactive**; will not contend for 80 |

### Consequences

- **The firewall is not touched.** UFW is currently inactive and Azure's NSG is the control point;
  it stays that way. An earlier draft had Ansible enabling UFW for 22/80/443 only, which would have
  firewalled off `danted` and the proxies — potentially severing the owner's access to the machine.
- **Docker rewrites iptables on install.** On a host whose purpose is relaying traffic this is a
  real risk, not a formality. Installation must be followed by verifying every existing listener is
  still reachable, and the plan must state how to roll back if not.
- **Never build images on this box.** 1 vCPU and ~1.1 GB free will not build a Ruby image
  comfortably, and the attempt would starve the running services. CI builds; the VM only pulls.
- **PostgreSQL needs explicit tuning.** Defaults assume far more memory than is spare here.
- **Hostname: `game.mezin.eu`**, not the apex. `mezin.eu` already resolves to this box and serves
  the owner's other purposes; the app takes a subdomain. A DNS A record to `23.100.7.86` is a
  prerequisite, and Let's Encrypt will issue for that name once it resolves.

### A note on SSH access

The maintainer's workstation (WSL2) cannot reach the internet directly and connects through a
Windows-side SOCKS bridge (`ssh mezin`). **This is a workstation concern, not a deployment one** —
the server's sshd is publicly reachable, so GitHub Actions can connect to it directly with a deploy
key. Do not design around the bridge.

## Non-goals

- Per-game timezone and locale. That belongs to the content-i18n project and would change the
  topology decision above.
- Multi-VM, load balancing, or read replicas. Peak load is a few dozen players for a few hours.
- Managed PostgreSQL. Reconsider if operating wal-g proves burdensome.
- Migrating data from the existing Heroku demo. This is a fresh instance.

## Architecture

```
Internet ──443──▶ kamal-proxy ──http──▶ app (puma)  ──▶ postgres accessory
                  TLS, Let's Encrypt     Rails 8         (custom image:
                  health-checked cutover                  postgres + wal-g)
                                                              │
                                                      archive_command
                                                              ▼
                                                        Azure Blob
                                                  (WAL + nightly base backup)
```

One VM, three containers, all managed by Kamal. The app is a single puma process — no JS build, no
asset precompile (this app has no asset-pipeline gem; static files serve from `public/`), no
background job worker, no Redis.

PostgreSQL runs as a Kamal **accessory**: started and stopped by Kamal, never rolled during a
deploy. Its data lives on a named Docker volume on the VM disk.

**wal-g runs inside the PostgreSQL container, not on the host.** `archive_command` is executed by
the PostgreSQL process itself, so the binary must be on that process's filesystem — a host-installed
wal-g is unreachable from inside the container. The accessory therefore uses a small custom image
(`Dockerfile.postgres`: the official PostgreSQL image plus the wal-g binary), built and pushed by
the same CI workflow as the app image. The nightly base backup is a cron inside that container.

**Migrations run in Kamal's `pre-deploy` hook, not the container entrypoint.** The generated Rails 8
Dockerfile puts `db:prepare` in the entrypoint, which races at more than one replica and, more
importantly, applies migrations *while traffic is shifting*. The hook runs them exactly once, before
any new container starts, so a failed migration aborts the deploy rather than half-applying it.

Concretely: the `pre-deploy` hook executes on the deploying host after the new image is pushed and
before any container is started, and runs `bin/rails db:migrate` in a one-off container built from
that exact image (Kamal exposes the version being deployed to the hook). A non-zero exit must abort
the deploy — the implementation has to verify that, since a hook that logs a failure and returns
zero is worse than no hook.

Deploys never touch the VM's git state: CI builds the image, pushes to GHCR, the VM pulls. No
checkout, no `bundle install`, nothing to drift on the server.

## App changes

`config/environments/production.rb` gains four settings. Each fixes something currently broken.

```ruby
config.assume_ssl = true
config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST"), protocol: "https" }
config.action_mailer.smtp_settings = {
  address:              ENV.fetch("SMTP_ADDRESS", "smtp.gmail.com"),
  port:                 ENV.fetch("SMTP_PORT", 587).to_i,
  authentication:       :plain,
  enable_starttls_auto: true,
  user_name:            ENV.fetch("SMTP_USERNAME"),
  password:             ENV.fetch("SMTP_PASSWORD"),
  domain:               ENV.fetch("APP_HOST")
}
```

Why each is required:

- **`assume_ssl`** — kamal-proxy terminates TLS and forwards plain HTTP. Without this, `force_ssl`
  sees an HTTP request, redirects to HTTPS, and loops forever. This is the most common way a first
  Kamal deploy of a `force_ssl` app fails.
- **`logger` to STDOUT** — Rails otherwise writes `log/production.log` *inside the container*, where
  `docker logs` cannot see it and a redeploy discards it.
- **`default_url_options`** — welcome letters and invitations contain links. Without a host they
  render broken or raise.
- **`smtp_settings`** — `delivery_method = :smtp` is already set with no settings, so production
  mail currently goes to localhost:25, i.e. nowhere. This app forms teams by invitation, so mail is
  not optional.

`app/models/user.rb`, controllers, views and locales are untouched.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: build layer with build-essential and libpq-dev, runtime layer on ruby:3.3.12-slim, non-root user, no asset precompile |
| `.dockerignore` | Excludes `.git`, `tmp`, `log`, `db/*.sqlite3`, `.superpowers`, `docs`, `features`, `spec` |
| `config/deploy.yml` | Kamal: service, image, server, proxy/TLS, GHCR, postgres accessory, env clear/secret split |
| `.kamal/secrets` | Secret *references* read from the environment. No values, ever |
| `.kamal/hooks/pre-deploy` | Runs `bin/rails db:migrate` once, aborting the deploy on failure |
| `.github/workflows/deploy.yml` | Build → push GHCR → `kamal deploy`, gated on a GitHub Environment with required reviewers |
| `Dockerfile.postgres` | Official PostgreSQL image plus the wal-g binary, `archive_command` and the nightly base-backup cron |
| `ansible/playbook.yml`, `ansible/inventory.example` | VM provisioning (see boundary below) |
| `docs/runbooks/restore.md` | The restore procedure, written to be followed under pressure |

## Configuration and secrets

Non-secret, in `config/deploy.yml` under `env.clear`:
`RAILS_ENV=production`, `TZ`, `DEFAULT_LOCALE`, `APP_HOST`, `MAIL_FROM`, `SMTP_ADDRESS`, `SMTP_PORT`.

Secret, referenced in `.kamal/secrets`, stored as GitHub Actions secrets:

| Secret | Origin | Used by |
|---|---|---|
| `SECRET_KEY_BASE` | generated once, 64 hex bytes | app — refuses to boot without it |
| `POSTGRES_PASSWORD` | generated once | postgres accessory; composed into the app's `DATABASE_URL` |
| `SMTP_USERNAME` | the Gmail address | app |
| `SMTP_PASSWORD` | Gmail **app password** (requires 2FA on the account) | app |
| `AZURE_STORAGE_ACCOUNT` | storage account name | wal-g |
| `AZURE_STORAGE_KEY` | storage account key | wal-g |
| `KAMAL_REGISTRY_PASSWORD` | GHCR PAT, `read:packages` for the VM pull | Kamal, VM |
| `SSH_PRIVATE_KEY` | deploy key authorised on the VM | Kamal, from Actions |

`DATABASE_URL` is composed in `deploy.yml` from `POSTGRES_PASSWORD` rather than stored separately,
so the password exists in exactly one place.

## Backup and restore

wal-g archives each WAL segment as PostgreSQL closes it, via `archive_command`, plus a nightly
`backup-push`. Retention: 7 daily base backups, WAL retained to cover them.

Restore is `wal-g backup-fetch` followed by replay to a chosen timestamp, documented in
`docs/runbooks/restore.md` with exact commands.

**A rehearsed restore is an acceptance criterion, not a follow-up.** Archiving that has run for
months and a restore nobody has attempted are operationally identical. The drill:

1. Insert a row; record the timestamp.
2. Insert a second row.
3. Restore to the timestamp between them.
4. Prove the first row is present and the second is gone.

If that is not demonstrated, the backup work is not done.

## CI/CD

On merge to `master`: build the image, push to GHCR, run `kamal deploy`. The deploy job targets a
GitHub Environment with required reviewers, so a merge cannot silently deploy while a game is in
progress.

The existing CI workflow (cucumber, rspec, zeitwerk) continues to gate pull requests and is
unchanged by this work.

## Ansible boundary

Ansible configures the **machine** and nothing about the application. On this shared host its scope
is deliberately small:

- Docker engine and the compose plugin — followed by a check that `danted` (1080), the proxies
  (3128–3130, 8080–8081) and sshd are all still reachable
- The named Docker volume for PostgreSQL data
- `unattended-upgrades` for security patches
- The deploy key in `authorized_keys`

Explicitly **not** in scope: any firewall change (UFW stays inactive, NSG remains the control
point), and swap (2 GB already configured).

It does **not** template `deploy.yml`, manage app env, or run Kamal. One tool owns the runtime and
that tool is Kamal.

## Acceptance criteria

1. `https://<domain>` serves the app with a valid Let's Encrypt certificate.
2. `/up` returns 200.
3. A real signup delivers a welcome letter to a real inbox.
4. An invitation delivers to a second address.
5. A deploy completes with zero failed requests under a concurrent request loop.
6. Migrations run exactly once per deploy, verified in the deploy log.
7. The restore drill above succeeds.
8. `docker logs` shows Rails request logs (proving STDOUT logging).
9. The app refuses to boot without `SECRET_KEY_BASE` (already true; must remain true).

## Risks

- **Gmail deliverability.** Invitations from a personal Gmail address to strangers frequently land
  in spam, and this app is invitation-driven, so failures are silent. Mitigation: verify against a
  non-Gmail recipient during acceptance; treat a transactional provider as the likely next step.
- **wal-g misconfiguration is invisible until restore.** Mitigation: the drill is an acceptance
  criterion, and the nightly job must alert on failure rather than fail quietly.
- **Single VM is a single point of failure.** Accepted: the recovery path is rebuild plus restore,
  which the runbook covers. Not worth HA at this scale.
- **Coexistence on a shared host.** Docker's iptables changes, or memory pressure from PostgreSQL
  and puma, could disturb `danted` and the proxy services this box exists to run — including the
  owner's own route to it. Mitigation: verify every existing listener after Docker installs, cap
  container memory, and keep a rollback path (`docker` removal) documented before starting.
- **Capacity.** 1 vCPU and ~1.1 GB spare RAM is genuinely tight for puma plus PostgreSQL plus a
  proxy. Mitigation: tune `shared_buffers`/`work_mem` down, set Docker memory limits, rely on the
  existing 2 GB swap, and measure headroom during acceptance rather than assuming it.
- **Disk exhaustion from WAL if archiving stalls.** PostgreSQL retains WAL when `archive_command`
  fails, and a full disk stops the database. Mitigation: monitor free space; make archive failures
  loud.
