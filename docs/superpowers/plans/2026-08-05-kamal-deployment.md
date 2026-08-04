# Kamal Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy encounter-engine to `https://game.mezin.eu` with Kamal 2, PostgreSQL in a container, point-in-time recovery to Azure Blob, and a CI deploy — without disturbing the services already running on that host.

**Architecture:** One Azure VM already in production use for other things. Kamal manages three containers on it: `kamal-proxy` (TLS via Let's Encrypt on :80/:443), the Rails app (single puma), and a PostgreSQL accessory built from a custom image carrying `wal-g`. CI builds and pushes images to GHCR; the VM only pulls. Migrations run once in a `pre-deploy` hook, never in the container entrypoint.

**Tech Stack:** Ruby 3.3.12, Rails 8.0.5.1, Kamal 2, Docker, PostgreSQL 16, wal-g, GitHub Actions, Ansible, Azure Blob Storage.

## Global Constraints

- Target host: `game.mezin.eu` → `23.100.7.86` (Azure VM, westeurope, Ubuntu 22.04.5, **1 vCPU / 1.9 GB RAM / 17 GB free**). SSH as `mezinster`, passwordless sudo. From this workstation the alias is `ssh mezin`.
- **This host is shared and in production use.** `danted` (SOCKS, `0.0.0.0:1080`), squid-family proxies (3128, 3129, 3130, 8080, 8081), and two `inreach` APRS forwarders are live. Ports 80/443/5432 are free.
- **Never modify the firewall.** UFW is inactive and must stay inactive; Azure's NSG is the control point. Enabling UFW for 22/80/443 would sever the owner's own access.
- **Never build images on the target host.** 1 vCPU and ~1.1 GB spare will not build a Ruby image without starving the running services. CI builds; the VM pulls.
- Ruby is pinned to `3.3.12` and Rails to `8.0.5.1` in the Gemfile. Do not change either.
- On this workstation, rbenv is not on PATH in non-login shells. Prefix commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- The local bundle is configured `without production`, so `pg` is not installed locally. A naive `RAILS_ENV=production` boot dies on a `pg` LoadError before reaching anything interesting; substitute `DATABASE_URL="sqlite3:db/probe.sqlite3"` to test production config locally.
- Existing test suites must not regress: `bundle exec rspec` (421 examples, 0 failures, 6 pending) and `bundle exec cucumber` (234 scenarios, 2362 steps).
- Branch: `deploy/kamal`, based on `modernize/rails`.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `Dockerfile` | App image: build deps in one stage, slim runtime in the next, non-root |
| `Dockerfile.postgres` | PostgreSQL 16 + wal-g binary + archive configuration |
| `.dockerignore` | Keeps history, tests, docs and local databases out of the image |
| `config/deploy.yml` | Kamal: service, servers, proxy/TLS, registry, accessory, env split |
| `.kamal/secrets` | Secret *references* only — never values |
| `.kamal/hooks/pre-deploy` | Runs `db:migrate` once against the exact image being deployed |
| `.github/workflows/deploy.yml` | Build → push GHCR → `kamal deploy`, gated on an Environment |
| `ansible/inventory.ini` | The single host |
| `ansible/playbook.yml` | Docker install plus a non-destructive verification of existing listeners |
| `docs/runbooks/restore.md` | The PITR procedure, written to be followed under pressure |

**Modified:**

| File | Change |
|---|---|
| `config/routes.rb` | Add the `/up` health endpoint kamal-proxy needs |
| `config/environments/production.rb` | `assume_ssl`, STDOUT logger, mailer host, SMTP settings |
| `Gemfile` | Add `kamal` to the development group |

---

### Task 1: Production configuration and the health endpoint

**Files:**
- Modify: `config/routes.rb`
- Modify: `config/environments/production.rb`
- Test: `spec/requests/health_spec.rb`, `spec/production_config_spec.rb`

**Interfaces:**
- Produces: `GET /up` returning 200; production env reading `APP_HOST`, `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`. Task 5's `deploy.yml` supplies all five.

- [ ] **Step 1: Write the failing health-endpoint test**

```ruby
# spec/requests/health_spec.rb
require "rails_helper"

RSpec.describe "health endpoint", type: :request do
  it "returns 200 so kamal-proxy can health-check the container" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/health_spec.rb
```

Expected: FAIL — `No route matches [GET] "/up"`.

- [ ] **Step 3: Add the route**

Add to `config/routes.rb`, immediately after `Rails.application.routes.draw do`:

```ruby
  # kamal-proxy polls this during deploys and will not cut traffic over to a
  # container that does not answer it. Rails ships the controller; this app's
  # routes were ported from Merb, so the route was never added.
  get "up" => "rails/health#show", as: :rails_health_check
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/requests/health_spec.rb
```

Expected: PASS, 1 example, 0 failures.

- [ ] **Step 5: Write the failing production-config test**

```ruby
# spec/production_config_spec.rb
require "rails_helper"

RSpec.describe "production environment configuration" do
  # Loading a second environment inside a running app is not possible, so read
  # the file and assert on its content. Crude, but it pins the four settings
  # whose absence breaks production in ways no other test can see.
  let(:source) { File.read(Rails.root.join("config/environments/production.rb")) }

  it "assumes SSL, or force_ssl loops forever behind kamal-proxy" do
    expect(source).to match(/config\.assume_ssl\s*=\s*true/)
  end

  it "logs to STDOUT, or logs are trapped inside the container" do
    expect(source).to match(/config\.logger\s*=.*STDOUT/)
  end

  it "sets a mailer host, or invitation links render broken" do
    expect(source).to match(/default_url_options.*APP_HOST/m)
  end

  it "configures SMTP, or mail silently goes to localhost:25" do
    expect(source).to match(/smtp_settings/)
    expect(source).to match(/SMTP_USERNAME/)
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

```bash
bundle exec rspec spec/production_config_spec.rb
```

Expected: FAIL — 4 examples, 4 failures.

- [ ] **Step 7: Rewrite `config/environments/production.rb`**

```ruby
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.force_ssl = true

  # kamal-proxy terminates TLS and forwards plain HTTP. Without assume_ssl,
  # force_ssl sees an HTTP request, redirects to HTTPS, and loops forever.
  config.assume_ssl = true

  # Containers have no useful filesystem for logs: log/production.log is
  # invisible to `docker logs` and discarded on redeploy.
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = :info

  config.i18n.default_locale = ENV.fetch("DEFAULT_LOCALE", "ru").to_sym

  config.action_mailer.delivery_method = :smtp
  # Welcome letters and invitations contain links; without a host they render
  # broken or raise.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST"), protocol: "https"
  }
  config.action_mailer.smtp_settings = {
    address:              ENV.fetch("SMTP_ADDRESS", "smtp.gmail.com"),
    port:                 ENV.fetch("SMTP_PORT", "587").to_i,
    authentication:       :plain,
    enable_starttls_auto: true,
    user_name:            ENV.fetch("SMTP_USERNAME"),
    password:             ENV.fetch("SMTP_PASSWORD"),
    domain:               ENV.fetch("APP_HOST")
  }
