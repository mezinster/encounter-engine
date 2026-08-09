# Security Follow-Up Queue — 2026-08-08

Everything the 2026-08-07/08 remediation surfaced that no plan covered. None of it is in
[`2026-08-07-findings-register.md`](2026-08-07-findings-register.md)'s closed list — that document
records what shipped; this one records what is still open.

Almost all of it was found by implementers and reviewers **checking claims rather than trusting
them**, usually while fixing something adjacent. The two structural items at the top are the ones
worth planning properly; the rest are individually small.

---

## Tier 1 — deserves its own plan

### 1. `logs` stores team and level as name strings, not foreign keys — DONE, PR #40

Shipped and merged: `team_id`/`level_id` columns added, backfilled, `of_team`/`of_level` switched
to id-based scopes. The section below is left as the original write-up for context. One gap
surfaced afterward: `Log.of_game` itself was left as `where(game_id: game)` — an AR object, not
`.id` like its siblings — the exact permissiveness that let a `Level` be passed where a `Game` was
meant (see `spec/requests/game_log_scope_spec.rb`). Closed in the `chore/follow-up-cleanup` batch:
`where(game_id: game.id)`, all callers confirmed to pass a `Game`.

`db/schema.rb` — `logs.team` and `logs.level` are `varchar`, written by
`GamePassingsController#save_log` as `team.name` and `level.name`. Only `Log.of_game` matches on an
id; every other scope matches on a name and is therefore **globally ambiguous unless a game filter is
also present**.

This is the shared root of *both* answer-log disclosures fixed in PR #33, and it will keep
regenerating that bug shape. It also means:

- Renaming a team silently re-attributes its historical rows — the old rows become invisible, and if
  another team later takes that name, within the same game it inherits them.
- `Level#name` has no per-game uniqueness constraint (`app/models/level.rb` validates presence only),
  so two same-named levels in one game cross-render each other's rows. Mis-attribution rather than
  disclosure, since both are already visible to that viewer.
- `teams.name` uniqueness is app-level only — no unique index in `db/schema.rb`.

**Shape of the fix:** add `team_id` and `level_id` columns, backfill by name, switch the scopes,
keep the string columns for historical rows whose referent no longer exists. Not a one-liner — it
needs a migration, a backfill strategy for unmatched rows, and a decision about what a log row means
when its team has been deleted.

### 2. Test suite has repeatedly been adjusted to match broken behaviour

Not a vulnerability; a property of the codebase that made every other finding harder to trust. Four
tests were found asserting a defect was correct (details in the register). The pattern suggests the
habit is "make the test agree with the code", and it means a green suite here has been weaker
evidence than it looks.

**Shape of the fix:** a convention — any spec that pins surprising behaviour must say *why* in a
comment, and any guard-style assertion must be mutation-tested when written. Cheap to adopt, and it
is the single change that would most improve confidence in this suite.

---

## Tier 2 — real defects, small fixes

### 3. `error_messages_for` renders validation messages as unescaped HTML — DONE, PR #41

`app/helpers/application_helper.rb` builds `"<li>%s</li>" % message` from `errors.full_messages` and
returns `markup.html_safe`. The original review cleared this on the reasoning that no message
interpolates a user-supplied *value* — **that reasoning was wrong**. `app/models/game.rb`'s
`available_locales.unknown` interpolates `available_locale_list`, which `GamesController` permits as
arbitrary strings. Demonstrated end to end:

```
Available locales содержит неизвестные языки: <img src=x onerror=alert(1)>
HTML_SAFE?: true
```

Self-XSS rather than stored (the value comes from the submitter's own params, and CSRF protection is
on), hence Tier 2 — but it is one line (`build_li % ERB::Util.html_escape(message)`), it is rendered
by 13 call sites, and it becomes stored XSS the day any validation message interpolates a persisted
value.

### 4. `GameEntry` has no uniqueness constraint, and `#new` creates a row per request — DONE, PR #42

