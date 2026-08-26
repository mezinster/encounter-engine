# SMTP Endpoint Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cutting production between SMTP vendors a variable change plus a deploy, instead of five secret edits, a commit and a deploy.

**Architecture:** One repository variable `MAIL_ROLE` names the live vendor. One committed plain-YAML map `ops/smtp/endpoints.yml` gives each vendor its host and port. One pure resolver, `ops/smtp/roles.rb`, turns those two into "live" and "standby" facts, and **both** the deploy and probe workflows call it — so they cannot disagree. Secrets are renamed from roles (`SPARE`) to vendors (`GMAIL`, `FASTMAIL`), which means a cutover edits no secrets at all.

**Tech Stack:** Ruby 3.3.12 (stdlib only for `ops/`), GitHub Actions, Kamal 2.12, RSpec.

**Spec:** `docs/superpowers/specs/2026-08-26-smtp-endpoint-switcher-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix commands with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Isolate the test database.** Export
  `DATABASE_URL="sqlite3:$SCRATCH/test.sqlite3"` where `$SCRATCH` is the session scratchpad, and run
  **one test command at a time** — the isolated DB is a single sqlite file and concurrent runs raise
  `SQLite3::BusyException`, which looks like a real failure and is not.
- **Never edit a `.feature` file.** Not one byte.
- **Nothing under `ops/` may require Rails.** These scripts run on a bare GitHub runner:
  `net/smtp`, `json`, `yaml` only.
- **No e-mail address, credential value, or personal data in any committed file.** The repository is
  public and the probe workflow files public issues. Truncation is not redaction.
- **`config/deploy.yml` and `.github/workflows/deploy.yml` are production-critical.** Do not touch the
  OIDC flow, the just-in-time NSG rule, or the Kamal invocation's structure.
- **Secrets are named `SMTP_<VENDOR>_<USE>_<FIELD>`** — `SMTP_GMAIL_DEPLOY_USERNAME`,
  `SMTP_FASTMAIL_PROBE_PASSWORD`, and so on. No name may contain a word whose meaning changes on
  cutover (`PRIMARY`, `SPARE`).
- **`MAIL_ROLE` values are vendor names**, lowercase: `gmail` or `fastmail`.
- Repo style: hash rockets (`:key => value`), `# -*- encoding : utf-8 -*-` where the surrounding file
  has it. `ops/` files use `# frozen_string_literal: true`, matching `ops/vmscale/policy.rb`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `ops/smtp/endpoints.yml` | **New.** Vendor → `{host, port}`. Data only, no logic. |
| `ops/smtp/roles.rb` | **New.** Pure resolver: `(role, endpoints) → live/standby facts`. The single source both workflows consume. |
| `spec/ops/smtp_roles_spec.rb` | **New.** Resolver examples, fixtures, no network, `spec_helper`. |
| `docs/runbooks/smtp-credentials.md` | **New.** The inventory answering "which secret is which". |
| `ops/smtp/probe.rb` | Carries the vendor name per role into its verdict. |
| `spec/ops/smtp_probe_spec.rb` | Examples for the vendor labelling. |
| `.github/workflows/smtp-probe.yml` | Resolves via `roles.rb`; uses vendor-named probe secrets. |
| `.github/workflows/deploy.yml` | Resolves via `roles.rb`; selects the vendor's deploy secrets. |
| `config/deploy.yml` | `SMTP_ADDRESS`/`SMTP_PORT` move from `env.clear` to `env.secret`. |
| `.kamal/secrets` | Sources those two from the environment. `MAIL_FROM` line unchanged. |
| `docs/runbooks/smtp-failover.md` | §3/§6 collapse to *set variable, deploy, verify*. |
| `CLAUDE.md` | Short note on the naming scheme and where the pointer lives. |

---

## Task 1: The map and the resolver

**Files:**
- Create: `ops/smtp/endpoints.yml`
- Create: `ops/smtp/roles.rb`
- Test: `spec/ops/smtp_roles_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `SMTPRoles.resolve(role:, endpoints:)` returning a Hash with String keys:
  `{"live" => {"vendor" => "gmail", "host" => "smtp.gmail.com", "port" => 587},
    "standby" => {"vendor" => "fastmail", "host" => "smtp.fastmail.com", "port" => 587}}`.
  Raises `ArgumentError` on an unknown role, a map with fewer than two vendors, or a vendor entry
  missing `host`. Also `SMTPRoles::ENDPOINTS_PATH` (String, `"ops/smtp/endpoints.yml"`).
  Running the file directly writes `live_vendor`, `live_host`, `live_port`, `standby_vendor`,
  `standby_host`, `standby_port` to `$GITHUB_OUTPUT`.

- [ ] **Step 1: Write the failing test**

Create `spec/ops/smtp_roles_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require_relative "../../ops/smtp/roles"

