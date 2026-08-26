# SMTP failover

For whoever is on call when the SMTP probe fails. Commands are copy-pasteable, but read §0 before
you act — a `degraded` verdict and a `down` verdict call for different responses, and this document
exists mainly to keep you from cutting over when you didn't need to.

**Rehearsed:** **2026-08-26 — not a rehearsal, a real cutover.** Gmail → Fastmail, in production, ten
minutes after the switcher merged. `gh variable set MAIL_ROLE --body fastmail` and a deploy: no secret
edits, no `config/deploy.yml` change, no commit. The deploy's own verification step authenticated the
shipped Fastmail credential, and the next probe reported
`ok — all configured SMTP endpoints authenticate (primary: fastmail, spare: gmail)`, following the
cutover in **both** host and credential with no human step. Production has sent as `@mezin.eu` since.

What that leaves unproven: cutting **back** (the same two commands with `gmail`, never run), and §5's
header checks — nobody has yet read the `From:`, SPF and DKIM headers of a message that actually
arrived. The credential works; what a recipient sees is still inferred rather than observed.

`docs/runbooks/smtp-credentials.md` §1 lists the eight vendor-named secrets a cutover depends on.
**Those secrets existing is not the same thing as rehearsed.** A credential that authenticates is
a configured standby; "rehearsed" means someone actually cut over, sent a real message, and read
its headers per §5 — do not let the secrets existing read as that having happened.

---

## 0. What changed, and why the urgency is lower than it used to be

Before this branch (2026-08-25, "SMTP outage resilience"), an SMTP failure was an unhandled
exception in the request that was sending mail. A signup during a Gmail outage lost the user's row,
their session, and the only copy of a generated password, all at once — see
`app/services/mail_delivery.rb`'s header comment for the mechanics.

That is no longer true. `MailDelivery.attempt` catches SMTP *transport* failures at every send site,
and the app now degrades instead of breaking:

- **Signup still succeeds.** If the welcome letter can't be sent, the success page shows the
  generated password on screen once, instead of losing it.
- **Invitations still succeed.** If a notification can't be sent, the acting captain sees a flash
  warning that it didn't go out, but the invitation itself is still created/accepted.
- **Password reset behaves identically either way**, deliberately — see §7.

So: **an SMTP outage is no longer a site-down emergency.** It's a "some people aren't getting email"
degradation. That changes how fast you need to move, not whether you need to fix it.

---

## 1. Symptoms

Any of:

- A GitHub issue labelled `smtp`, titled `SMTP probe: <verdict> -- <summary>`, filed automatically
  by `.github/workflows/smtp-probe.yml` (runs every 6 hours, plus manual dispatch). The issue body
  has the full JSON verdict and a copy of the two paragraphs below.
- `[mail] delivery failed: <ErrorClass>: <redacted message>` lines in `docker logs` on the
  production host — this is `MailDelivery.attempt`'s own log line, emitted every time a
  `deliver_now` call rescues a transport error.
- A user or team captain reporting that a welcome letter or an invitation notification never
  arrived. Because of §0, this is now the *quiet* symptom — nothing broke, so nobody necessarily
  reports it, which is exactly why the probe exists instead of relying on complaints.

---

## 2. Decide: `degraded` or `down`?

The probe (`ops/smtp/probe.rb`) checks both endpoints every run: the **live** vendor (whichever
`MAIL_ROLE` names) and the **standby** (the other vendor in `ops/smtp/endpoints.yml`). Both are
resolved by `ops/smtp/roles.rb` — the same resolver `.github/workflows/deploy.yml` calls — so the
probe and the deploy cannot disagree about which vendor is which. **Primary and spare are roles,
not fixed vendors**, and a cutover doesn't need to *make* that true any more: because both roles
are always defined as "whatever `MAIL_ROLE` says" and "the other one," flipping the variable in §3
is the whole swap. There is no secret to rewrite and nothing to forget. Its verdict is one of
three:

| Verdict | Means | Do |
|---|---|---|
| `ok` | Both endpoints authenticate. | Nothing. |
| `degraded` | The **primary is fine**; the **spare** doesn't authenticate. | **Fix the spare. Do not cut over** — the site is not affected, and cutting over would trade a working primary for a spare you just found out is broken. If you cut over recently, confirm the deploy actually went green first — see **"Before you trust the probe: confirm the deploy actually shipped"** below; a failed deploy makes this verdict mean the opposite. |
| `down` | The **primary** doesn't authenticate (or didn't respond at all). | **Cut over** — go to §3. |

