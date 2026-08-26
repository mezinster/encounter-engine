# A deploy-time SMTP endpoint switcher

**Status:** design, approved 2026-08-26.
**Scope:** make cutting production between SMTP vendors a variable change plus a deploy, instead of
five secret edits, a commit and a deploy. Explicitly **not** automatic runtime failover — see §7.
**Builds on:** `docs/superpowers/specs/2026-08-25-smtp-outage-resilience-design.md`, which made an
SMTP outage survivable and detectable. This makes it *switchable*.

---

## 0. The gap

Cutting over today is `docs/runbooks/smtp-failover.md` §3: five `gh secret set` calls, a one-line edit
to `config/deploy.yml`, a commit, a push and a deploy. Three defects have already been found in that
procedure, and every one traces to the same root cause.

**Secrets are named after roles, and roles move.** `SMTP_SPARE_*` means "whatever is not primary", so
its correct value inverts the moment you cut over. Everything downstream inherits that:

* **The role-swap step exists at all.** §3 step 2 has to rewrite `SMTP_SPARE_*` to point at the
  outgoing vendor. Forget it and the probe authenticates one credential twice under two labels,
  `degraded` becomes structurally unreachable, and the endpoint you are waiting to recover goes
  unwatched.
* **The probe credential goes stale.** `SMTP_PROBE_*` is a Gmail app password, but the probe's primary
  role dials whatever `SMTP_ADDRESS` now is. Immediately after a cutover it authenticates Gmail
  against Fastmail, misreports `down`, and files a public issue every six hours *during an incident*.
* **A wrong `--env` scope fails silently.** `SMTP_USERNAME`/`SMTP_PASSWORD` live in the `production`
  environment; `SMTP_SPARE_*` and `SMTP_PROBE_*` live at repository scope. The runbook's promote step
  omitted `--env production`, which would have created a repository secret that the deploy ignores —
  a cutover that looks done and changes nothing.

The first two were fixed by adding more steps. The third by adding a flag. All three are the same
bug wearing different clothes, and adding steps to a procedure performed under stress is the wrong
direction of travel.

### 0.1 Why the obvious switcher does not work

The naive version — an ERB expression in `config/deploy.yml` driven by a dispatch input — breaks the
monitoring silently.

Kamal **does** evaluate ERB in `deploy.yml` (verified: `kamal-2.12.0/lib/kamal/configuration.rb:42`,
`ERB.new(template, trim_mode: "-").result`). But `.github/workflows/smtp-probe.yml` reads that same
file with `YAML.unsafe_load_file(...).dig("env","clear","SMTP_ADDRESS")`, and **`YAML.unsafe_load_file`
does not evaluate ERB**. The probe would receive the literal string `<%= ENV.fetch(...) %>` and try to
dial it as a hostname.

Two components, one file, different parsers. Each correct alone.

### 0.2 Why it cannot be a dispatch input

A `workflow_dispatch` input with `default: primary` reasserts itself on every dispatch. A routine
deploy shipping an unrelated feature would silently revert a live cutover, mid-incident. An input
with no default forces a mail decision onto every deploy that has nothing to do with mail, and still
leaves no readable record of what is live for the probe to consult.

The role has to be **state**, not a parameter.

---

## 1. Decisions

### S1 — one pointer, held outside git, named for a vendor

A GitHub **repository variable** `MAIL_ROLE`, whose value is a vendor name: `gmail` or `fastmail`.
Not `primary`/`spare` — those are the role words whose meaning moves, and this whole design exists to
delete them from anywhere a human has to keep them straight.

A variable rather than a committed value because a cutover must not require a commit, push and
merge while mail is down. A variable rather than a dispatch input because of §0.2.

It is readable by both workflows (`vars.MAIL_ROLE`) and settable in one command
(`gh variable set MAIL_ROLE --body fastmail`).

### S2 — one committed map, plain YAML, read by both workflows

`ops/smtp/endpoints.yml` maps each vendor to its host and port. It is ordinary YAML with no ERB, so
the §0.1 collision cannot occur: both the deploy workflow and the probe workflow parse the same file
the same way and reach the same answer.

This mirrors `ops/vmscale/ladder.json`, already established here — committed data, read by a workflow,
kept out of the code that decides.

The hosts stay in version control, so a change to them is a diff with a reviewer and a history. Only
the *pointer* lives outside git, and only because incidents cannot wait for a merge.

### S3 — secrets named `SMTP_<VENDOR>_<USE>_<FIELD>`

| Secret | Scope | Vendor | Use |
|---|---|---|---|
| `SMTP_GMAIL_DEPLOY_USERNAME` / `_PASSWORD` | `production` environment | Gmail | the app sends with this |
| `SMTP_FASTMAIL_DEPLOY_USERNAME` / `_PASSWORD` | `production` environment | Fastmail | the app sends with this |
| `SMTP_GMAIL_PROBE_USERNAME` / `_PASSWORD` | repository | Gmail | monitoring only |
| `SMTP_FASTMAIL_PROBE_USERNAME` / `_PASSWORD` | repository | Fastmail | monitoring only |