# resolve is a pure function: no network, no clock, no ENV. Same reasoning as
# spec/ops/vmscale_policy_spec.rb -- the workflow gathers, the Ruby decides, and
# only the deciding is tested here.
RSpec.describe SMTPRoles do
  MAP = {
    "gmail"    => { "host" => "smtp.gmail.com",    "port" => 587 },
    "fastmail" => { "host" => "smtp.fastmail.com", "port" => 587 }
  }.freeze

  it "puts the named vendor live and the other on standby" do
    result = described_class.resolve(:role => "gmail", :endpoints => MAP)

    expect(result["live"]["vendor"]).to eq("gmail")
    expect(result["live"]["host"]).to eq("smtp.gmail.com")
    expect(result["standby"]["vendor"]).to eq("fastmail")
    expect(result["standby"]["host"]).to eq("smtp.fastmail.com")
  end

  # The whole point of the design: the same map with a different pointer swaps
  # both roles, and nothing else anywhere has to change.
  it "swaps both roles when the pointer moves" do
    result = described_class.resolve(:role => "fastmail", :endpoints => MAP)

    expect(result["live"]["vendor"]).to eq("fastmail")
    expect(result["standby"]["vendor"]).to eq("gmail")
  end

  it "carries the port through" do
    result = described_class.resolve(:role => "gmail", :endpoints => MAP)

    expect(result["live"]["port"]).to eq(587)
    expect(result["standby"]["port"]).to eq(587)
  end

  # Loudly, not silently. A typo in MAIL_ROLE must stop the deploy, never
  # resolve to an empty host and ship mail configured to talk to nowhere.
  it "refuses an unknown role" do
    expect { described_class.resolve(:role => "gnail", :endpoints => MAP) }
      .to raise_error(ArgumentError, /gnail/)
  end

  it "refuses an empty role" do
    expect { described_class.resolve(:role => "", :endpoints => MAP) }
      .to raise_error(ArgumentError)
  end

  it "refuses a map that cannot name a standby" do
    expect { described_class.resolve(:role => "gmail", :endpoints => { "gmail" => { "host" => "x" } }) }
      .to raise_error(ArgumentError, /standby/)
  end

  it "refuses a vendor entry with no host" do
    broken = { "gmail" => { "port" => 587 }, "fastmail" => { "host" => "smtp.fastmail.com" } }

    expect { described_class.resolve(:role => "gmail", :endpoints => broken) }
      .to raise_error(ArgumentError, /host/)
  end

  # The shipped map is the one production actually uses, so assert on it rather
  # than only on fixtures -- a fixture-only spec would pass with the real file
  # empty or malformed.
  it "resolves against the shipped endpoints file" do
    endpoints = YAML.safe_load_file(
      File.expand_path("../../#{described_class::ENDPOINTS_PATH}", __dir__)
    )

    expect(endpoints.keys).to contain_exactly("gmail", "fastmail")
    expect(described_class.resolve(:role => "gmail", :endpoints => endpoints)["live"]["host"])
      .to eq("smtp.gmail.com")
  end
end
```

- [ ] **Step 2: Run the test and watch it fail for the right reason**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/ops/smtp_roles_spec.rb
```

Expected: `cannot load such file -- ops/smtp/roles`.

- [ ] **Step 3: Write the map**

Create `ops/smtp/endpoints.yml`:

```yaml
# Every SMTP vendor this app can send through, and how to reach it.
#
# Plain YAML with no ERB, deliberately. Kamal DOES evaluate ERB in
# config/deploy.yml (kamal-2.12.0/lib/kamal/configuration.rb:42), and an earlier
# sketch of this feature put the host selection there -- but
# .github/workflows/smtp-probe.yml reads its configuration with
# YAML.unsafe_load_file, which does NOT evaluate ERB, so the probe would have
# received the literal string "<%= ... %>" and tried to dial it as a hostname.
# Two components, one file, different parsers. Keeping this file free of ERB is
# what makes it safe for both to read.
#
# Which vendor is LIVE is not recorded here -- that is the MAIL_ROLE repository
# variable, because a cutover must not require a commit, push and merge while
# mail is down. This file holds the facts; the variable holds the pointer.
#
# See docs/superpowers/specs/2026-08-26-smtp-endpoint-switcher-design.md
gmail:
  host: smtp.gmail.com
  port: 587
fastmail:
  host: smtp.fastmail.com
  port: 587
```

- [ ] **Step 4: Write the resolver**