end
```

- [ ] **Step 8: Run both new specs and the full suite**

```bash
bundle exec rspec spec/production_config_spec.rb spec/requests/health_spec.rb
bundle exec rspec
```

Expected: the two new files pass; the full run is 426 examples, 0 failures, 6 pending.

- [ ] **Step 9: Prove production still boots with the new config**

```bash
RAILS_ENV=production \
  DATABASE_URL="sqlite3:db/probe.sqlite3" \
  SECRET_KEY_BASE=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)') \
  APP_HOST=game.mezin.eu SMTP_USERNAME=x SMTP_PASSWORD=y \
  bundle exec ruby -e 'require "./config/environment"; puts "BOOTED"'
rm -f db/probe.sqlite3
```

Expected: `BOOTED`. If it raises `KeyError`, an `ENV.fetch` has no default and no value — that is the intended behaviour for `APP_HOST`, `SMTP_USERNAME` and `SMTP_PASSWORD`, so supply them as above rather than adding defaults.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb config/environments/production.rb spec/requests/health_spec.rb spec/production_config_spec.rb
git commit -m "Add /up health endpoint and make production config container-aware"
```

---

### Task 2: The application image

**Files:**
- Create: `Dockerfile`, `.dockerignore`
- Modify: `Gemfile`

**Interfaces:**
- Consumes: the health endpoint from Task 1.
- Produces: an image whose default command serves puma on `:3000` and answers `GET /up`. Task 5's `deploy.yml` references it as `ghcr.io/mezinster/encounter-engine`.

