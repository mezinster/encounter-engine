# SMTP outage resilience

**Status:** design, approved 2026-08-25.
**Scope:** make mail failure non-destructive, break signup's dependency on a letter that may never
arrive, detect a dead credential before a user does, and keep a continuously-proven spare sender.
Explicitly **not** a migration off Gmail, and **not** a move to background delivery — see §8.

---

## 0. The gap

Every mail this app sends goes out with `deliver_now`, inside the request, on one Puma process.
`config.action_mailer.raise_delivery_errors` is never set, so it is Rails' default `true`. There is
no queue to absorb a failure: `config.active_job.queue_adapter = :inline`
(`config/environments/production.rb:80`) means even `deliver_later` would be synchronous.

So an SMTP failure is an **exception in a controller**, at six call sites:

| File | Line | Mail |
|---|---|---|
| `app/controllers/users_controller.rb` | 165 | welcome letter (signup) |
| `app/controllers/password_resets_controller.rb` | 29 | password reset |
| `app/controllers/invitations_controller.rb` | 21 | invitation |
| `app/controllers/invitations_controller.rb` | 37 | accept notification |
| `app/controllers/invitations_controller.rb` | 47 | reject notification |
| `app/controllers/invitations_controller.rb` | 76 | auto-reject notifications |

The credential is a single Gmail account (`config/deploy.yml:70-76`,
`smtp.gmail.com:587`). Any of: a revoked app password, an account suspended on spam heuristics, or
the free-tier daily recipient cap tripping mid-onboarding, produces the same result.

### 0.1 Why signup is the severe case

`UsersController#create` (lines 74-80) runs `@user.save`, then `authenticate_user`, then
`send_welcome_letter_to`. With SMTP down the third step raises, and the outcome is an
**unrecoverable orphan account**:

* The `users` row is committed. `user.rb:46-48` makes both nickname and email unique, so the person
  cannot register again — they get "already taken".
* The session cookie is never sent. Verified from `bin/rails middleware`:
  `ActionDispatch::ShowExceptions` sits at position **10**, `ActionDispatch::Session::CookieStore`
  at **16**. The exception unwinds past the session middleware, which therefore never commits, and
  `ShowExceptions` builds a fresh response with no `Set-Cookie`. The user is not logged in.
* The password was generated server-side (`SecureRandom.alphanumeric(12)`, line 70) and exists
  **only inside the letter that failed to send**. Nobody knows it — not the user, not the operator.
* Password reset cannot help: `password_resets_controller.rb:29` needs the same dead SMTP.
* The admin console cannot help: `app/controllers/admin/users_controller.rb` deliberately never
  touches passwords.

Recovery is `rails console` on the VM, per account. The user sees a 500 and tries again, hitting
"email already taken".

A quieter variant exists even when SMTP works but the letter is spam-foldered: the user is logged
in but can never change their password, because `users_controller.rb:88-96` requires the current
one — which they never learned. Logged in permanently, until the session ends.

### 0.2 The invitation case

`InvitationsController#accept` adds the member and deletes the invitation, *then* mails (line 37).
An exception there commits the join, skips `reject_rest_of_invitations` (line 39), notifies nobody,
and shows a 500. The join succeeded and looks like it failed.

### 0.3 What is not wrong

The `mail` gem's defaults are `open_timeout: 5, read_timeout: 5`
(`mail-2.9.1/lib/mail/network/delivery_methods/smtp.rb:99-100`), so a blackholed connection holds a
Puma thread for seconds, not the 30/60s Ruby's `Net::SMTP` would default to. The failure is 500s,
not a wedged server. No timeout tuning is needed.

---

## 1. Decisions

### D1 — a `MailDelivery.attempt { ... }` seam, not `raise_delivery_errors = false`

Setting `raise_delivery_errors = false` in production is one line and would stop the 500s. It is
rejected because it is **silent and global**: the caller learns nothing, so the signup page cannot
know to show the password (D2) and the invitation flash cannot know to reword itself (D3). It also
suppresses failures in the one environment where suppression is most dangerous.