Create `ops/smtp/roles.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns "which vendor is live" plus the endpoint map into the facts both
# workflows need, so they cannot disagree about what production is doing.
#
# BOTH .github/workflows/deploy.yml and .github/workflows/smtp-probe.yml call
# this. That is the point: the probe following the deploy automatically -- in
# host AND credential -- is what removes the class of bug where a cutover leaves
# the monitor testing the vendor you just left.
#
# `resolve` is pure: no network, no clock, no ENV. Same split as
# ops/vmscale/policy.rb -- the caller gathers, the Ruby decides.
#
# No Rails. This runs on a bare GitHub runner; yaml and json only.

require "yaml"

module SMTPRoles
  ENDPOINTS_PATH = "ops/smtp/endpoints.yml"

  module_function

  # role -> the vendor name that is currently live, e.g. "gmail".
  # endpoints -> the parsed contents of ENDPOINTS_PATH.
  def resolve(role:, endpoints:)
    vendor = role.to_s
    raise ArgumentError, "MAIL_ROLE is empty -- nothing says which vendor is live" if vendor.empty?

    unless endpoints.key?(vendor)
      raise ArgumentError,
            "MAIL_ROLE is #{vendor.inspect}, which is not in #{ENDPOINTS_PATH} " \
            "(known: #{endpoints.keys.join(', ')})"
    end

    standby = (endpoints.keys - [vendor]).first
    if standby.nil?
      raise ArgumentError,
            "#{ENDPOINTS_PATH} names only #{vendor.inspect}, so there is no standby to watch"
    end

    { "live" => facts(vendor, endpoints), "standby" => facts(standby, endpoints) }
  end

  def facts(vendor, endpoints)
    entry = endpoints.fetch(vendor)
    host  = entry["host"].to_s
    raise ArgumentError, "#{ENDPOINTS_PATH} entry #{vendor.inspect} has no host" if host.empty?

    { "vendor" => vendor, "host" => host, "port" => (entry["port"] || 587).to_i }
  end
end

if $PROGRAM_NAME == __FILE__
  resolved = SMTPRoles.resolve(
    :role      => ENV["MAIL_ROLE"],
    :endpoints => YAML.safe_load_file(SMTPRoles::ENDPOINTS_PATH)
  )

  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
    %w[live standby].each do |slot|
      resolved.fetch(slot).each { |key, value| f.puts "#{slot}_#{key}=#{value}" }
    end
  end

  # stderr, so it lands in the run log without polluting anything parsing stdout.
  warn "live: #{resolved['live']['vendor']} (#{resolved['live']['host']}:#{resolved['live']['port']}) " \
       "standby: #{resolved['standby']['vendor']}"
end
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
bundle exec rspec spec/ops/smtp_roles_spec.rb
```

Expected: 8 examples, 0 failures.

- [ ] **Step 6: Prove the runner block works, since no spec covers it**

```bash
cd "$(git rev-parse --show-toplevel)"
GITHUB_OUTPUT=/tmp/out.$$ MAIL_ROLE=fastmail ruby ops/smtp/roles.rb && cat /tmp/out.$$ && rm -f /tmp/out.$$
```

Expected output contains `live_vendor=fastmail`, `live_host=smtp.fastmail.com`, `live_port=587`,
`standby_vendor=gmail`. Put this output in your report.

Then prove it fails loudly:

```bash
GITHUB_OUTPUT=/tmp/out.$$ MAIL_ROLE=gnail ruby ops/smtp/roles.rb; echo "exit=$?"; rm -f /tmp/out.$$
```

Expected: a non-zero exit and a message naming `gnail` and the known vendors.

- [ ] **Step 7: Commit**

```bash
git add ops/smtp/endpoints.yml ops/smtp/roles.rb spec/ops/smtp_roles_spec.rb
git commit -m "Add the SMTP endpoint map and its resolver"
```

---

## Task 2: The probe reports vendors, not just roles

**Files:**
- Modify: `ops/smtp/probe.rb` (the `check`/`classify` pair and the runner block)
- Test: `spec/ops/smtp_probe_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1 at runtime — the workflow passes vendor names in as env vars, so
  `probe.rb` stays free of map-reading and stays independently testable.
- Produces: every result Hash gains `"vendor"` (String). `classify`'s summary names the vendor
  alongside the role. New env vars read by the runner block: `SMTP_LIVE_VENDOR`,
  `SMTP_STANDBY_VENDOR`.

- [ ] **Step 1: Write the failing test**

Append to `spec/ops/smtp_probe_spec.rb`, inside the existing `RSpec.describe SMTPProbe` block:

```ruby
  describe "vendor labelling" do
    def ok_with(role, vendor)
      { "role" => role, "vendor" => vendor, "configured" => true, "ok" => true }
    end

    def broken_with(role, vendor)
      { "role" => role, "vendor" => vendor, "configured" => true, "ok" => false,
        "error_class" => "Net::SMTPAuthenticationError", "error" => "535 5.7.8 nope" }
    end

    # "primary" alone is unreadable six months later, and actively misleading
    # after a cutover: it names a role whose vendor has changed. The issue this
    # files is public and long-lived, so it must say WHICH vendor failed.
    it "names the vendor in a failure summary, not just the role" do
      result = described_class.classify([broken_with("primary", "fastmail"), ok_with("spare", "gmail")])

      expect(result["summary"]).to include("fastmail")
      expect(result["verdict"]).to eq("down")
    end

    it "names the vendor when the standby is the broken one" do
      result = described_class.classify([ok_with("primary", "fastmail"), broken_with("spare", "gmail")])

      expect(result["summary"]).to include("gmail")
      expect(result["verdict"]).to eq("degraded")
    end

    # A green run is the cheapest place to answer "which is which right now",
    # so the healthy summary carries the mapping too.
    it "states the live and standby vendors even when everything passes" do
      result = described_class.classify([ok_with("primary", "gmail"), ok_with("spare", "fastmail")])

      expect(result["verdict"]).to eq("ok")
      expect(result["summary"]).to include("gmail")
      expect(result["summary"]).to include("fastmail")
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/ops/smtp_probe_spec.rb -e "vendor labelling"
```

Expected: FAIL — the summaries contain role words but no vendor names.

- [ ] **Step 3: Carry the vendor through `check`**

In `ops/smtp/probe.rb`, `check` currently takes `role:` and returns Hashes keyed
`role`/`configured`/`ok`. Add a `vendor:` keyword argument and include `"vendor" => vendor` in **all
three** return paths — the unconfigured early return, the success return, and the `rescue` return.
Miss one and a failure summary silently loses the vendor exactly when it matters most.

- [ ] **Step 4: Name the vendor in `classify`'s summary**

Replace the `summary` assignment in `classify` with:

```ruby
    # Roles are positions; vendors are facts. After a cutover "primary" means a
    # different company than it did last week, and this string outlives the
    # incident in a public issue -- so say both.
    mapping = results.map { |r| "#{r['role']}: #{r['vendor']}" }.join(", ")

    summary =
      if failures.empty?
        (["all configured SMTP endpoints authenticate (#{mapping})"] + notes).join("; ")
      else
        described = failures.map do |f|
          "#{f['role']} (#{f['vendor']}): #{f['error_class']} #{f['error']}"
        end
        (described + notes).join("; ")
      end