Seven secrets today become eight, and `SMTP_SPARE_ADDRESS` disappears into the map.

**Every name answers "which vendor" and "what for", and contains no word that changes meaning over
time.** Three consequences, all of them the point:

* **A cutover edits no secrets at all**, so there is no `--env` scope to get wrong. The §0 third
  defect stops being possible rather than being guarded against.
* **Nothing is ever rotated for a role change.** The §0 first defect — the role-swap step — has
  nothing left to do.
* **Rotating a credential never requires knowing the current role.** Today, rotating Gmail's app
  password means first answering "is Gmail primary or spare right now?", because the answer decides
  whether you edit `SMTP_USERNAME` or `SMTP_SPARE_*`, and the wrong guess silently does nothing.
  With vendor names it is always the same pair.

Deploy credentials stay **environment**-scoped, keeping the `production` environment's branch policy
between a branch and a live credential. Probe credentials are **repository**-scoped, because an
unattended six-hourly job cannot read environment secrets: `production` carries a required-reviewer
rule (verified), so `environment: production` on the probe would park every run on a human approval —
four a day, forever. That constraint is recorded in §D10 of the 2026-08-25 design.

### S4 — the probe derives its roles instead of being told them

The probe reads `MAIL_ROLE` and the map, labels the live vendor `primary` and the other `spare`, and
probes both using the `_PROBE_` credentials. It follows a cutover with no human step, in both host
**and** credential — closing the §0 second defect by construction.

`SMTPProbe.classify`'s verdict gains the vendor name per role, so its JSON and the issue it files say
`primary: fastmail` rather than leaving the reader to infer what "primary" meant that week. That also
answers "which is which" from the last green run rather than from memory.

### S5 — `MAIL_FROM` keeps deriving, untouched

`.kamal/secrets` composes `MAIL_FROM=${SMTP_USERNAME}`. The deploy workflow sets `SMTP_USERNAME` from
the selected vendor's `_DEPLOY_USERNAME`, so the From address follows the vendor automatically, as it
does today. No change to that line, and no second place for the sender identity to drift from the
credential actually authenticating.

This matters more than it looks: `mezin.eu`'s SPF authorises Fastmail only, and `gmail.com`'s
authorises Google only. A design where the credential could switch without the From address following
would send Fastmail mail claiming to be `@gmail.com` — SPF failure, and a spam folder.

### S6 — Fastmail's deploy and probe credentials are the same value, deliberately

Gmail has two distinct app passwords (deploy and probe). Fastmail has one, used for both.

This is a considered trade rather than an oversight. GitHub secrets are **write-only** — there is no
API returning a value, and `GITHUB_TOKEN` cannot write secrets, so copying one to a new name is not
possible without a PAT this repository deliberately does not use (see the credential-hygiene section
of `CLAUDE.md`). Every rename therefore means re-entering the value by hand, and the owner chose not
to generate anything new at the vendor for the sake of a naming scheme.

What it costs: revoking Fastmail's app password kills sending and monitoring together, where Gmail's
can be revoked independently. That is exactly today's posture for `SMTP_SPARE_*`, so it is not a
regression — only an improvement not taken. Recorded in the credentials runbook as a known asymmetry
and an obvious candidate for symmetry the next time anyone is in Fastmail's settings.

---

## 2. What a cutover becomes

```bash
gh variable set MAIL_ROLE --body fastmail
gh workflow run deploy.yml -f command=deploy
```

Then verify, unchanged from the 2026-08-25 design: the deploy's own final step authenticates the
credential it just shipped, and the header checks in the failover runbook confirm what actually
arrived. Cutting back is the same two commands with `gmail`.

No secret edits. No commit. No role to reason about.

---

## 3. Files

**New**

| Path | Purpose |
|---|---|
| `ops/smtp/endpoints.yml` | vendor → `{host, port}`. Plain YAML, no ERB. |
| `docs/runbooks/smtp-credentials.md` | The inventory: every secret, its scope, vendor, purpose, where its value is kept, and the exact rotation command with the correct `--env` flag baked in. |
| `spec/ops/smtp_endpoints_spec.rb` | Resolution is a pure function; fixtures, no network. |

**Modified**

