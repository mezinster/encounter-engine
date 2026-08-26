# SMTP failover

For whoever is on call when the SMTP probe fails. Commands are copy-pasteable, but read §0 before
you act — a `degraded` verdict and a `down` verdict call for different responses, and this document
exists mainly to keep you from cutting over when you didn't need to.

**Rehearsed:** _not yet — fill in the date and what was verified the first time someone actually
walks §3, §4, and §5 end to end._

The three `SMTP_SPARE_*` secrets exist as of 2026-08-26. **That is not the same thing as
rehearsed.** A credential that authenticates is a configured spare; "rehearsed" means someone
actually cut over, sent a real message, and read its headers per §5 — do not let the secrets
existing read as that having happened.

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

The probe (`ops/smtp/probe.rb`) checks both endpoints every run — the primary (whatever
`SMTP_ADDRESS`/`SMTP_USERNAME`/`SMTP_PASSWORD` currently are) and the spare (whatever
`SMTP_SPARE_*` currently are), which the probe reads and the app never does. **Primary and spare
are roles, not fixed vendors** — before any cutover the primary is Gmail and the spare is Fastmail,
but §3 swaps them: cutting over sets the outgoing vendor (Gmail) as the *new* spare, not just a
retired credential nobody watches. Its verdict is one of three:

| Verdict | Means | Do |
|---|---|---|
| `ok` | Both endpoints authenticate. | Nothing. |
| `degraded` | The **primary is fine**; the **spare** doesn't authenticate. | **Fix the spare. Do not cut over** — the site is not affected, and cutting over would trade a working primary for a spare you just found out is broken. |
| `down` | The **primary** doesn't authenticate (or didn't respond at all). | **Cut over** — go to §3. |

The verdict and a human-readable summary are both in the filed issue's JSON. If you're unsure which
one you're looking at, re-run the probe (`gh workflow run smtp-probe.yml`, or trigger it from the
Actions tab) rather than guessing from a stale issue.

**A green six-hourly probe proves the Gmail *account* is healthy — it does not prove the exact
credential the app ships still works.** `.github/workflows/smtp-probe.yml` cannot read
`SMTP_USERNAME`/`SMTP_PASSWORD` — those exist only as `production` **environment** secrets, gated by
a required reviewer, and an unattended schedule cannot wait on one (four approval prompts a day,
forever). So the six-hourly run instead feeds the probe's primary slot from
`SMTP_PROBE_USERNAME`/`SMTP_PROBE_PASSWORD`: a dedicated app password on the *same* Gmail account,
stored as **repository** secrets specifically so the unattended schedule can read them. It still
catches what actually breaks in practice — account suspension, the daily-quota trip, Google blocking
the account, network/TLS breakage — but it is a different credential from the one running in
production, so it cannot see that credential specifically being rotated or revoked elsewhere.

`.github/workflows/deploy.yml` closes that one remaining gap instead, at the point where it's cheap
to close: its job already carries `environment: production`, so its final step,
**"Verify the shipped SMTP credential (the deploy itself already completed)"**, authenticates with
the real `SMTP_USERNAME`/`SMTP_PASSWORD` that were just shipped, with no extra approval needed. A
failure there means the shipped mail credential doesn't authenticate — not that the deploy itself
failed; the step name says so on purpose. See design spec §D10.

**`degraded` is not urgent, but it is real.** An unrehearsed fallback is not a fallback — it's a
hope, same as an untested backup. Fix the spare's credentials — rotate whichever vendor is
currently in the spare role's app password, and update the `SMTP_SPARE_USERNAME`/
`SMTP_SPARE_PASSWORD` GitHub secrets to match — then re-dispatch the probe to confirm.

---

## 3. Cut over (verdict is `down`)

Four things change, in this order. **Do not skip the `MAIL_FROM` reasoning below** — there is no
step for it because there is no second place to change it.

1. **Update the GitHub secrets the app itself reads.** Set `SMTP_USERNAME` and `SMTP_PASSWORD` to
   the Fastmail spare's credentials — the same ones already proven live by the probe's
   `SMTP_SPARE_USERNAME` / `SMTP_SPARE_PASSWORD`. GitHub secrets cannot be read back once set, so
   pull these values from wherever they're actually kept (password manager / secure note), not from
   GitHub. Use `gh secret set`, giving no `--body`, so it prompts on hidden input and the value
   never lands in your shell history:

   ```bash
   gh secret set SMTP_USERNAME
   gh secret set SMTP_PASSWORD
   ```