```

- [ ] **Step 5: Pass vendors in from the environment**

In the runner block at the bottom of `ops/smtp/probe.rb`, add `:vendor` to both `check` calls:

```ruby
    SMTPProbe.check(role: "primary",
                    vendor:      ENV["SMTP_LIVE_VENDOR"].to_s,
                    address:     ENV["SMTP_ADDRESS"] || "smtp.gmail.com",
                    ...
    SMTPProbe.check(role: "spare",
                    vendor:      ENV["SMTP_STANDBY_VENDOR"].to_s,
                    address:     ENV["SMTP_SPARE_ADDRESS"],
                    ...
```

Leave every other line of the runner block alone, including the `helo_domain` guard — that
`.to_s.empty?` check exists because a GitHub Actions `env:` fed from an empty step output is `""`
rather than unset, and removing it reintroduces a bare `EHLO`.

- [ ] **Step 6: Run the tests and verify they pass**

```bash
bundle exec rspec spec/ops/smtp_probe_spec.rb
```

Expected: all pass, including the pre-existing redaction and verdict examples.

- [ ] **Step 7: Commit**

```bash
git add ops/smtp/probe.rb spec/ops/smtp_probe_spec.rb
git commit -m "Name the vendor, not just the role, in probe verdicts"
```

---

## Task 3: The probe workflow resolves from the map

**Files:**
- Modify: `.github/workflows/smtp-probe.yml` (the `cfg` step and the `Probe both endpoints` step)

**Interfaces:**
- Consumes: `ops/smtp/roles.rb` (Task 1) and the `SMTP_LIVE_VENDOR`/`SMTP_STANDBY_VENDOR` env vars
  (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Replace the `cfg` step**

The current `cfg` step reads `config/deploy.yml`. It must now read `MAIL_ROLE` and the map. Replace
the whole step with:

```yaml
      # Both this workflow and deploy.yml call the same resolver, so the probe
      # cannot end up watching a different vendor than the one production is
      # sending through. Before this, the host came from config/deploy.yml while
      # the credential came from a fixed secret -- the host followed a cutover
      # and the credential did not, so the probe authenticated Gmail against
      # Fastmail and filed a `down` issue every six hours while the app was fine.
      - name: Resolve which vendor is live
        id: cfg
        env:
          MAIL_ROLE: ${{ vars.MAIL_ROLE }}
        run: |
          set -euo pipefail
          ruby ops/smtp/roles.rb
```

- [ ] **Step 2: Repoint the probe step's env**

In the `Probe both endpoints` step, replace the `SMTP_*` env entries with:

```yaml
          SMTP_ADDRESS: ${{ steps.cfg.outputs.live_host }}
          SMTP_PORT: ${{ steps.cfg.outputs.live_port }}
          SMTP_LIVE_VENDOR: ${{ steps.cfg.outputs.live_vendor }}
          SMTP_STANDBY_VENDOR: ${{ steps.cfg.outputs.standby_vendor }}
          SMTP_SPARE_ADDRESS: ${{ steps.cfg.outputs.standby_host }}
          SMTP_SPARE_PORT: ${{ steps.cfg.outputs.standby_port }}
          # Indexed by vendor so a cutover needs no secret edit. Both pairs are
          # passed in and the script below picks -- rather than `secrets[...]`
          # dynamic indexing, which works but is harder to read in a log when
          # something is wrong at 3am.
          GMAIL_PROBE_USERNAME: ${{ secrets.SMTP_GMAIL_PROBE_USERNAME }}
          GMAIL_PROBE_PASSWORD: ${{ secrets.SMTP_GMAIL_PROBE_PASSWORD }}
          FASTMAIL_PROBE_USERNAME: ${{ secrets.SMTP_FASTMAIL_PROBE_USERNAME }}
          FASTMAIL_PROBE_PASSWORD: ${{ secrets.SMTP_FASTMAIL_PROBE_PASSWORD }}
          # Literal, matching config/deploy.yml's env.clear.APP_HOST. Verified
          # 2026-08-26 that this repository has no Actions variables at all, so
          # there is no vars.APP_HOST to read. If APP_HOST ever changes, it
          # changes in both places -- which is why the value is named here
          # rather than silently defaulted inside probe.rb.
          APP_HOST: game.mezin.eu
```

Then replace that step's `run:` block with:

```bash
          # Plain case, assigning directly. An earlier draft of this plan used a
          # pick() helper called in a command substitution -- and its `exit 1`
          # for an unknown vendor would have exited only the SUBSHELL, leaving an
          # empty prefix and, under `set +e`, empty credentials. The probe would
          # then have reported "not configured" instead of failing. Unreachable
          # in practice (the vendor comes from our own validated resolver) but
          # silent, which is the failure shape this project keeps removing.
          select_creds() {
            case "$1" in
              gmail)    printf '%s\n%s\n' "$GMAIL_PROBE_USERNAME"    "$GMAIL_PROBE_PASSWORD" ;;
              fastmail) printf '%s\n%s\n' "$FASTMAIL_PROBE_USERNAME" "$FASTMAIL_PROBE_PASSWORD" ;;
              *)        return 1 ;;
            esac
          }

          set -euo pipefail
          if ! { read -r SMTP_USERNAME; read -r SMTP_PASSWORD; } < <(select_creds "$SMTP_LIVE_VENDOR"); then
            echo "unknown live vendor '${SMTP_LIVE_VENDOR}' -- refusing to probe nothing" >&2
            exit 1
          fi
          if ! { read -r SMTP_SPARE_USERNAME; read -r SMTP_SPARE_PASSWORD; } < <(select_creds "$SMTP_STANDBY_VENDOR"); then
            echo "unknown standby vendor '${SMTP_STANDBY_VENDOR}' -- refusing to probe nothing" >&2
            exit 1
          fi
          export SMTP_USERNAME SMTP_PASSWORD SMTP_SPARE_USERNAME SMTP_SPARE_PASSWORD

          # set +e only around the probe itself: its non-zero exit is DATA (the
          # verdict), not a failure of this step. Everything above must abort.
          set +e
          ruby ops/smtp/probe.rb > verdict.json
          echo "exit_code=$?" >> "$GITHUB_OUTPUT"
          cat verdict.json