Overriding delivery inside `NotificationMailer` was also rejected: callers still need the outcome,
so they change anyway, and it entangles "which errors are survivable" with "how mail is composed".

`MailDelivery.attempt { ... } # => true | false` puts the rescue policy in one place and makes each
call site state what it does about failure.

### D2 — the rescue list is narrow, and that is the point

`MailDelivery` rescues **transport failures only**:

```
Net::SMTPError            # a MODULE, see below
Net::OpenTimeout          # < Timeout::Error, NOT IOError
Net::ReadTimeout
SocketError
OpenSSL::SSL::SSLError
Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::ENETUNREACH
EOFError                  # < IOError, see below -- a clean FIN, not an RST
Errno::EPIPE
```

Three non-obvious facts, all verified rather than assumed:

* **`Net::SMTPError` is a module, not a class.** It is mixed into five error classes with five
  different superclasses (`Net::SMTPAuthenticationError < Net::ProtoAuthError`,
  `Net::SMTPServerBusy < Net::ProtoServerError`, `Net::SMTPSyntaxError < Net::ProtoSyntaxError`,
  `Net::SMTPFatalError < Net::ProtoFatalError`, `Net::SMTPUnknownError < Net::ProtoUnknownError`).
  There is no common ancestor class. `rescue Net::SMTPError` works only because Ruby's `rescue`
  dispatches on `Module#===`.
* **`Net::OpenTimeout` descends from `Timeout::Error`, not `IOError`.** A rescue list assembled by
  reasoning about the hierarchy would omit the single most likely failure — a connection that is
  dropped rather than refused.
* **`EOFError` and `Errno::EPIPE` cover the peer closing the connection outright, and
  `Errno::ECONNRESET` above does not reach either.** `ECONNRESET` fires only for an RST — an abrupt,
  abnormal teardown. A clean FIN — a greylisting relay, an over-quota Gmail dropping the session
  right after its 220 greeting, a load balancer reaping an idle connection — is the far more common
  shape of "the other end hung up", and it surfaces to `net/protocol.rb` as a bare `EOFError` on
  read, or `Errno::EPIPE` if this process is still writing when the peer is already gone. Neither is
  an `ECONNRESET`. Reproduced against a real socket (server greets 220 then closes; server accepts
  then closes) — both raised `EOFError`, uncaught, before these two entries were added. Note that
  `EOFError < IOError`: §D9 aside, this is exactly why the rescue list names `EOFError` and not the
  broader `IOError` — see the class comment in `app/services/mail_delivery.rb` and the "everything
  else" spec in `spec/services/mail_delivery_spec.rb` for why `IOError` itself must keep raising
  (`net/smtp` raises it for "SMTP session already started" and similar programming errors, which
  are bugs, not transport failures).

`StandardError` is **not** rescued. A template bug or an `I18n::MissingTranslationData` must keep
raising loudly; swallowing those would trade a visible outage for an invisible one — the same
mistake as `skip`-instead-of-`raise`, which this repository has already made twice (see the
`shared.countdown.*` and `spec/layout` notes in `CLAUDE.md`).

### D3 — the signup failure page shows the password once

On failure the account and session are kept, and `users/welcome_password` renders with the
generated password, an explanation that it could not be emailed, and advice to change it.

The alternatives and why they lost:

* **Roll back the account.** Guarantees "every account's password was delivered", but nobody can
  register at all while SMTP is down — unacceptable on a game day for an app whose whole activity
  is time-boxed — and a transient blip costs a legitimate registration.
* **Waive the current-password check for a never-changed password.** Adds user state to get right
  and silently weakens the CWE-620 fix of 2026-08-07.
* **Set-password-by-token.** Architecturally the cleanest, and it deletes this whole class of
  problem. Rejected *for now* only because it stops logging the user in at signup, breaking two
  assertions in a frozen feature file (§2) and requiring a fourth owner amendment. Recorded in §8
  as the right long-term shape.

The response carries `Cache-Control: no-store`, because the body contains a live credential.

### D4 — password reset discards the boolean, deliberately