- [ ] **Step 1: Add Kamal to the Gemfile**

In the `group :development, :test do` block, add:

```ruby
  gem "kamal", "~> 2.0", require: false
```

Then:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle install
bundle exec kamal version
```

Expected: a 2.x version string.

- [ ] **Step 2: Write `.dockerignore`**

```
.git
.github
.superpowers
docs
features
spec
tmp
log
node_modules
db/*.sqlite3
db/*.sqlite
.env*
ansible
```

- [ ] **Step 3: Write the `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.3.12

FROM ruby:${RUBY_VERSION}-slim AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev git && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY Gemfile Gemfile.lock ./
# Production needs pg; it must NOT inherit this workstation's
# `bundle config without production`.
RUN bundle config set --local without 'development test' && \
    bundle config set --local deployment 'true' && \
    bundle install && \
    rm -rf ~/.bundle /usr/local/bundle/ruby/*/cache
COPY . .

FROM ruby:${RUBY_VERSION}-slim
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 curl tzdata && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# No asset precompile: this app has no asset-pipeline gem. Static files are
# served straight from public/.

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /rails
USER rails:rails

ENV RAILS_ENV=production BUNDLE_WITHOUT="development test"
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000"]
```

- [ ] **Step 4: Build the image locally**

```bash
docker build -t encounter-engine:test .
```

Expected: a successful build. If Docker is unavailable on this workstation, build it in CI via Task 7 and mark this step done there instead — but do not skip verifying the image runs.

- [ ] **Step 5: Prove the image actually serves**

```bash
docker run -d --name ee-smoke -p 3001:3000 \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) \
  -e DATABASE_URL="sqlite3:/tmp/smoke.sqlite3" \
  -e APP_HOST=game.mezin.eu -e SMTP_USERNAME=x -e SMTP_PASSWORD=y \
  encounter-engine:test
sleep 8
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3001/up
docker rm -f ee-smoke
```

Expected: `200`. A non-200 means the image cannot serve, and no amount of Kamal configuration will fix that later.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile .dockerignore Gemfile Gemfile.lock
git commit -m "Add the application image and the kamal gem"
```

---

### Task 3: The PostgreSQL image with wal-g

**Files:**
- Create: `Dockerfile.postgres`

**Interfaces:**
- Produces: an image exposing PostgreSQL 16 with `wal-g` on PATH and `archive_command` configured. Task 5 references it as `ghcr.io/mezinster/encounter-engine-postgres`; Task 6 drives its archiving.

- [ ] **Step 1: Write `Dockerfile.postgres`**

```dockerfile
# syntax=docker/dockerfile:1
FROM postgres:16-bookworm

# wal-g must live INSIDE this image. archive_command is executed by the
# PostgreSQL process itself, so a wal-g installed on the host is unreachable.
ARG WALG_VERSION=v3.0.3
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates curl cron && \
    curl -fsSL -o /tmp/walg.tar.gz \
      "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-ubuntu-20.04-amd64.tar.gz" && \
    tar -xzf /tmp/walg.tar.gz -C /tmp && \
    mv /tmp/wal-g-pg-ubuntu-20.04-amd64 /usr/local/bin/wal-g && \
    chmod +x /usr/local/bin/wal-g && \
    rm -rf /tmp/walg.tar.gz /var/lib/apt/lists/*

# Tuned for a 1 vCPU / 1.9 GB host that is ALSO running danted, several
# proxies and two APRS forwarders. Defaults assume far more headroom.
COPY <<'CONF' /etc/postgresql/conf.d/10-tuning.conf
shared_buffers = 128MB
work_mem = 4MB
maintenance_work_mem = 64MB
effective_cache_size = 512MB
max_connections = 20
archive_mode = on
archive_command = 'wal-g wal-push %p'
archive_timeout = 300
wal_level = replica
CONF

CMD ["postgres", "-c", "config_file=/usr/share/postgresql/postgresql.conf.sample", "-c", "include_dir=/etc/postgresql/conf.d"]
```

- [ ] **Step 2: Build it**

```bash
docker build -f Dockerfile.postgres -t ee-postgres:test .
```

Expected: a successful build.

- [ ] **Step 3: Verify wal-g is present and runnable inside the image**

```bash
docker run --rm ee-postgres:test wal-g --version
```