```

If process substitution (`< <(...)`) reads awkwardly to you, an equally correct shape is a single
`case` that assigns all four variables inline per vendor, with a `*)` arm that echoes and exits at
**top level**. Either is fine; what is not fine is any form where the failure arm runs inside a
subshell, because there its `exit` cannot stop the step.

**`APP_HOST` note:** the old `cfg` step supplied it from `config/deploy.yml`. The resolver does not
read that file, so it is a literal now, matching `config/deploy.yml`'s `env.clear.APP_HOST`. Do not
reintroduce a `config/deploy.yml` read to get it — that coupling is exactly what Task 1's map exists
to remove, and re-adding it for one value would put the probe back on two sources of truth.

It matters that this stays a real value rather than leaning on `probe.rb`'s internal default: that
default exists only to stop a bare `EHLO` when the variable arrives empty, and a silent fallback is
not the same thing as a configured value.

- [ ] **Step 2b: Prove the unknown-vendor arm actually aborts**

The whole point of the rewrite above is that a bad vendor stops the step rather than silently
probing with empty credentials. Verify it locally rather than trusting the shape:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
cat > /tmp/arm.$$ <<'SH'
GMAIL_PROBE_USERNAME=u; GMAIL_PROBE_PASSWORD=p
FASTMAIL_PROBE_USERNAME=u2; FASTMAIL_PROBE_PASSWORD=p2
SMTP_LIVE_VENDOR=gnail
SH
# append your select_creds function and the two `if ! { read ... }` guards, then:
bash /tmp/arm.$$; echo "exit=$?"; rm -f /tmp/arm.$$
```

Expected: a non-zero exit and the message naming `gnail`. If it exits 0, the failure arm is inside a
subshell and the guard does nothing — fix it before moving on and say so in your report.

- [ ] **Step 3: Validate the YAML**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/smtp-probe.yml", aliases: true); puts "yaml ok"'
```

Expected: `yaml ok`.

- [ ] **Step 4: Confirm no `config/deploy.yml` read remains**

```bash
grep -n "load_file\|unsafe_load" .github/workflows/smtp-probe.yml
```

Expected: no match. If one remains, the probe still reads a second source of truth and Task 1's whole
purpose is defeated.

Check the **functional read**, not the string `deploy.yml`. An earlier version of this step grepped for
the filename and expected zero hits — but the comments in this workflow legitimately *mention*
`config/deploy.yml` while explaining why it is no longer read, and why both workflows now share one
resolver. Those comments are the most valuable lines in the file. A check that would be satisfied by
deleting them is measuring the wrong thing.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/smtp-probe.yml
git commit -m "Resolve the probe's endpoints from MAIL_ROLE and the map"
```

---

## Task 4: The deploy selects the live vendor's credentials

**Files:**
- Modify: `config/deploy.yml` (the `env` block, around lines 60-82)
- Modify: `.kamal/secrets`
- Modify: `.github/workflows/deploy.yml` (the `Deploy` step and the SMTP verification steps)

**Interfaces:**
- Consumes: `ops/smtp/roles.rb` (Task 1).
- Produces: nothing later tasks depend on in code.

**Read `.github/workflows/deploy.yml` in full before editing.** Do not touch the OIDC login, the NSG
rule steps, or the retry loop. Your edits are: one new resolver step, the `Deploy` step's env and
`run`, and the two SMTP verification steps added previously.

- [ ] **Step 1: Move the host and port out of `env.clear`**