`PasswordResetsController#create` sends **only inside `if user`** (lines 28-30). An SMTP exception
there therefore fires *only when the address is registered*. Any failure message distinct from the
success message would re-create precisely the address oracle that controller's identical-response
design exists to prevent (see its own comment at lines 20-24, and `sessions_controller.rb:24`).

So: rescue, log, and return the same `password_resets.create.sent` notice either way. The discarded
return value gets a comment saying why, because a future reader will find it and reasonably want to
"fix" it.

### D5 — invitations tell the actor, because there is no oracle to protect

Unlike password reset, the recipient of an invitation notification is already known to the person
acting. A captain who is told "invitation created, but we couldn't email them" can chase the player
another way; silence means waiting for a reply that will never come.

`InvitationsController#accept` performs **two** mail operations: its own `accept_notification`
(line 37) and the `reject_rest_of_invitations` loop (line 76), which notifies every *other* captain.
Either or both may fail. `invitations.accept_unnotified` covers both cases and is shown once —
failures in the loop are collected and reported as **one** flash, never N, and the loop always runs
to completion regardless of individual failures.

### D6 — no in-code failover; the spare is config

The app never knows a spare exists. `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME` and `SMTP_PASSWORD`
are already environment-driven, so cutover is a secrets change plus a one-line `config/deploy.yml`
edit plus a deploy dispatch. Automatic failover would double the credential surface inside the app
and turn a partial failure into duplicate sends.

### D7 — the probe authenticates, and probes the spare too

`ops/smtp/probe.rb` connects, STARTTLS, **authenticates, and quits without sending**. No test mail
to a real address, ever — that damages the sending reputation the whole design exists to protect.

It probes **both** the primary and the spare on every run. An idle spare that nobody exercises is
not a spare; it is a hope. This is the same failure the offsite archive is currently in — live but
unrehearsed — and it is cheap to avoid here.

AUTH rather than connect-only is a deliberate risk trade: authenticating four times a day from
GitHub's rotating runner IPs is itself mildly provocative to Gmail, but a **revoked app password is
the failure we are hunting**, and only AUTH detects it. Cadence is therefore every 6 hours, not
every 15 minutes.

### D8 — Fastmail is the spare

Verified live on 2026-08-25, not taken from the comment in `.kamal/secrets`:

```
$ dig +short TXT mezin.eu
"v=spf1 include:spf.messagingengine.com ?all"
$ dig +short MX mezin.eu
10 in1-smtp.messagingengine.com.
20 in2-smtp.messagingengine.com.
```

Fastmail is the domain's MX and the only sender its SPF authorises. So a Fastmail spare is
SPF-aligned for `@mezin.eu` with **zero DNS change**, and a Google-side suspension cannot touch it.

Azure Communication Services was considered and deferred: it speaks plain SMTP
(`smtp.azurecomm.net:587`, STARTTLS) and would drop into the existing `smtp_settings` unchanged, at
$0.00025/message, but it needs domain verification, SPF/DKIM edits, an Entra app registration, and
a **client secret that expires** — which converts "Google blocked us" into "the secret quietly
expired on a Tuesday". It also shares a blast radius with the VM's own cloud account.

### D9 — addresses are redacted, not truncated (a correction to this document)

**This design was wrong when first written, and the error is recorded rather than quietly patched,
because the wrong version is the instructive one.** D2 and §5 originally said that truncating an
exception message to `MESSAGE_LIMIT` kept recipient addresses out of the log. It does not. A real
rejection —

```
550 5.1.1 <ivan@example.com>: Recipient address rejected: User unknown
```

— is about 70 characters, so a 200-character cap removes nothing whatsoever. The comment asserted a
mitigation that never mitigated, and a background security review caught it after Task 1 had already
shipped. That is the exact failure this repository documents everywhere else: *a documented claim
that reads as protection while protecting nothing.* Truncation bounds a log line's **length**; only
redaction protects the **address**.

Both layers are kept. `MailDelivery.redact` substitutes address-shaped substrings before truncating,
and the SMTP code and reason text — the entire diagnostic value of the line — survive intact.

