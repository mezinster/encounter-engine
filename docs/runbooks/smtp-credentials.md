# SMTP credential inventory

For whoever needs to rotate an SMTP credential and isn't sure which one. This file exists because
the person who asked for it said, in effect, *"it would be difficult to rotate credentials if
necessary — I am already a bit lost on which is which."* Start at the table below, not at the
prose under it.

None of these eight secrets exist in GitHub yet as of this writing — they're created once, by hand,
when the endpoint-switcher branch ships. Everything here describes the target state.

---

## 1. The eight secrets

| Secret | Scope | Vendor | Purpose | Value lives in |
|---|---|---|---|---|
| `SMTP_GMAIL_DEPLOY_USERNAME` | `production` **environment** | Gmail | the app sends with this when Gmail is live | password manager |
| `SMTP_GMAIL_DEPLOY_PASSWORD` | `production` **environment** | Gmail | the app sends with this when Gmail is live | password manager |
| `SMTP_FASTMAIL_DEPLOY_USERNAME` | `production` **environment** | Fastmail | the app sends with this when Fastmail is live | password manager |
| `SMTP_FASTMAIL_DEPLOY_PASSWORD` | `production` **environment** | Fastmail | the app sends with this when Fastmail is live | password manager (same value as the probe password below — §3) |
| `SMTP_GMAIL_PROBE_USERNAME` | repository | Gmail | six-hourly monitoring only, never sends | password manager |
| `SMTP_GMAIL_PROBE_PASSWORD` | repository | Gmail | six-hourly monitoring only, never sends | password manager |
| `SMTP_FASTMAIL_PROBE_USERNAME` | repository | Fastmail | six-hourly monitoring only, never sends | password manager (same value as the deploy password above — §3) |
| `SMTP_FASTMAIL_PROBE_PASSWORD` | repository | Fastmail | six-hourly monitoring only, never sends | password manager (same value as the deploy password above — §3) |

That's the whole inventory. `vars.MAIL_ROLE` (a repository *variable*, not a secret — `gmail` or
`fastmail`) says which vendor is live; `ops/smtp/endpoints.yml`, committed, says each vendor's host
and port. Neither of those two holds a credential. The eight secrets above are the only place any
SMTP password lives in this project.

---

## 2. Rotate one

**Read this whole section before typing anything.** The four deploy commands and the four probe
commands are not the same shape, and the difference is not a style choice — see §4. Do not "clean
up" the probe commands by adding `--env production` to match the deploy ones, and do not drop it
from the deploy ones to match the probe ones. Both of those look tidy and both are wrong.

Every command below gives `gh` **no `--body`**, so the new value is prompted on hidden input and
never touches your shell history. Have the new value ready from your password manager before you
run the command — GitHub cannot show you the old one (§5).

### Deploy credentials — `--env production` required, on all four

```bash
gh secret set SMTP_GMAIL_DEPLOY_USERNAME    --env production
gh secret set SMTP_GMAIL_DEPLOY_PASSWORD    --env production
gh secret set SMTP_FASTMAIL_DEPLOY_USERNAME --env production
gh secret set SMTP_FASTMAIL_DEPLOY_PASSWORD --env production
```

### Probe credentials — no `--env` flag, on all four

```bash
gh secret set SMTP_GMAIL_PROBE_USERNAME
gh secret set SMTP_GMAIL_PROBE_PASSWORD
gh secret set SMTP_FASTMAIL_PROBE_USERNAME
gh secret set SMTP_FASTMAIL_PROBE_PASSWORD
```

**`--env production` is load-bearing, not decorative, on the deploy four.** Run
`gh secret set SMTP_GMAIL_DEPLOY_PASSWORD` without the flag and `gh` does not error — it silently
creates a *repository* secret of the same name instead. `.github/workflows/deploy.yml`'s job
declares `environment: production`, and GitHub resolves an environment secret ahead of a
repository one of the same name for that job. So the deploy keeps reading the *old* environment
secret, the new repository secret sits there unread, and nothing anywhere says so — no error, no
warning, a green deploy. The rotation looks done and changed nothing. This has already bitten this
repository once (`fix/smtp-runbook-env-scope`, see the git log).

The probe four are the mirror image: they genuinely are repository secrets, because
`.github/workflows/smtp-probe.yml` runs on a schedule with no `environment:` declared at all (see
§3 for why). Adding `--env production` to one of these would put the value where the unattended
probe job cannot read it, and the six-hourly run would start reporting `not configured` for that
vendor — a false alarm with a real cause.