In `config/deploy.yml`, delete `SMTP_ADDRESS` and `SMTP_PORT` from `env.clear` — including the
comment above them, which points at a runbook step that will no longer exist — and add both to the
`env.secret` list:

```yaml
  secret:
    - SECRET_KEY_BASE
    - DATABASE_URL
    # Not secrets in any real sense -- they are in ops/smtp/endpoints.yml, in
    # git. They travel through the secrets file because that is Kamal's
    # mechanism for "a value the deploy supplies", and the deploy now picks them
    # from the map according to MAIL_ROLE rather than from a committed literal.
    - SMTP_ADDRESS
    - SMTP_PORT
    - SMTP_USERNAME
    - SMTP_PASSWORD
    # Derived from SMTP_USERNAME rather than set here — see .kamal/secrets.
    - MAIL_FROM
    - ANTHROPIC_API_KEY
```

- [ ] **Step 2: Source them in `.kamal/secrets`**

Add immediately above the existing `SMTP_USERNAME` line:

```bash
# Supplied by the deploy workflow from ops/smtp/endpoints.yml, selected by the
# MAIL_ROLE repository variable. Not committed as a literal any more: a cutover
# must not require a commit, push and merge while mail is down.
SMTP_ADDRESS=$SMTP_ADDRESS
SMTP_PORT=$SMTP_PORT
```

Leave `MAIL_FROM=${SMTP_USERNAME}` exactly as it is. It is what makes the From address follow the
vendor automatically, and the comment above it explains why that matters for SPF.

- [ ] **Step 3: Add the resolver step to the deploy workflow**

Insert immediately before the existing `Deploy` step:

```yaml
      # The same resolver the probe uses, so the two cannot disagree about which
      # vendor production is sending through. A bad MAIL_ROLE fails HERE, before
      # anything is deployed, rather than shipping mail pointed at nowhere.
      - name: Resolve which SMTP vendor to ship
        id: mail
        if: success() && inputs.command == 'deploy'
        env:
          MAIL_ROLE: ${{ vars.MAIL_ROLE }}
        run: |
          set -euo pipefail
          ruby ops/smtp/roles.rb
```

- [ ] **Step 4: Select the credentials in the `Deploy` step**

Replace the `Deploy` step's `SMTP_USERNAME`/`SMTP_PASSWORD` env lines with all four vendor secrets
plus the resolved host, keeping every other entry untouched:

```yaml
          SMTP_ADDRESS: ${{ steps.mail.outputs.live_host }}
          SMTP_PORT: ${{ steps.mail.outputs.live_port }}
          MAIL_ROLE: ${{ vars.MAIL_ROLE }}
          SMTP_GMAIL_DEPLOY_USERNAME: ${{ secrets.SMTP_GMAIL_DEPLOY_USERNAME }}
          SMTP_GMAIL_DEPLOY_PASSWORD: ${{ secrets.SMTP_GMAIL_DEPLOY_PASSWORD }}
          SMTP_FASTMAIL_DEPLOY_USERNAME: ${{ secrets.SMTP_FASTMAIL_DEPLOY_USERNAME }}
          SMTP_FASTMAIL_DEPLOY_PASSWORD: ${{ secrets.SMTP_FASTMAIL_DEPLOY_PASSWORD }}
```

and replace its `run:` with:

```bash
          set -euo pipefail
          case "$MAIL_ROLE" in
            gmail)
              export SMTP_USERNAME="$SMTP_GMAIL_DEPLOY_USERNAME"
              export SMTP_PASSWORD="$SMTP_GMAIL_DEPLOY_PASSWORD" ;;
            fastmail)
              export SMTP_USERNAME="$SMTP_FASTMAIL_DEPLOY_USERNAME"
              export SMTP_PASSWORD="$SMTP_FASTMAIL_DEPLOY_PASSWORD" ;;
            *)
              echo "MAIL_ROLE is '${MAIL_ROLE}' -- refusing to deploy mail configured for nobody" >&2
              exit 1 ;;
          esac

          if [ -z "$SMTP_USERNAME" ] || [ -z "$SMTP_PASSWORD" ]; then
            echo "the ${MAIL_ROLE} deploy credentials are empty -- are the environment secrets set?" >&2
            exit 1
          fi

          echo "shipping mail via ${MAIL_ROLE} (${SMTP_ADDRESS}:${SMTP_PORT})"
          bundle exec kamal ${{ inputs.command }}
```

The empty-check matters: environment secrets that do not exist expand to empty strings rather than
failing, which is exactly how the probe's first live run reported `primary not configured`.

Keep the existing comment above `ANTHROPIC_API_KEY` about enumerating secrets explicitly — it now
applies to six more names and is more true than before, not less.

- [ ] **Step 5: Repoint the verification steps**

The `Read the app's configured SMTP host, port, and HELO domain` step reads `config/deploy.yml`,
which no longer carries the host. Delete that step and take its values from `steps.mail.outputs`
instead. In `Verify the shipped SMTP credential (the deploy itself already completed)`:

- `SMTP_ADDRESS` / `SMTP_PORT` come from `steps.mail.outputs.live_host` / `live_port`
- add `SMTP_LIVE_VENDOR: ${{ steps.mail.outputs.live_vendor }}` and
  `SMTP_STANDBY_VENDOR: ${{ steps.mail.outputs.standby_vendor }}`
