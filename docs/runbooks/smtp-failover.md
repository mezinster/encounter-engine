# SMTP failover

For whoever is on call when the SMTP probe fails. Commands are copy-pasteable, but read §0 before
you act — a `degraded` verdict and a `down` verdict call for different responses, and this document
exists mainly to keep you from cutting over when you didn't need to.

**Rehearsed:** _not yet — fill in the date and what was verified the first time someone actually
walks §3 and §4 end to end._

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
- **Password reset behaves identically either way**, deliberately — see §6.

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
`SMTP_ADDRESS`/`SMTP_USERNAME`/`SMTP_PASSWORD` currently are) and the warm spare, Fastmail, via its
own `SMTP_SPARE_*` GitHub secrets, which the probe reads and the app never does. Its verdict is one
of three:

| Verdict | Means | Do |
|---|---|---|
| `ok` | Both endpoints authenticate. | Nothing. |
| `degraded` | The **primary is fine**; the **spare** doesn't authenticate. | **Fix the spare. Do not cut over** — the site is not affected, and cutting over would trade a working primary for a spare you just found out is broken. |
| `down` | The **primary** doesn't authenticate (or didn't respond at all). | **Cut over** — go to §3. |

The verdict and a human-readable summary are both in the filed issue's JSON. If you're unsure which
one you're looking at, re-run the probe (`gh workflow run smtp-probe.yml`, or trigger it from the
Actions tab) rather than guessing from a stale issue.

**`degraded` is not urgent, but it is real.** An unrehearsed fallback is not a fallback — it's a
hope, same as an untested backup. Fix the spare's credentials (rotate the Fastmail app password,
update the `SMTP_SPARE_USERNAME`/`SMTP_SPARE_PASSWORD` GitHub secrets), then re-dispatch the probe
to confirm.

---

## 3. Cut over (verdict is `down`)

Three things change, in this order. **Do not skip the `MAIL_FROM` reasoning below** — there is no
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

2. **Change the one `SMTP_ADDRESS` line in `config/deploy.yml`** from `smtp.gmail.com` to
   `smtp.fastmail.com` (it's commented — the comment points back at this file). Commit it:

   ```bash
   git add config/deploy.yml
   git commit -m "Cut SMTP over to the Fastmail spare"
   ```

   `MAIL_FROM` needs **no edit of its own**. `.kamal/secrets` derives it from `SMTP_USERNAME`
   (`MAIL_FROM=${SMTP_USERNAME}`), specifically so the From address can't drift from the credential
   that's actually authenticating. Once step 1 lands, the From address becomes the spare's
   `@mezin.eu` address automatically on the next deploy.

   That address change is safe to send from without touching DNS: `mezin.eu`'s SPF record is
   `v=spf1 include:spf.messagingengine.com ?all` — Fastmail, and only Fastmail — so a Fastmail
   sender is already SPF-aligned for `@mezin.eu`. Nothing to add, nothing to wait on propagating.

   This one line also retargets the probe. `.github/workflows/smtp-probe.yml` no longer carries its
   own copy of the host — it reads `env.clear.SMTP_ADDRESS` out of `config/deploy.yml` at the start
   of every run, so the six-hourly probe (and any manual dispatch) starts checking Fastmail the
   moment this commit lands, with no separate step to remember.

3. **Push and dispatch the deploy workflow.**

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

   It reads the primary host from `config/deploy.yml` at the start of the run (see §3 step 2), so
   it is already checking Fastmail — no separate address to update here.

2. Register a throwaway account on the live site and confirm the welcome letter actually arrives
   (not just that the probe authenticates — the probe never sends anything, by design, so it can't
   prove an end-to-end send). Delete the throwaway account/team afterward if you want to keep the
   data clean; it isn't required for the check itself.

---

## 5. Cut back

Same three steps as §3, in reverse, once the primary (Gmail) is confirmed working again — don't cut
back on a hunch, confirm with the probe first:

1. `gh secret set SMTP_USERNAME` / `gh secret set SMTP_PASSWORD`, back to the primary's values.
2. `config/deploy.yml`'s `SMTP_ADDRESS` back to `smtp.gmail.com`, commit.
3. Push, `gh workflow run deploy.yml -f command=deploy`.

Then re-verify per §4 against the primary.

---

## 6. Why password reset looks unchanged either way

If you're debugging a report that "password reset silently did nothing," this isn't the SMTP outage
— it's working as designed. `PasswordResetsController` calls `MailDelivery.attempt` and **discards
the boolean on purpose**: the response is identical whether the mail sent, the mail failed, or the
address was never registered at all. Making the response depend on delivery success would let an
attacker learn whether an address has an account by watching for a "we couldn't email you" message —
an oracle. If you suspect the reset mailer itself is broken (not SMTP), check the logs for
`[mail] delivery failed:` lines correlated with reset requests; the controller's response won't tell
you either way.

---

## 7. What this does not cover

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