Expected: a version string. This is the check that would have caught the design error where wal-g was installed on the host instead — a host binary cannot be reached by `archive_command`.

- [ ] **Step 4: Verify PostgreSQL still starts with the tuning file**

```bash
docker run -d --name pg-smoke -e POSTGRES_PASSWORD=smoke ee-postgres:test
sleep 10
docker exec pg-smoke psql -U postgres -c "SHOW shared_buffers; SHOW archive_mode;"
docker rm -f pg-smoke
```

Expected: `128MB` and `on`. If the container exits, the config include path is wrong — read `docker logs pg-smoke` rather than guessing.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile.postgres
git commit -m "Add the PostgreSQL image carrying wal-g and small-host tuning"
```

---

### Task 4: Prepare the host without disturbing it

**Files:**
- Create: `ansible/inventory.ini`, `ansible/playbook.yml`

**Interfaces:**
- Produces: Docker installed on `game.mezin.eu`, every pre-existing listener still reachable.

- [ ] **Step 1: Record the baseline BEFORE touching anything**

```bash
ssh mezin 'ss -tlnp 2>/dev/null | awk "NR>1{print \$4}" | sort -u' | tee /tmp/listeners-before.txt
```

Expected to include `0.0.0.0:1080`, `0.0.0.0:22`, `*:3128`, `*:3129`, `*:3130`, `*:8080`, `*:8081`, `127.0.0.1:25`. Keep this file — Step 5 compares against it.

- [ ] **Step 2: Write the inventory**

```ini
# ansible/inventory.ini
[web]
game.mezin.eu ansible_user=mezinster ansible_host=23.100.7.86
```

- [ ] **Step 3: Write the playbook**

```yaml
# ansible/playbook.yml
# Scope is deliberately small. This host is in production use for other
# things: danted on 1080, squid-family proxies on 3128-3130 and 8080-8081,
# and two inReach APRS forwarders. We are a tenant, not the owner.
#
# It does NOT touch the firewall. UFW is inactive and Azure's NSG is the
# control point. Enabling UFW for 22/80/443 would firewall off danted and
# the proxies, plausibly severing the owner's own access to this machine.
- name: Prepare the host for Kamal
  hosts: web
  become: true
  tasks:
    - name: Install Docker prerequisites
      ansible.builtin.apt:
        name: [ca-certificates, curl, gnupg]
        state: present
        update_cache: true

    - name: Add the Docker apt key
      ansible.builtin.apt_key:
        url: https://download.docker.com/linux/ubuntu/gpg
        keyring: /etc/apt/keyrings/docker.gpg
        state: present

    - name: Add the Docker repository
      ansible.builtin.apt_repository:
        repo: "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
        state: present

    - name: Install Docker engine
      ansible.builtin.apt:
        name: [docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin]
        state: present
        update_cache: true

    - name: Allow the deploy user to run Docker
      ansible.builtin.user:
        name: mezinster
        groups: docker
        append: true

    - name: Create the PostgreSQL data volume
      community.docker.docker_volume:
        name: encounter_engine_pg_data

    - name: Enable unattended security upgrades
      ansible.builtin.apt:
        name: unattended-upgrades
        state: present

    - name: Assert the firewall was left alone
      ansible.builtin.command: ufw status
      register: ufw_state
      changed_when: false
      failed_when: "'inactive' not in ufw_state.stdout"
```

- [ ] **Step 4: Run it**

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
```

Expected: `ok`/`changed` throughout, and the final assertion passing — if UFW came up, something enabled it and that must be undone before continuing.

- [ ] **Step 5: Prove nothing was disturbed — the real gate for this task**

```bash
ssh mezin 'ss -tlnp 2>/dev/null | awk "NR>1{print \$4}" | sort -u' > /tmp/listeners-after.txt
diff /tmp/listeners-before.txt /tmp/listeners-after.txt && echo "NO LISTENERS LOST"
ssh mezin 'systemctl is-active danted inreach inreach-kate'
ssh mezin 'docker --version'
```

Expected: `NO LISTENERS LOST`, three `active` lines, and a Docker version. Docker rewrites iptables when it installs; on a host whose purpose is relaying traffic that is a real risk, and this diff is how you find out.

**If a listener disappeared:** stop. Remove Docker (`sudo apt-get remove --purge docker-ce docker-ce-cli containerd.io && sudo reboot`) and report before going further — do not attempt to patch iptables by hand.