2. **Point `SMTP_SPARE_*` at the endpoint you're moving away from — Gmail — not at Fastmail
   again.** Skip this and the probe authenticates the same Fastmail credential twice under two
   different role labels: `degraded` becomes structurally unreachable (there is no longer a
   configured "spare" that can be found broken), which is exactly the alarm for "your fallback is
   broken" going silent for as long as you're relying on the fallback. It also means Gmail is no
   longer probed at all, so §4's "confirm with the probe before cutting back" instructs a check that
   can no longer be performed. Set these to the credentials that were *just* the primary's:

   ```bash
   gh secret set SMTP_SPARE_ADDRESS   # smtp.gmail.com
   gh secret set SMTP_SPARE_USERNAME  # the Gmail app username, just replaced above
   gh secret set SMTP_SPARE_PASSWORD  # the Gmail app password, just replaced above
   ```

3. **Change the one `SMTP_ADDRESS` line in `config/deploy.yml`** from `smtp.gmail.com` to
   `smtp.fastmail.com` (it's commented — the comment points back at this file). Commit it:

   ```bash
   git add config/deploy.yml
   git commit -m "Cut SMTP over to the Fastmail spare"
   ```

   `MAIL_FROM` needs **no edit of its own**. `.kamal/secrets` derives it from `SMTP_USERNAME`
   (`MAIL_FROM=${SMTP_USERNAME}`), specifically so the From address can't drift from the credential
   that's actually authenticating. Once step 1 lands, the From address becomes the new primary's
   `@mezin.eu` address automatically on the next deploy.

   That address change is safe to send from without touching DNS: `mezin.eu`'s SPF record is
   `v=spf1 include:spf.messagingengine.com ?all` — Fastmail, and only Fastmail — so a Fastmail
   sender is already SPF-aligned for `@mezin.eu`. Nothing to add, nothing to wait on propagating.

   This one line also retargets the probe. `.github/workflows/smtp-probe.yml` no longer carries its
   own copy of the host — it reads `env.clear.SMTP_ADDRESS` out of `config/deploy.yml` at the start
   of every run, so the six-hourly probe (and any manual dispatch) starts checking Fastmail the
   moment this commit lands, with no separate step to remember.

4. **Push and dispatch the deploy workflow.**

   ```bash
   git push
   gh workflow run deploy.yml -f command=deploy
   ```

---

## 4. Verify

1. Dispatch the probe:

   ```bash
   gh workflow run smtp-probe.yml
   ```

   It reads the primary host from `config/deploy.yml` at the start of the run (see §3 step 3), so
   it is already checking Fastmail as the primary — and Gmail as the spare, per step 2 — no separate
   address to update here.

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

Same four steps as §3, in reverse, once the primary (Gmail) is confirmed working again — don't cut
back on a hunch, confirm with the probe first:

1. `gh secret set SMTP_USERNAME` / `gh secret set SMTP_PASSWORD`, back to Gmail's values.
2. **Point `SMTP_SPARE_*` back at Fastmail** — the endpoint you're moving away from this time.
   Skipping this repeats the exact §3 step 2 mistake in the other direction: the probe would
   authenticate Gmail twice under two role labels, `degraded` would go silent again, and Fastmail —
   now the spare — would go unwatched.
   ```bash
   gh secret set SMTP_SPARE_ADDRESS   # smtp.fastmail.com
   gh secret set SMTP_SPARE_USERNAME  # the Fastmail credential, just retired from primary above
   gh secret set SMTP_SPARE_PASSWORD
   ```
3. `config/deploy.yml`'s `SMTP_ADDRESS` back to `smtp.gmail.com`, commit.
4. Push, `gh workflow run deploy.yml -f command=deploy`.

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
- **The six-hourly probe's own credential does not move with a cutover.** `SMTP_PROBE_USERNAME`/
  `SMTP_PROBE_PASSWORD` are a Gmail-specific app password (§2), but the probe's *primary* role
  always dials whatever `SMTP_ADDRESS` currently is — which §3 step 3 repoints to Fastmail on
  cutover. Nothing in §3 rotates the probe credential to match, so immediately after a real cutover
  the six-hourly probe would authenticate a Gmail credential against Fastmail's server and
  misreport `down`, even though the real credential (proven separately by the next deploy's
  verification step) is fine. Noticed while wiring up the two-credential arrangement above and
  recorded rather than silently worked around; a probe credential that follows the primary role
  across a cutover is unscoped follow-up work, not something this fix attempted.