- `SMTP_USERNAME`/`SMTP_PASSWORD` select by `MAIL_ROLE` the same way the `Deploy` step does
- the spare's values come from the vendor-named **probe** secrets, since the deploy credentials for
  the standby vendor are not what the probe watches

Keep its step name, its `$GITHUB_STEP_SUMMARY` write, and its non-zero exit on a bad verdict.

- [ ] **Step 6: Validate both workflows and the deploy config**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
ruby -ryaml -e 'YAML.safe_load_file(".github/workflows/deploy.yml", aliases: true); puts "deploy.yml ok"'
ruby -ryaml -e 'c=YAML.unsafe_load_file("config/deploy.yml"); raise "SMTP_ADDRESS still in clear" if c.dig("env","clear","SMTP_ADDRESS"); raise "SMTP_ADDRESS not in secret" unless c.dig("env","secret").include?("SMTP_ADDRESS"); puts "deploy config ok"'
```

Expected: both print their ok line.

- [ ] **Step 7: Confirm the OIDC and NSG machinery is untouched**

```bash
git diff --stat HEAD -- .github/workflows/deploy.yml
git diff HEAD -- .github/workflows/deploy.yml | grep "^-[^-]" | grep -i "azure\|nsg\|oidc\|client-id\|ssh" || echo "no OIDC/NSG/SSH lines removed"
```

Expected: the second command prints its message. If it lists removals, you have changed something
production-critical — stop and report.

- [ ] **Step 8: Commit**

```bash
git add config/deploy.yml .kamal/secrets .github/workflows/deploy.yml
git commit -m "Ship the SMTP vendor selected by MAIL_ROLE"
```

---

## Task 5: The credentials inventory

**Files:**
- Create: `docs/runbooks/smtp-credentials.md`

**Interfaces:** none.

- [ ] **Step 1: Write the inventory**

The repository owner's stated problem is *"I am already a bit lost on which is which."* This file is
the answer, so lead with the table, not with prose.

Cover:

1. **A table of all eight secrets**: name, scope (`production` environment / repository), vendor,
   purpose in one clause, and where the value is kept.
2. **The rotation command per secret**, with the correct `--env production` already in the line for
   the four deploy credentials and deliberately absent for the four probe ones. Add a sentence saying
   the flag is load-bearing: omitting it creates a repository secret that the deploy silently ignores,
   because an environment secret shadows a repository one for a job declaring that environment.
3. **The one thing that makes rotation easy now**: no rotation requires knowing which vendor is live.
   Vendor-named secrets mean Gmail's deploy password is always the same pair, whatever `MAIL_ROLE`
   says. Contrast this explicitly with the old scheme, where the answer decided whether you edited
   `SMTP_USERNAME` or `SMTP_SPARE_*`, and the wrong guess did nothing.
4. **The Fastmail asymmetry, recorded honestly**: its deploy and probe secrets hold the *same* app
   password, so revoking it stops sending and monitoring together, where Gmail's are independent.
   This is carried over from the old `SMTP_SPARE_*` posture rather than introduced, and it is a
   candidate for symmetry next time anyone is in Fastmail's settings.
5. **A warning that GitHub secrets are write-only.** There is no API returning a value, and
   `GITHUB_TOKEN` cannot write secrets, so a secret whose value exists nowhere else can never be
   renamed, copied or audited — only replaced by generating a new one at the vendor. Say plainly that
   every value here must also live in a password manager.
6. **How to find out what is live right now**: `gh variable get MAIL_ROLE`, and the fact that the last
   green probe run and the last deploy's step summary both state it.

- [ ] **Step 2: Confirm no value leaked into the file**

```bash
grep -nE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" docs/runbooks/smtp-credentials.md || echo "no address-shaped strings"
```

Expected: the message. Any hit is a real finding — this repository is public.

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/smtp-credentials.md
git commit -m "Add the SMTP credential inventory"
```

---

## Task 6: Simplify the failover runbook

**Files:**
- Modify: `docs/runbooks/smtp-failover.md`
- Modify: `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: Collapse §3 and §6**

Cutting over becomes:

```bash
gh variable set MAIL_ROLE --body fastmail
gh workflow run deploy.yml -f command=deploy
```

and cutting back the same with `gmail`. Delete the `gh secret set` steps, the `SMTP_SPARE_*`
role-swap step, the `SMTP_PROBE_*` rotation step, and the `config/deploy.yml` edit — every one of
them now has nothing to do. Keep the verification sections (§4/§5) intact; they are unaffected and
still the only check that sees what actually arrived.

Add one sentence explaining *why* there are no secrets to set: secrets are named by vendor, so
nothing means "whatever is not primary" and nothing has to be rewritten when the roles swap.

- [ ] **Step 2: Update §8**

The bullet about the probe credential not following a cutover describes a problem that no longer
exists — the probe now resolves both host and credential from `MAIL_ROLE`. Replace it with what
remains true, and point at `smtp-credentials.md` for the Fastmail asymmetry.

- [ ] **Step 3: Note the scheme in `CLAUDE.md`**

Add a short subsection near the deployment notes: secrets are named `SMTP_<VENDOR>_<USE>_<FIELD>`;
`MAIL_ROLE` is a repository variable naming the live vendor; `ops/smtp/endpoints.yml` maps vendors to
hosts; both the deploy and the probe resolve through `ops/smtp/roles.rb` so they cannot disagree.
Match the file's voice — explain why, and say what went wrong before.

- [ ] **Step 4: Run the suite**

`docs/runbooks` is read by four specs, so a documentation change here really can redden the default
run — heading renames break anchor-integrity examples.

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
DATABASE_URL="sqlite3:$SCRATCH/test.sqlite3" bundle exec rspec
```