- [ ] **Step 6: Commit**

```bash
git add ansible/
git commit -m "Add a deliberately small Ansible playbook that installs Docker and proves it disturbed nothing"
```

---

### Task 5: Kamal configuration and the first deploy

**Files:**
- Create: `config/deploy.yml`, `.kamal/secrets`, `.kamal/hooks/pre-deploy`

**Interfaces:**
- Consumes: the images from Tasks 2 and 3, the prepared host from Task 4.
- Produces: `https://game.mezin.eu` serving with a valid certificate.

- [ ] **Step 1: Confirm DNS resolves before touching TLS**

```bash
getent hosts game.mezin.eu || dig +short game.mezin.eu
```

Expected: `23.100.7.86`. **If it does not resolve, stop** — Let's Encrypt will fail and rate-limit the domain on repeated attempts. Add the A record first.

- [ ] **Step 2: Write `config/deploy.yml`**

```yaml
service: encounter-engine
image: mezinster/encounter-engine

servers:
  web:
    - 23.100.7.86

proxy:
  ssl: true
  host: game.mezin.eu
  app_port: 3000
  healthcheck:
    path: /up

registry:
  server: ghcr.io
  username: mezinster
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  # Built in CI and pushed. This host has 1 vCPU and ~1.1 GB spare; building
  # here would starve danted and the APRS forwarders.
  remote: false

ssh:
  user: mezinster

env:
  clear:
    RAILS_ENV: production
    TZ: Europe/Vienna
    DEFAULT_LOCALE: ru
    APP_HOST: game.mezin.eu
    MAIL_FROM: noreply@mezin.eu
    SMTP_ADDRESS: smtp.gmail.com
    SMTP_PORT: "587"
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL
    - SMTP_USERNAME
    - SMTP_PASSWORD

accessories:
  db:
    image: ghcr.io/mezinster/encounter-engine-postgres:latest
    host: 23.100.7.86
    port: "127.0.0.1:5432:5432"
    env:
      clear:
        POSTGRES_USER: encounter
        POSTGRES_DB: encounter_production
        WALG_AZ_PREFIX: azure://encounter-engine-wal
      secret:
        - POSTGRES_PASSWORD
        - AZURE_STORAGE_ACCOUNT
        - AZURE_STORAGE_ACCESS_KEY
    volumes:
      - encounter_engine_pg_data:/var/lib/postgresql/data
```

Note `port: "127.0.0.1:5432:5432"` — PostgreSQL is bound to loopback only. Publishing 5432 on `0.0.0.0` of a host that already exposes several proxies to the internet would be an unforced error.

- [ ] **Step 3: Write `.kamal/secrets`**

```bash
# Values come from the environment. In CI these are GitHub Actions secrets;
# locally, export them or use a password manager. Never commit values here.
SECRET_KEY_BASE=$SECRET_KEY_BASE
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
# Composed so the password exists in exactly one place.
DATABASE_URL=postgresql://encounter:${POSTGRES_PASSWORD}@127.0.0.1:5432/encounter_production
SMTP_USERNAME=$SMTP_USERNAME
SMTP_PASSWORD=$SMTP_PASSWORD
AZURE_STORAGE_ACCOUNT=$AZURE_STORAGE_ACCOUNT
AZURE_STORAGE_ACCESS_KEY=$AZURE_STORAGE_ACCESS_KEY
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
```

- [ ] **Step 4: Write the pre-deploy migration hook**

```bash
#!/usr/bin/env bash
# .kamal/hooks/pre-deploy
#
# Migrations run exactly once, here, before any new container starts.
# The generated Rails 8 Dockerfile puts db:prepare in the entrypoint, which
# races across replicas and applies migrations while traffic is shifting.
#
# set -e matters: without it a failed migration logs and returns zero, the
# deploy proceeds, and the app runs against a half-migrated schema.
set -euo pipefail

echo "Running migrations for version ${KAMAL_VERSION}"
kamal app exec --version "${KAMAL_VERSION}" --no-reuse "bin/rails db:prepare"
echo "Migrations complete"
```

```bash
chmod +x .kamal/hooks/pre-deploy
```

- [ ] **Step 5: Generate and export the secrets, then run setup**