**The same flaw was worse in the probe, and was fixed before implementation.** `ops/smtp/probe.rb`
put a truncated error message into its verdict JSON, and `.github/workflows/smtp-probe.yml` embeds
that JSON verbatim in a GitHub issue body. `mezinster/encounter-engine` is **public** (`gh repo view`
confirms it), so an auth failure whose message echoed the authenticating address would have published
it to the open internet rather than to a private container log. The probe redacts with its own copy
of the pattern: it runs on a bare CI runner and must never require Rails, so sharing the constant
with `MailDelivery` is not available and duplication is correct here.

---

## 2. The frozen feature files are untouched

`features/signup/signup.feature`, scenario `Удачная регистрация`, asserts three things: redirect to
the dashboard, the user is visible (logged in), and **exactly one letter** is sent.

`config/environments/test.rb:8` sets `delivery_method = :test`, which never raises. So
`MailDelivery.attempt` always returns `true` under Cucumber, the `else` branch of D3 is unreachable
from the acceptance suite, and all three assertions hold unchanged.

**No amendment is requested.** This is to be *verified*, not asserted, using the inherited-contract
command in `CLAUDE.md` (expected: 228 scenarios / 2325 steps).

---

## 3. Files

**New**

| Path | Purpose |
|---|---|
| `app/services/mail_delivery.rb` | `MailDelivery.attempt` — the rescue seam |
| `app/views/users/welcome_password.html.erb` | signup failure page (D3) |
| `ops/smtp/probe.rb` | SMTP handshake probe + pure `classify` |
| `.github/workflows/smtp-probe.yml` | 6-hourly schedule + `workflow_dispatch` |
| `docs/runbooks/smtp-failover.md` | cutover procedure |
| `spec/services/mail_delivery_spec.rb` | rescue-list pinning |
| `spec/ops/smtp_probe_spec.rb` | `classify` from fixtures, `spec_helper` |
| `spec/requests/mail_failure_spec.rb` | the five request-level examples in §5 |

**Modified**

| Path | Change |
|---|---|
| `app/controllers/users_controller.rb` | branch on delivery outcome (D3) |
| `app/controllers/invitations_controller.rb` | four sites, flash on failure (D5) |
| `app/controllers/password_resets_controller.rb` | rescue, discard, comment (D4) |
| `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` | 8 new keys each |
| `config/deploy.yml` | comment pointing at the failover runbook |
| `CLAUDE.md` | mail-failure policy; recounted i18n leaf total |