The verdict and a human-readable summary are both in the filed issue's JSON. If you're unsure which
one you're looking at, re-run the probe (`gh workflow run smtp-probe.yml`, or trigger it from the
Actions tab) rather than guessing from a stale issue.

**A green six-hourly probe proves the *account* is healthy — it does not always prove the exact
credential the app ships still works.** `.github/workflows/smtp-probe.yml` cannot read the
`SMTP_<VENDOR>_DEPLOY_*` secrets — those live in the `production` **environment**, gated by a
required reviewer, and an unattended schedule cannot wait on one (four approval prompts a day,
forever). So the six-hourly run instead authenticates with `SMTP_<VENDOR>_PROBE_*`: repository
secrets, one pair per vendor, specifically so the unattended schedule can read them. Whether that
is a *different* credential from the one shipped depends on the vendor — see
`docs/runbooks/smtp-credentials.md` §4 for which vendor's probe pair is a dedicated password and
which shares its value with deploy.

`.github/workflows/deploy.yml` closes that gap for the live vendor at the point where it's cheap to
close: its job already carries `environment: production`, so its final step,
**"Verify the shipped SMTP credential (the deploy itself already completed)"**, authenticates with
the real `SMTP_<VENDOR>_DEPLOY_*` credential that was just shipped, with no extra approval needed. A
failure there means the shipped mail credential doesn't authenticate — not that the deploy itself
failed; the step name says so on purpose. See design spec §D10.

**`degraded` is not urgent, but it is real.** An unrehearsed fallback is not a fallback — it's a
hope, same as an untested backup. Rotate the standby vendor's probe credential per
`docs/runbooks/smtp-credentials.md` §2, then re-dispatch the probe to confirm.

---

## 3. Cut over (verdict is `down`)

```bash
gh variable set MAIL_ROLE --body fastmail
gh workflow run deploy.yml -f command=deploy
```

That's the whole cutover. `MAIL_ROLE` is a repository **variable**, not a secret — it names the
live vendor. `.github/workflows/deploy.yml` resolves it through `ops/smtp/roles.rb` and
`ops/smtp/endpoints.yml` into a host, a port, and the matching `SMTP_FASTMAIL_DEPLOY_USERNAME` /
`SMTP_FASTMAIL_DEPLOY_PASSWORD` secret pair, and ships them. `MAIL_FROM` needs no edit of its own —
`.kamal/secrets` still derives it from `SMTP_USERNAME` (`MAIL_FROM=${SMTP_USERNAME}`), so the From
address follows whichever credential is actually authenticating.

That address change is safe to send from without touching DNS: `mezin.eu`'s SPF record is
`v=spf1 include:spf.messagingengine.com ?all` — Fastmail, and only Fastmail — so a Fastmail sender
is already SPF-aligned for `@mezin.eu`. Nothing to add, nothing to wait on propagating.

**There is nothing to set in GitHub secrets, and that is the design, not an omission.** This
runbook used to have seven `gh secret set` calls here, a `config/deploy.yml` edit and a commit,
because secrets were named by **role**: `SMTP_USERNAME` meant "whoever is primary right now",
`SMTP_SPARE_*` meant "whoever isn't" — so a cutover had to rewrite which vendor each name pointed
at, by hand, or the deploy kept shipping the old vendor while the probe silently watched the wrong
pair. Secrets are now named by **vendor** — `SMTP_GMAIL_DEPLOY_*`, `SMTP_FASTMAIL_DEPLOY_*`, and
their `_PROBE_` counterparts — so "whoever is not primary" is no longer a value any secret has to
hold, and nothing needs rewriting when the roles swap. `.github/workflows/smtp-probe.yml` resolves
the same `MAIL_ROLE` through the same `ops/smtp/roles.rb`, so the six-hourly probe follows this
cutover on its very next run with no separate step — see §4.

Rotating, creating or auditing any of the eight underlying credentials — including which four need
`--env production` and which four must never have it — is `docs/runbooks/smtp-credentials.md`, not
this file. This runbook is only about *which vendor is live*; that file is about the secrets
themselves.

Then go verify: **"Before you trust the probe: confirm the deploy actually shipped"** below, then §4, then §5.

---

## Before you trust the probe: confirm the deploy actually shipped