```bash
export SECRET_KEY_BASE=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')
export POSTGRES_PASSWORD=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(24)')
export SMTP_USERNAME='<the gmail address>'
export SMTP_PASSWORD='<the gmail app password>'
export AZURE_STORAGE_ACCOUNT='<storage account>'
export AZURE_STORAGE_ACCESS_KEY='<storage key>'
export KAMAL_REGISTRY_PASSWORD='<ghcr PAT with write:packages>'

bundle exec kamal setup
```

Record `SECRET_KEY_BASE` and `POSTGRES_PASSWORD` somewhere durable **now** — regenerating `SECRET_KEY_BASE` logs every user out, and regenerating the PostgreSQL password without also changing it in the database locks the app out of its own data.

- [ ] **Step 6: Verify the deploy end to end**

```bash
curl -s -o /dev/null -w "up:      %{http_code}\n" https://game.mezin.eu/up
curl -s -o /dev/null -w "root:    %{http_code}\n" https://game.mezin.eu/
curl -sI https://game.mezin.eu/ | grep -i '^location' || true
echo | openssl s_client -connect game.mezin.eu:443 -servername game.mezin.eu 2>/dev/null | openssl x509 -noout -issuer -dates
ssh mezin 'docker ps --format "{{.Names}}\t{{.Status}}"'
ssh mezin 'docker logs $(docker ps -q --filter name=encounter-engine-web) 2>&1 | tail -5'
```

Expected: `up: 200`, root `200`, a Let's Encrypt issuer with valid dates, three running containers, and Rails request logs on stdout — that last one proving Task 1's STDOUT logging works in the real container.

- [ ] **Step 7: Confirm the neighbours are still fine**

```bash
ssh mezin 'systemctl is-active danted inreach inreach-kate'
ssh mezin 'ss -tlnp 2>/dev/null | awk "NR>1{print \$4}" | sort -u' > /tmp/listeners-deployed.txt
diff /tmp/listeners-before.txt /tmp/listeners-deployed.txt || echo "NOTE: only :80 and :443 should be new"
```

Expected: three `active`, and the only additions being `:80` and `:443`.

- [ ] **Step 8: Commit**

```bash
git add config/deploy.yml .kamal/
git commit -m "Add Kamal configuration and the pre-deploy migration hook"
```

---

### Task 6: Backups, and a restore you have actually performed

**Files:**
- Create: `docs/runbooks/restore.md`

**Interfaces:**
- Consumes: the PostgreSQL accessory from Tasks 3 and 5.

- [ ] **Step 1: Confirm WAL is reaching Azure Blob**

```bash
ssh mezin 'docker exec encounter-engine-db psql -U encounter -d encounter_production -c "SELECT pg_switch_wal();"'
sleep 20
ssh mezin 'docker exec encounter-engine-db wal-g wal-verify integrity'
```

Expected: an integrity report showing archived segments. **If nothing is archived, stop here** — everything below is theatre without this.

- [ ] **Step 2: Take the first base backup**

```bash
ssh mezin 'docker exec encounter-engine-db wal-g backup-push /var/lib/postgresql/data'
ssh mezin 'docker exec encounter-engine-db wal-g backup-list'
```

Expected: one backup listed.

- [ ] **Step 3: Schedule the nightly base backup**

```bash
ssh mezin 'docker exec encounter-engine-db bash -c "echo \"0 3 * * * wal-g backup-push /var/lib/postgresql/data >> /var/log/walg.log 2>&1\" | crontab -u postgres -"'
ssh mezin 'docker exec encounter-engine-db crontab -l -u postgres'
```

Expected: the cron line echoed back.

- [ ] **Step 4: Write the restore runbook**

Create `docs/runbooks/restore.md` containing: the exact `wal-g backup-fetch` and recovery-target commands, how to find a timestamp to restore to, how to bring PostgreSQL up in recovery, and how to verify afterwards. Write it for someone under pressure who did not build the system — imperative, no prose, every command copy-pasteable.

- [ ] **Step 5: REHEARSE THE RESTORE — this is the acceptance criterion**

```bash
# 1. a row, and a timestamp
ssh mezin 'docker exec encounter-engine-db psql -U encounter -d encounter_production -c "CREATE TABLE restore_drill(id serial, note text); INSERT INTO restore_drill(note) VALUES (''before'');"'
ssh mezin 'docker exec encounter-engine-db psql -U encounter -d encounter_production -t -c "SELECT now();"'
# 2. wait past the granularity, then a second row
sleep 60
ssh mezin 'docker exec encounter-engine-db psql -U encounter -d encounter_production -c "INSERT INTO restore_drill(note) VALUES (''after'');"'
```