`MailDelivery` is **top-level, not `Mail::Delivery`**. The `mail` gem owns `::Mail`; a file at
`app/services/mail/delivery.rb` would have Zeitwerk reopen the gem's module. `bin/rails
zeitwerk:check` is part of the gate for this reason.

---

## 4. New i18n keys

Eight keys, in **all seven** locale files:

```
users.create.mail_failed.title
users.create.mail_failed.explanation
users.create.mail_failed.password_label
users.create.mail_failed.change_hint
users.create.mail_failed.continue
invitations.notice_sent_unnotified      # interpolates %{nickname}
invitations.accept_unnotified
invitations.reject_unnotified
```

Two `CLAUDE.md` rules apply directly:

* **Turkish must not inflect around the placeholder.** `notice_sent_unnotified` carries a
  user-authored `%{nickname}`, so the Turkish string puts the case suffix on a common noun —
  `«%{nickname}» adlı oyuncu` — and is checked by rendering with both a consonant-final and a
  vowel-final name.
* **The leaf count is recounted, never derived.** That entry has gone stale six times. Run the
  script in `CLAUDE.md` after the keys land and write down what it prints.

These are flashes and page copy, not validation messages, so the
`activerecord.attributes` + `activerecord.errors.models` noun/predicate pairing does not apply.

---

## 5. Testing

**`MailDelivery`** — the mechanism's entire value is *which* errors it swallows, so that is what is
pinned: each of the five `Net::SMTPError` includers, plus each timeout, socket, SSL and `Errno::*`
entry, returns `false`; and `NoMethodError` and `I18n::MissingTranslationData` **propagate**. The
second half is the mutation-resistant half — a rescue later widened to `StandardError` passes every
test that checks only the happy cases.

**Request specs, with delivery stubbed to raise:**

1. Signup failure — row persists, session set, `welcome_password` rendered, password in the body,
   `Cache-Control: no-store` present.
2. Signup success — identical to today: redirect to dashboard.
3. **Password reset anti-oracle** — a registered address (mailer raises, rescued) and an
   unregistered address (no mail attempted) produce the same status, redirect and flash. The most
   valuable example here: it fails the moment someone turns D4's discarded boolean into a message.
4. **Invitation accept with a raising mailer still runs `reject_rest_of_invitations`** — a
   regression test for the bug that fixes itself, so that it stays fixed.
5. The log line names the exception class and does **not** contain the generated password, **nor any
   e-mail address**. See the correction in D9.

**Probe** — `classify` driven from fixtures, no network, `spec_helper` not `rails_helper`, mirroring
`spec/ops/vmscale_policy_spec.rb`.

**Gates, run by the orchestrator and not delegated:** full RSpec, full Cucumber, the inherited
contract at 228/2325, and `bin/rails zeitwerk:check`. `DATABASE_URL` points at a scratchpad sqlite
file so a parallel session cannot lock `db/test.sqlite3`.

---

## 6. Rehearsal

Once the Fastmail app password exists, the cutover is performed **for real** once: switch, verify a
live registration, switch back. Roughly ten minutes, blast radius limited to outbound mail. This is
what separates a runbook from a document, and the probe then keeps the spare proven from that day
forward.

---

## 7. Failure modes accepted

* **A per-recipient rejection still looks like success to the sender.** A 550 for one address is
  rescued and logged like any other transport error; the probe cannot see it because it never sends.
  Detecting this needs a delivery counter or bounce handling, which is out of scope.
* **The daily send cap tripping mid-game is invisible until someone reads the logs.** The 6-hourly
  probe will catch it late, not live. This is an argument for leaving Gmail (§8), not for a faster
  probe.
* **The probe's own AUTH attempts are a small provocation** to Gmail (D7).
* **Mail is still synchronous.** A slow SMTP server still holds a Puma thread for up to ~10s across
  connect and read. Bounded, and unchanged by this work.

---

## 8. Non-goals, and the obvious next steps

* **Promote Fastmail to primary.** Verification for D8 turned this up and it deserves stating: the
  spare is arguably the better primary. Today's mail comes from `@gmail.com`, aligned only because
  Gmail's own SPF covers it; via Fastmail it would come from an SPF-aligned `@mezin.eu`, and the
  free-tier 500-recipients/day cap — a real ceiling for an invitation-driven app — would be gone.
  The rehearsal in §6 effectively proves the path.
* **`mezin.eu` has no DMARC record.** `_dmarc.mezin.eu` *appears* populated only because the domain
  serves a **wildcard TXT** record — verified: `nonexistent-probe-xyz.mezin.eu` returns the same
  SPF-looking string. There is no `v=DMARC1` policy. Out of scope, but it is a deliverability gap
  and a prerequisite for any future ACS migration.
* **Set-password-by-token at signup** (D3) — the correct long-term shape; needs a fourth authorised
  feature-file amendment.
* **Background delivery.** Moving mail off the request thread needs a real ActiveJob backend, which
  this single-vCPU host does not have. A different project.
* **In-app delivery-failure counter.** Considered and dropped: `Rails.cache` is `:memory_store`,
  process-local and wiped on deploy, so it would be a live signal rather than a record.

---

## 9. Invariants, and how to re-verify them

| Invariant | How to check |
|---|---|
| Inherited acceptance contract unchanged | the `comm -12` command in `CLAUDE.md` → 228 / 2325 |
| No account can exist whose password was never disclosed | spec 1 in §5 |
| Password reset reveals nothing about address registration | spec 3 in §5 |
| Only transport errors are swallowed | `spec/services/mail_delivery_spec.rb` |
| The spare authenticates | the 6-hourly probe, both endpoints |
| `MailDelivery` has not collided with the `mail` gem | `bin/rails zeitwerk:check` |