If the deploy dispatched in §3 **fails** -- the NSG/`az` flakiness both retry loops in
`deploy.yml` exist for is real and observed -- `MAIL_ROLE` is now ahead of production: the
variable names the new vendor, but the container never picked it up, and the old vendor is still
what's actually sending. The next scheduled probe run resolves `primary: <the new vendor>`,
authenticates it fine, and finds the OLD vendor -- the one actually serving production, and quite
possibly the one that was down -- failing to authenticate. That reports **`degraded`**, and §2's
table for `degraded` says *"the site is not affected... do not cut over."* During an outage, that
is the exact opposite of true.

**Before reading anything the probe says right after a cutover, confirm the deploy run itself
finished green:**

```bash
gh run list --workflow deploy.yml --limit 1
```

If it did not succeed, the cutover has not actually happened yet. Re-dispatch the deploy (or fix
whatever made it fail) before treating any probe verdict -- `ok`, `degraded`, or `down` -- as a
description of what production is doing. Once that run shows `success`, the probe's verdict can be
trusted again.

This is not a new failure mode this design created: the same window existed when the host lived in
`config/deploy.yml` on `master`, between the commit and the deploy. What changed is the width of
the window -- one command wide instead of a commit, push and merge -- not its existence. See
design spec §6.

---

## 4. Verify

1. Dispatch the probe:

   ```bash
   gh workflow run smtp-probe.yml
   ```

   It resolves `MAIL_ROLE` through the same `ops/smtp/roles.rb` the deploy in §3 just used, so it
   is already checking Fastmail as the primary — and Gmail as the spare — with no separate address
   or credential to update here.

2. Register a throwaway account on the live site and confirm the welcome letter actually arrives
   (not just that the probe authenticates — the probe never sends anything, by design, so it can't
   prove an end-to-end send). Delete the throwaway account/team afterward if you want to keep the
   data clean; it isn't required for the check itself.

   Don't stop at "it arrived." Go to §5 and read the headers — that's the only part of this that
   actually looks at what the recipient got.

---

## 5. Read the headers — the probe can't see this

`ops/smtp/probe.rb` authenticates and quits. It **never sends a message**, so a green probe proves
the *credential* and nothing about the *envelope*. All of the following produce a green probe and
a broken cutover:

- `MAIL_FROM` failing to recompose, so `From:` still names the old credential
- the relay silently rewriting `From:` (Gmail does this for any non-verified alias)
- SPF or DKIM failing, so mail delivers today and spam-folders next week
- the letter landing in Junk instead of the inbox

The throwaway account from §4 step 2 is what this section checks. If you haven't registered one
yet, do that first.

**Step 1 — make a real message go out.** Register the throwaway account (§4 step 2 covers this)
with `<an address you control and can read now>` — not a personal address committed to this file;
substitute your own. The maintainer's usual choice is their own `@mezin.eu` mailbox. Registration
exercises the welcome letter through the real send path, the same one every signup uses.

**Step 2 — open the full headers of what arrived** ("Show original" / "View source" in most
clients) and check these, in this order:

| Header | Expect | What it proves / what a bad value means |
|---|---|---|
| `From:` | the new primary's `SMTP_USERNAME` | The `MAIL_FROM` derivation in `.kamal/secrets` held **and** the relay did not rewrite it. A stale address here means the deploy step did not actually recompose the env — the secret changed but the container did not. |
| `Return-Path:` | the authenticating account | This is the envelope sender, and it is what SPF is evaluated against — not `From:`. Worth reading separately because the two can differ. |
| `Authentication-Results:` → `spf=` | `pass` | `mezin.eu` publishes `v=spf1 include:spf.messagingengine.com ?all`, so Fastmail is authorised and Gmail is not. Sending as `@mezin.eu` through Gmail would fail here. |
| `Authentication-Results:` → `dkim=` | `pass` | Verified 2026-08-26: all three Fastmail selectors are live (`fm1`/`fm2`/`fm3._domainkey.mezin.eu` → `dkim.fmhosted.com`). So a Fastmail-sent `@mezin.eu` message is signed. |
| `Authentication-Results:` → `dmarc=` | `none` — **and that is expected** | `mezin.eu` publishes **no** DMARC policy. `_dmarc.mezin.eu` appears to answer only because the domain serves a **wildcard TXT** record — verified: a random subdomain returns the same string. There is no `v=DMARC1`. Do not chase this during an incident; it is a known gap recorded in §8 of the design. |
| Delivery folder | Inbox, not Junk | The whole point. This app forms teams by emailed invitation, so spam-foldering is a silent failure. |
| Links in the body | `game.mezin.eu` | Built from `APP_HOST` via `default_url_options`, which a cutover does **not** change. A glance costs nothing and catches a mis-set env. |