Now follow `docs/runbooks/restore.md` to restore to the timestamp from step 1, into a scratch container — **not over the live volume**.

Expected: `before` present, `after` absent. If the runbook cannot be followed as written, fix the runbook and repeat. Archiving that has run for months and a restore nobody has attempted are operationally identical.

- [ ] **Step 6: Clean up and commit**

```bash
ssh mezin 'docker exec encounter-engine-db psql -U encounter -d encounter_production -c "DROP TABLE restore_drill;"'
git add docs/runbooks/restore.md
git commit -m "Add wal-g archiving and a rehearsed restore runbook"
```

---

### Task 7: Deploy from CI

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Create the GitHub Environment**

In repository settings, create an Environment named `production` with **required reviewers**, then add these secrets to it: `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_ACCESS_KEY`, `KAMAL_REGISTRY_PASSWORD`, `SSH_PRIVATE_KEY`.

The required reviewer is the point: a merge must not silently deploy while a game is running.

- [ ] **Step 2: Write the workflow**

```yaml
name: Deploy

on:
  push:
    branches: ["master"]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}

      - name: Build and push the PostgreSQL image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile.postgres
          push: true
          tags: ghcr.io/mezinster/encounter-engine-postgres:latest

      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Deploy
        env:
          SECRET_KEY_BASE: ${{ secrets.SECRET_KEY_BASE }}
          POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
          SMTP_USERNAME: ${{ secrets.SMTP_USERNAME }}
          SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
          AZURE_STORAGE_ACCOUNT: ${{ secrets.AZURE_STORAGE_ACCOUNT }}
          AZURE_STORAGE_ACCESS_KEY: ${{ secrets.AZURE_STORAGE_ACCESS_KEY }}
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
        run: bundle exec kamal deploy
```

- [ ] **Step 3: Trigger it and watch**

```bash
gh workflow run Deploy
gh run watch
```

Expected: it pauses for review, then deploys. Confirm the log shows `Running migrations for version …` exactly once.

- [ ] **Step 4: Prove zero-downtime**

In one shell:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " https://game.mezin.eu/up; sleep 0.3; done
```

Trigger another deploy from a second shell. Expected: an unbroken run of `200` — no `502`, no `000`. Anything else means the health-checked cutover is not working and the config needs fixing before this is trusted during a game.

- [ ] **Step 5: Verify mail actually arrives**

Sign up on `https://game.mezin.eu` with a real address that is **not** the sending Gmail account, and confirm the welcome letter arrives. Check the spam folder too — invitations from a personal Gmail address to strangers frequently land there, and this app forms teams by invitation, so the failure is silent.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "Deploy from CI, gated on a reviewed environment"
```

---

## Self-Review

**Spec coverage.** production.rb (Task 1); `/up`, which the spec did not mention but kamal-proxy's healthcheck requires (Task 1); Dockerfile and `.dockerignore` (Task 2); `Dockerfile.postgres` with wal-g inside the container (Task 3); Ansible with no firewall changes plus the listener diff (Task 4); `deploy.yml`, `.kamal/secrets`, pre-deploy hook, first deploy, TLS (Task 5); WAL archiving, nightly backup, runbook and the rehearsed restore (Task 6); CI deploy behind a reviewed Environment, zero-downtime proof, mail delivery (Task 7). All eight spec acceptance criteria map to a step. Postgres tuning lives in Task 3 rather than a task of its own, because it belongs to the image.

**Placeholder scan.** No "TBD" or "handle errors appropriately". Two placeholders are deliberate and marked with angle brackets because only the owner holds the values: the Gmail credentials and the Azure storage keys in Task 5 Step 5.

**Type consistency.** `encounter_engine_pg_data` is the volume name in Task 4 and Task 5. `ghcr.io/mezinster/encounter-engine-postgres:latest` matches between Task 5's accessory and Task 7's build. `KAMAL_VERSION` in the hook is Kamal's own variable. `/tmp/listeners-before.txt` is written in Task 4 Step 1 and read in Task 4 Step 5 and Task 5 Step 7.