| Path | Change |
|---|---|
| `config/deploy.yml` | `SMTP_ADDRESS`/`SMTP_PORT` move from `env.clear` to `env.secret`, composed by the workflow. The runbook pointer comment goes — there is nothing left to hand-edit. |
| `.kamal/secrets` | `SMTP_ADDRESS`/`SMTP_PORT` sourced from the environment. `MAIL_FROM` line unchanged (S5). |
| `.github/workflows/deploy.yml` | Resolve `MAIL_ROLE` + map → host, port and the vendor's `_DEPLOY_` credentials. Step summary states the vendor shipped. |
| `.github/workflows/smtp-probe.yml` | Resolve `MAIL_ROLE` + map → role labels; probe both vendors with `_PROBE_` credentials. The `cfg` step reads the map, not `deploy.yml`. |
| `ops/smtp/probe.rb` | Verdict carries the vendor per role. |
| `docs/runbooks/smtp-failover.md` | §3 and §6 collapse to *set variable, deploy, verify*. Most of what PR #150 added deletes itself. |
| `CLAUDE.md` | A short note on the naming scheme and where the pointer lives. |

`config/deploy.yml` is production-critical. The change to it is small, but the OIDC flow, the
just-in-time NSG rule and the Kamal invocation are not to be touched.

---

## 4. Migration

Ordered so that everything before the merge is inert and everything irreversible is last.

1. Add the four `*_DEPLOY_*` secrets to the `production` environment, from values already held.
2. Add the four `*_PROBE_*` secrets at repository scope. Fastmail's is the same value as its deploy
   credential (S6); Gmail's is the probe password created 2026-08-26.
3. `gh variable set MAIL_ROLE --body gmail` — matching what is live, so the first deploy changes
   nothing about mail.
4. Merge and deploy. Confirm mail works and the probe is green.
5. **Only then** delete the seven old secrets.

Steps 1–3 are purely additive: nothing reads the new names until step 4 ships the code, so the
rollback for the whole migration is "do not merge". Step 5 is last and separate because deleting
`SMTP_USERNAME` before the new code is live breaks mail on the very next deploy — the one
irreversible move in the sequence.

---

## 5. Testing

* **Resolution is a pure function** — `(role, map) → {host, port, credential names}` — tested from
  fixtures with no network, mirroring `spec/ops/vmscale_policy_spec.rb`. An unknown role, a map
  missing a vendor, and an empty value each fail loudly rather than resolving to something.
* **The probe's role labelling** gets examples for both `MAIL_ROLE` values, asserting the live vendor
  is labelled `primary` and that `degraded` still means "the standby is broken".
* **Workflow shell** is checked the way the last round's bugs were actually caught: YAML parse, plus a
  stub `gh` on `PATH` to exercise the branches — an empty issue lookup, a failing one, and a crashed
  probe must all still end with the operator informed.
* **The deploy path is proven by an actual deploy.** Neither suite evaluates
  `config/environments/production.rb`, and no local test can tell you whether Kamal shipped the right
  host. The deploy's own verification step is the check; the migration's step 4 is where it runs.

---

## 6. Failure modes accepted

* **`MAIL_ROLE` is state outside git**, so a change leaves no diff and no reviewer. Mitigated by both
  workflows reporting the resolved vendor on every run, but the audit trail is GitHub's variable
  history rather than the repository's.
* **A wrong `MAIL_ROLE` deploys the wrong vendor.** The deploy's verification step catches it within
  the same run, because it authenticates what it shipped — but it catches it after the deploy, not
  before.
* **Fastmail's revocation is coupled** (S6).
* **Still no runtime failover.** A cutover remains a deploy — four to five minutes, measured across
  the three most recent production deploys (3m51s, 4m18s, 4m52s) — initiated by a human who has
  noticed.

---

## 7. Non-goals

* **Automatic runtime failover.** Rejected again here, and the reasoning is stronger than before: the
  credential and the sender identity must switch atomically or SPF fails (S5); a connection dropped
  after `DATA` cannot be distinguished from a delivery whose acknowledgement was lost, so retrying on
  the other vendor sends some messages twice; and both live credentials would have to sit inside the
  container. Since the 2026-08-25 work an outage is no longer destructive — signups succeed and show
  the password, invitations succeed with a warning — so the value of shaving minutes off recovery is
  much lower than it was when that outage stranded accounts.
* **A third vendor.** The map admits one, but nothing here is built for it and no such need exists.
* **Promoting Fastmail to primary.** Still the obvious eventual move (it is SPF-aligned and
  DKIM-signed for `@mezin.eu`, where Gmail is neither), and this design makes it a one-command
  change — but it is a decision, not a mechanism, and not part of this work.

---

## 8. Invariants, and how to re-verify them

| Invariant | How to check |
|---|---|
| A cutover edits no secrets | the failover runbook's §3 contains no `gh secret set` |
| The probe follows the live vendor in host **and** credential | probe spec examples for both `MAIL_ROLE` values |
| `deploy.yml` is parsed identically by Kamal and the probe | neither reads a host from it any more; the map is the only source |
| The From address follows the credential | `.kamal/secrets` still derives `MAIL_FROM` from `SMTP_USERNAME` |
| No live credential is readable from a branch | the four `_DEPLOY_` secrets are environment-scoped |
| Every secret's purpose is discoverable | `docs/runbooks/smtp-credentials.md` lists all eight |