**Step 3 — when a check fails:**

- **`From:` still shows the old account** → the deploy did not recompose `MAIL_FROM`. It is derived
  in `.kamal/secrets` as `MAIL_FROM=${SMTP_USERNAME}` at deploy time, not at secret-set time, so
  changing the GitHub secret alone changes nothing running. Re-run the deploy.
- **`spf=fail` or `spf=softfail`** → the From domain and the sending relay disagree. Check that the
  new `SMTP_USERNAME` is an address on a domain whose SPF authorises the vendor now doing the
  sending.

**A green probe does not substitute for any of this.** It's the same blind spot §8 (What this does
not cover) already records for per-recipient rejections: the probe never sends, so it cannot see
anything about what a recipient actually receives. Delete the throwaway account/team once you're
done with it if you want to keep the data clean; it isn't required for the check itself.

---

## 6. Cut back

Same command as §3, with `gmail`, once the primary (Gmail) is confirmed working again — don't cut
back on a hunch, confirm with the probe first:

```bash
gh variable set MAIL_ROLE --body gmail
gh workflow run deploy.yml -f command=deploy
```

No secrets to set here either, for the same reason as §3: `SMTP_GMAIL_DEPLOY_*` and
`SMTP_FASTMAIL_DEPLOY_*` are always Gmail's and Fastmail's credentials respectively, regardless of
which one `MAIL_ROLE` currently names, so cutting back needs no rotation, no `SMTP_ADDRESS` edit
and no commit — only the variable and a deploy.

Then re-verify per §4 and §5 against the primary — the same envelope surprises (a stale `From:`,
an SPF mismatch, a spam-foldered letter) apply in this direction too, not just on the way out.

---

## 7. Why password reset looks unchanged either way

If you're debugging a report that "password reset silently did nothing," this isn't the SMTP outage
— it's working as designed. `PasswordResetsController` calls `MailDelivery.attempt` and **discards
the boolean on purpose**: the response is identical whether the mail sent, the mail failed, or the
address was never registered at all. Making the response depend on delivery success would let an
attacker learn whether an address has an account by watching for a "we couldn't email you" message —
an oracle. If you suspect the reset mailer itself is broken (not SMTP), check the logs for
`[mail] delivery failed:` lines correlated with reset requests; the controller's response won't tell
you either way.

---

## 8. What this does not cover

The probe authenticates and quits — it **never sends a message**, deliberately, so as not to spend
sending reputation proving sending reputation works. That means it cannot see, and this runbook does
not help with:

- **A per-recipient rejection** (e.g. `550 5.1.1 ... User unknown`, or a full mailbox, or a
  recipient's server greylisting a specific message). Those only happen on a real send, to a real
  address, and only `MailDelivery`'s own logs — on the production host, per the redacted
  `[mail] delivery failed:` line — can show you one. A single user not receiving mail while the
  probe is green is very likely this, not an outage; there is nothing to cut over for.
- **Deliverability problems that aren't authentication failures** — spam-foldering, DKIM/DMARC
  alignment issues, reputation damage from a previous incident. The probe proves the credential
  still authenticates, not that the mail that goes out is actually read.
- **The probe's credential used to need a manual rotation step on every cutover. It no longer
  does.** `.github/workflows/smtp-probe.yml` resolves `MAIL_ROLE` through the same
  `ops/smtp/roles.rb` the deploy uses, and authenticates each vendor with that vendor's own
  `SMTP_<VENDOR>_PROBE_*` secret — so the probe already holds the right credential for both the
  live and the standby vendor before either one is ever live, and §3/§6 have no rotation step for
  it to skip. One asymmetry is still worth knowing, because it isn't visible from this file: **for
  Fastmail, the `_DEPLOY_` and `_PROBE_` secrets are the same app password**, so revoking it stops
  sending and monitoring together; Gmail's two credentials are independent, so revoking one leaves
  the other watching. See `docs/runbooks/smtp-credentials.md` §4 for why, and for what fixing it
  would take.