No unique index on `(team_id, game_id)`; `GameEntriesController#new` creates an entry on every hit
with no existence check. A team can therefore hold several entries for one game and consume several
`reserve_place_for_team!` capacity slots. PR #32 worked around the symptom by making `GameEntry.of`
prefer an accepted entry, because otherwise a rejected duplicate with a lower id would have locked a
legitimately accepted team out of a live race.

### 5. A mutating GET the CSRF migration could not fix

`find_or_create_game_passing` is a `before_action` on `GET /play/:game_id` and `/tip` that calls
`GamePassing.create!` and starts the team's clock. Found by the whole-plan review's own completeness
check — parsing routes by verb, locating action bodies via the Ruby AST, then scanning the
`before_action` chains, because an action body is not the whole request. Not fixable by the CSRF
plan's method: `config/routes.rb` deliberately preserves those bookmarked URLs, and this is lazy
initialisation rather than a state transition.

### 6. A partial clobbers controller instance variables mid-render — DONE, `chore/follow-up-cleanup`

`app/views/games/_game_entries.html.erb` assigns `@team` and `@game` *inside its loop*, overwriting
the controller's ivars for everything rendered afterwards. Both call sites were traced and neither is
currently exploitable — on one, `@game` is overwritten with itself; on the other, the affected branch
is dead code after an early return. Benign today, one partial-reorder away from not being.

Fixed by switching the loop to local variables (`team`/`game`, not `@team`/`@game`). Both call sites
(`app/views/games/show.html.erb`, `app/views/dashboard/index.html.erb`) still render correctly —
neither reads `@team`/`@game` set by the partial.

### 7. `t()` results interpolated into JavaScript string literals — DONE, `chore/follow-up-cleanup`

`app/views/shared/_countdown.html.erb` and `app/views/games/show.html.erb`, with
`_countdown.html.erb` feeding the value to `elem.html(prefix + s)`. The source is a locale file, not a
user, so it is not a vulnerability — but it is the identical construct PR #32 removed, and it is
inconsistent with lines 5-10 of that same file, which correctly use `.to_json.html_safe`.

Both call sites now use `.to_json.html_safe`, consistent with lines 5-10 of `_countdown.html.erb`.
The `elem.html(prefix + s)` sink itself is untouched — the value it now receives is JSON-escaped at
the source, and changing the sink was not asked for and not needed for this specific construct.

### 8. `data: { confirm: ... }` attributes are inert

Two call sites carry them. This app has no Turbo and no rails-ujs, so nothing reads them and no
confirmation dialog ever fires. Either wire up a confirm mechanism or drop the attributes and their
i18n keys — but not silently, because they read as protection that does not exist.

Still open. Explicitly left alone by the `chore/follow-up-cleanup` batch: removing a confirmation
affordance, or wiring one up, is a product decision, not a cleanup — deferred, not forgotten.

---

## Tier 3 — known limitations of what shipped

### 9. Re-entering your existing password evicts nothing
`encrypt_password` short-circuits when the plaintext already matches, so the digest never changes and
`session_token` never rotates. "Change my password because I think I am compromised" is a no-op
unless the new password actually differs — the exact case where eviction matters most.

### 10. The welcome letter carries the password in cleartext
Owner's decision, and coherent now that the server generates it. The exposure is real: a working
credential resting in a mailbox indefinitely, in the relay's logs, and on the wire whenever
opportunistic STARTTLS does not negotiate. Bounded by the reset flow.

### 11. Email verification is implicit
Successful login proves mailbox ownership, but nothing records that it happened and nothing is gated
on it. If verification is ever meant to protect something, it needs a column and a decision about
what it blocks.

### 12. `authenticate` raises on a non-persisted record — DONE, `chore/follow-up-cleanup`
The lazy bcrypt upgrade calls `update_columns`, which raises on a new or destroyed record where the
method previously returned a boolean. No current caller passes one; a console session or a future
caller would 500 on a *correct* password.

Fixed: the `update_columns` upgrade is now guarded with `if persisted?`, so a non-persisted or
destroyed record returns `true` on a correct password instead of raising. Two specs added in
`spec/models/user/authenticate_spec.rb` (a new, unsaved record and a destroyed record).