Expected: 0 failures. Report the real example count.

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/smtp-failover.md CLAUDE.md
git commit -m "A cutover is now a variable and a deploy"
```

---

## Task 7: Migration (operator, not agent)

**Files:** none. Performed by the repository owner.

**Interfaces:**
- Consumes: Tasks 1-6 merged.
- Produces: eight vendor-named secrets and the `MAIL_ROLE` variable.

Ordered so everything before the merge is inert and the only irreversible step is last.

- [ ] **Step 1: Add the four deploy secrets to the `production` environment**, from values already
      held. Gmail's are what `SMTP_USERNAME`/`SMTP_PASSWORD` hold today; Fastmail's are what
      `SMTP_SPARE_USERNAME`/`SMTP_SPARE_PASSWORD` hold.

```bash
gh secret set SMTP_GMAIL_DEPLOY_USERNAME --env production
gh secret set SMTP_GMAIL_DEPLOY_PASSWORD --env production
gh secret set SMTP_FASTMAIL_DEPLOY_USERNAME --env production
gh secret set SMTP_FASTMAIL_DEPLOY_PASSWORD --env production
```

- [ ] **Step 2: Add the four probe secrets at repository scope.** Fastmail's are the *same value* as
      its deploy credential, deliberately (spec §S6). Gmail's are the probe app password created
      2026-08-26.

```bash
gh secret set SMTP_GMAIL_PROBE_USERNAME
gh secret set SMTP_GMAIL_PROBE_PASSWORD
gh secret set SMTP_FASTMAIL_PROBE_USERNAME
gh secret set SMTP_FASTMAIL_PROBE_PASSWORD
```

- [ ] **Step 3: Set the pointer to what is already live**, so the first deploy changes nothing about
      mail:

```bash
gh variable set MAIL_ROLE --body gmail
```

- [ ] **Step 4: Merge, deploy, and verify.** The deploy's own final step authenticates what it
      shipped; then dispatch the probe and confirm a plain `ok` naming both vendors.

```bash
gh workflow run deploy.yml -f command=deploy
gh workflow run "SMTP probe"
```

- [ ] **Step 5: Only now, delete the seven old secrets.**

```bash
gh secret delete SMTP_USERNAME --env production
gh secret delete SMTP_PASSWORD --env production
gh secret delete SMTP_SPARE_ADDRESS
gh secret delete SMTP_SPARE_USERNAME
gh secret delete SMTP_SPARE_PASSWORD
gh secret delete SMTP_PROBE_USERNAME
gh secret delete SMTP_PROBE_PASSWORD
```

Deleting `SMTP_USERNAME` before the new code is live would break mail on the very next deploy. This
is the one irreversible move in the sequence, which is why it is last and separate.

- [ ] **Step 6: Rehearse a real cutover** now that it costs two commands, and record the date in
      `docs/runbooks/smtp-failover.md`'s `Rehearsed:` field. An unrehearsed procedure and a rehearsed
      one look identical in git.

---

## Self-Review Notes

Checked against the spec, 2026-08-26:

- **Spec coverage:** S1 (pointer) → Tasks 3, 4, 7 step 3; S2 (map) → Task 1; S3 (naming) → Tasks 3, 4,
  5, 7; S4 (probe derives roles) → Tasks 2, 3; S5 (`MAIL_FROM` untouched) → Task 4 step 2; S6
  (Fastmail asymmetry) → Tasks 5, 7 step 2. §2 (cutover shape) → Task 6. §3 (files) → the File
  Structure table. §4 (migration) → Task 7. §5 (testing) → Tasks 1, 2, 3, 4, 6. §8 (invariants) →
  Task 3 step 4, Task 4 steps 6-7, Task 6 step 4.
- **Type consistency:** `SMTPRoles.resolve` returns String-keyed Hashes with `live`/`standby` in Task
  1 and is consumed as `steps.*.outputs.live_host` etc. in Tasks 3 and 4, matching the runner block's
  `"#{slot}_#{key}"` output format. `probe.rb`'s `check` gains `vendor:` in Task 2 and is fed
  `SMTP_LIVE_VENDOR`/`SMTP_STANDBY_VENDOR` in Tasks 3 and 4.
- **Resolved during self-review:** Task 3's `APP_HOST` originally branched on `vars.APP_HOST`.
  Checked — this repository has no Actions variables at all, so that branch was dead. Replaced with
  the literal and a note on why it must not be fetched from `config/deploy.yml` instead.
- **Known soft spot, flagged rather than hidden:** Task 3 step 2b explicitly invites the implementer
  to replace the `eval` indirection with a plain `case` if it reads better. The values are not
  attacker-controlled — `pick` emits one of two literals — but shell indirection in a file someone
  reads at 3am deserves a second opinion, and the plan asks for one rather than pretending the
  question does not exist.