**To check which shape a secret currently has:**

```bash
gh secret list --env production   # the four deploy secrets should be here
gh secret list                    # the four probe secrets should be here — and NONE of the deploy four
```

If a deploy secret's name shows up in the plain `gh secret list` output, someone ran it without
`--env production`. Delete the stray repository secret and re-run the command correctly.

---

## 3. You don't need to know which vendor is live to rotate

Under the previous scheme, the app read fixed names — `SMTP_USERNAME`/`SMTP_PASSWORD` for whichever
vendor was primary, `SMTP_SPARE_USERNAME`/`SMTP_SPARE_PASSWORD` for whichever was standing by. To
rotate Gmail's password you first had to answer "is Gmail primary or spare right now?", because the
answer decided which pair of secret names to edit. Guess wrong and the command still succeeded —
it just rotated the credential nothing was currently using, and the live one stayed exactly as
compromised or expired as before.

That question is gone. The secrets are named by **vendor**, not by role: `SMTP_GMAIL_DEPLOY_*` is
always Gmail's deploy credential, whether Gmail is currently live or currently idle. Rotating it is
always the same two commands, regardless of what `MAIL_ROLE` says today. You still may want to know
which vendor is live — to decide *whether* a rotation is urgent, say — but knowing it is no longer
a precondition for rotating correctly. See §6 for how to check.

---

## 4. Why Fastmail's two secrets share one value, and Gmail's don't

Gmail has two distinct app passwords: `SMTP_GMAIL_DEPLOY_*` and `SMTP_GMAIL_PROBE_*` are different
credentials on the same account, and revoking one doesn't touch the other.

Fastmail has one app password, used for both `SMTP_FASTMAIL_DEPLOY_*` and `SMTP_FASTMAIL_PROBE_*`.
This is deliberate, not an oversight: GitHub secrets are write-only (§5), so there is no way to
duplicate a value under a second name without re-typing it by hand at the vendor. Generating a
second Fastmail app password just to give the probe its own name was judged not worth the trip to
Fastmail's settings at the time this scheme was built, so the existing single-credential posture
(carried over from the old `SMTP_SPARE_*` setup) continued rather than being treated as a new risk.

The cost: revoking or rotating Fastmail's app password takes down sending **and** monitoring
together. If Fastmail is ever compromised, you lose the probe's visibility into Fastmail at the
same moment you lose the ability to send through it — there's no independent alarm left ringing.
This is worth fixing the next time anyone is in Fastmail's account settings for another reason:
generate a second app password, split `SMTP_FASTMAIL_DEPLOY_*` and `SMTP_FASTMAIL_PROBE_*` onto
separate credentials, and update this table.

---

## 5. GitHub secrets are write-only — the password manager is the source of truth

There is no `gh` command and no API call that reads a secret's value back out of GitHub, for any
of the eight. `GITHUB_TOKEN` cannot write secrets either, so nothing running in a workflow can copy
one for you. Practically, that means:

- You cannot audit a secret's current value against what you think it is. You can only overwrite it.
- You cannot rename a secret. "Renaming" is: set the new name, confirm the app works, delete the old
  name — never a copy.
- **If a value exists only in GitHub, it is gone the moment you need it for anything else** —
  debugging locally, generating a second app password with the same base name, migrating to a new
  secret name. There is no recovery path.

So every value in the table in §1 must also live in a password manager, in full, before or at the
moment it's set in GitHub. Treat GitHub's copy as write-only storage the app and workflows consume
from, not as a record of what the credential is. This is exactly why the migration onto this eight-
secret scheme requires the owner to still hold all four current values by hand — nothing can pull
them back out of the old secrets to seed the new ones.

---

## 6. Which vendor is live right now

```bash
gh variable get MAIL_ROLE
```

Two other places say the same thing without you having to run anything:

- The **last green run of `smtp-probe.yml`** — its verdict JSON labels each endpoint `primary` or
  `spare` and names the vendor behind each role (`primary: fastmail`, for example), so you don't
  have to infer which vendor "primary" meant that week.
- The **step summary of the last successful `deploy.yml` run** — its "Resolve which SMTP vendor to
  ship" and "Verify the shipped SMTP credential" steps both log the vendor they resolved and
  shipped.

If those disagree with each other, trust the deploy — it's the one that actually shipped a
credential to production, not just checked one.

---

See `docs/runbooks/smtp-failover.md` for what to do when the probe reports `degraded` or `down`;
this file is only about the secrets themselves.