### 13. Level partitioning in `show_game_log` is untested
Dropping `.of_level` leaves every example green, and Cucumber cannot catch it either — its
`должен увидеть следующее:` step is an unordered per-string `have_text`, so it asserts the codes
appear *somewhere*, not under the right heading.

### 14. The XSS source guards are text-based
`spec/assets/level_hint_updater_spec.rb` cannot see `insertAdjacentHTML`, `outerHTML`, ES6 template
literals, or variable indirection — a reviewer demonstrated `insertAdjacentHTML` slipping through.
Inherent to static text guards; a real JS test runner is the only complete answer.

### 15. bcrypt login latency is unmeasured
Cost 12 is confirmed in production, but login latency at that cost was never measured against this
app's request budget.

---

## Tier 4 — hygiene

16. **`CLAUDE.md` doc drift. — DONE, `chore/follow-up-cleanup`** The i18n section's leaf-key count,
    the RSpec and Cucumber counts, and the "Deployment: Heroku" section are all stale — production is
    Kamal. Worth one pass now that the queue has drained and the numbers have stopped moving.

    Every number re-verified rather than copied from any prior doc: leaf keys are **488** per locale
    (counted directly from `config/locales/{ru,en,uk,ka}.yml`, up from the 295 previously recorded —
    the file grew since that count was taken); RSpec is **967 examples, 0 failures, 6 pending** (run
    directly, `bundle exec rspec`); Cucumber is **232 scenarios (230 passed, 2 undefined), 2342
    steps** — matches the count already derived in `CLAUDE.md`'s own acceptance-suite-rule change log
    (not independently re-run here — Cucumber takes longer than this pass's tooling allows per-command,
    left for the next full suite run to reconfirm). The Deployment section now describes Kamal
    (`config/deploy.yml`, `.kamal/secrets`, `.github/workflows/deploy.yml`) and keeps the still-accurate
    `SECRET_KEY_BASE`-from-environment explanation; `create-heroku-instance` is noted as retained history,
    not the live deploy path.
17. **`features/support/env.rb`'s identity-counter reset may be justified by nothing.** Its stated
    reason was corrected during PR #33 after the original justification proved false; a grep found no
    remaining hardcoded id-1 dependency. Either substantiate it or drop it.
18. **`ops/db-restore-scratch.sh` breadcrumb placement. — DONE, `chore/follow-up-cleanup`** The
    comment explaining the deliberately absent `POSTGRES_PASSWORD` sits at the old assignment site,
    not in the `docker run` block where someone would re-add it, and it hardcodes a line number that
    will drift.

    Fixed: the breadcrumb next to `docker run` now references the explanation by description
    ("the comment above the `POSTGRES_PASSWORD` note near the top of this script, next to where
    `WALG_AZ_PREFIX` and `AZURE_STORAGE_ACCOUNT` are read off the running production container")
    instead of a line number.
19. **The restore rehearsal is still an open ops gate. — DONE, PR #31 (and #41)** `ops/db-restore-scratch.sh`
    changed and the plan's mandated rehearsal was never run — no Docker, no Azure credentials, no
    production host available to automation. Run the **Database** workflow's `restore-to-scratch`
    action and watch: the base-backup fetch completing; the promotion check ending in ` f` not ` t`;
    and the row-count block printing integers, not `?`.

    **If it prints `?`, do not restore the `-e POSTGRES_PASSWORD` line.** That would not have fixed
    it — libpq reads `PGPASSWORD` and never `POSTGRES_PASSWORD`. The correct fallback is an
    `--env-file` on a `mktemp`ed 0600 file removed by the script's existing cleanup trap.

    Rehearsed and recorded: PR #31 ("Add a rehearsed restore runbook, a Database workflow, and WAL
    retention") added the runbook and the Database workflow; PR #41 includes "Record the post-change
    restore rehearsal" confirming the rehearsal ran clean after the escaping fix landed.

---

## Tier 5 — signup and reset abuse (added 2026-08-09)

Opened by a question from the owner: registration takes only a nickname and an e-mail, so what stops
a script from creating accounts in bulk? The database turned out to be the least of it.

### 20. Unauthenticated mail cannons — DONE (rate limiting), `feature/signup-abuse-hardening`
`POST /users` and `POST /password` both send mail to an **attacker-chosen** address. SMTP defaults to
`smtp.gmail.com` (`config/environments/production.rb`), which caps sending at a few hundred a day and
suspends senders that trip its spam heuristics — so a script could exhaust the quota and get the
account suspended, which stops invitations and resets too, not just signups.

Closed by a per-IP fixed-window throttle (`app/controllers/concerns/request_throttling.rb`) whose
limits live in `settings` and are edited at `/admin/settings` without a deploy. Rails 8's built-in
`rate_limit` was not usable: it captures `to:`/`within:` at class-load time.

Also closed: a signup honeypot, measured to have no layout effect on phone or desktop.

### 21. Mail is still delivered synchronously — OPEN
Both endpoints call `deliver_now`, so a permitted request holds a Puma thread for a full SMTP round
trip (0.5–2s to Gmail). Below the throttle's limits this is still the cheapest way to occupy every
thread this app has, and it puts SMTP latency in the user's signup.

`deliver_later` is the obvious fix and is **not free here**: no queue backend is configured, so
Rails' default `:async` adapter is an in-process thread pool that drops jobs on restart or deploy. A
welcome letter or a reset link vanishing silently is arguably worse than a slow signup. Needs a
durable queue (solid_queue) before it is worth doing.

### 22. Nothing alerts on a throttle trip — OPEN
`RequestThrottling` logs `[throttle] ... remote_ip= xff= count= limit=` on every refusal, and nobody
reads it. The first sign of a real attack would be Gmail suspending the sending account. Same blind
spot as the backup timer, which also tells nobody when it fails.

### 23. `remote_ip` behind kamal-proxy — DONE, verified in production 2026-08-09
The limiter keys on `request.remote_ip`. Every connection arrives from the proxy container, so this
is only correct if `ActionDispatch::RemoteIp` trusts that hop and reads `X-Forwarded-For`. It should
— the proxy connects over the Docker bridge, a private address Rails trusts by default — but that is
reasoning, not evidence, and the failure direction is the bad one: if XFF is ignored, **every request
in the world shares one counter** and the first few signups of each window lock everyone out.

**Verified, and it did not need a deploy.** Rails already logs the client address on every request:
`Rails::Rack::Logger`'s "Started ... for X" line is `request.remote_ip`, the same expression the
limiter keys on. A marked request from a known public address was made against the live site and the
running container's log read back:

    Started GET "/login?probe=remoteip-check" for 178.134.238.169   <- the real client
    Started GET "/team-room"                  for 3.78.35.189
    Started GET "/"                           for 73.151.93.198

The address is the client's public IP, not a `172.x` bridge address or the proxy's, and it differs
per client — so kamal-proxy is setting `X-Forwarded-For` and `ActionDispatch::RemoteIp` is honouring
it. There is no `trusted_proxies` override anywhere in `config/` or `app/`, so this is Rails' default
private-range trust doing the right thing, and nothing in this branch changes it.

Re-check if the proxy is ever replaced, moved off the Docker bridge, or fronted by a CDN — a CDN in
particular would make the CDN's egress IP the client unless it is added to `trusted_proxies`.

### 24. The reset flow was left as it is — owner's decision, 2026-08-09
A redesign was planned (the emailed link would issue a generated password in a second mail) and then
dropped, because the property it was meant to buy already holds: `PasswordResetsController#create`
only issues a token and mails a link, so a stranger submitting someone else's address changes
nothing. The redesign would have added a second cleartext-password e-mail — the opposite direction
from item #10 — and doubled the mail volume of an endpoint this work was hardening.

Recorded so it is not re-proposed as an oversight. If it is ever revisited, the emailed link must
**not** perform the reset itself: mail scanners follow links on delivery, so a mutating `GET` would
reset accounts nobody asked to reset.
