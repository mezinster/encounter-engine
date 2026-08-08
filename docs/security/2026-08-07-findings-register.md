# Security Findings Register — 2026-08-07/08

What the whole-application security review found, what shipped, and what each fix is actually
backed by. Companion document: [`2026-08-08-follow-up-queue.md`](2026-08-08-follow-up-queue.md),
which carries everything implementation surfaced that no plan covered.

Delivered in three pull requests, all merged into `master`:

| PR | Scope | State |
|---|---|---|
| [#32](https://github.com/mezinster/encounter-engine/pull/32) | Stored XSS ×2, user-directory dump, gameplay access control | merged |
| [#33](https://github.com/mezinster/encounter-engine/pull/33) | CSRF verb migration, answer-log disclosures ×2, ops credential | merged |
| [#36](https://github.com/mezinster/encounter-engine/pull/36) | Account protection, password reset, signup redesign | merged |

Suite on `master` after all three: **RSpec 944 examples / 0 failures / 6 pending**;
**Cucumber 232 scenarios (2 undefined, 230 passed) / 2342 steps**.

The scenario count fell from 234 because two scenarios were removed under the third authorised
acceptance-suite amendment (see `CLAUDE.md`). It is the only reduction in coverage in this work,
and it was authorised explicitly.

---

## Closed — HIGH

### Stored XSS in the invitation autocomplete
`app/views/invitations/new.html.erb`

Nicknames were interpolated into a JavaScript string literal. `ERB::Util.html_escape` covers
`& " ' < >` and **not** the backslash, so a nickname ending in `\` escaped the closing quote, merged
the two literals, and put the email field in executable position. Registering with nickname `evil\`
and email `-alert(1)});//@x.com` — both of which pass the model's validations — executed script for
every team captain who opened the page.

Fixed by emitting the list as JSON in a `<script type="application/json">` island and parsing it.
Pinned by a regression example using a `</script>` nickname, and by a property assertion that the
nickname's backslash run occurs exactly once and in escaped form — the literal-text assertion it
replaced would have passed against a reintroduction using different syntax.

### Stored XSS in the live hint poller
`public/javascripts/level_hint_updater.js`

Author-written hint text was concatenated into an HTML string passed to jQuery `.append()`, which
parses markup — and jQuery 1.3.2 additionally `globalEval`s any `<script>` it finds. Any registered
user can create a game and author hints, so this executed attacker-controlled script in every
playing team's browser. The server-rendered path escaped correctly, so the bug was invisible on page
load and fired only when a hint unlocked live.

Fixed by building DOM nodes. Verified against the vendored jQuery source: `clean` gates all
`innerHTML` work behind `if (typeof S === "string")`, so appending an element never enters the
parser.

**Residual:** the browser check was performed by the repository owner, not by automation. No agent in
this engagement had a browser.

### Gameplay without registration
`app/controllers/game_passings_controller.rb`

The filter chain checked authenticated, on *a* team, game started, not author-finished, not exited,
not the author — but never that this team was admitted to *this* game. Registration was enforced
only in views that hide a link. Any user could create a team and `GET /play/:game_id` for any started
game, including one whose entry the author had explicitly rejected, consuming no capacity slot while
appearing in the author's stats and the public results table.

Fixed at creation rather than in a filter, so a team already mid-game is never locked out by a status
change. The `is_testing?` exemption is scoped to the author — unscoped, it would have let any team
read every level and code while a game sat in test mode. That hole was in the plan and was caught in
review.

### ~20 destructive actions outside CSRF protection
`config/routes.rb` and 19 view call sites

Rails skips forgery verification for GET by design. The worst case, `GET /games/finish_test/:id`,
ran `GamePassing.of_game(@game).delete_all` and `Log.of_game(@game).delete_all` — no callbacks, no
audit row, unrecoverable — and because `ensure_author` returns early for superadmins, a superadmin's
session authorised that URL for **every game on the instance**. One clicked link.

Converted to POST/DELETE with `button_to`. This app has no Turbo and no rails-ujs, so
`link_to ..., method:` would have silently issued a GET; every call site was checked for that.

**A negative routing example now asserts GET no longer reaches these actions.** Before it, re-adding
`get :delete` beside `delete :delete` left the entire suite green — the migration proved the new
verbs worked and never that the old ones stopped.

---

## Closed — MEDIUM

**Orphan rows that 500 a public page.** `find_or_create_game_passing` ran before the authorisation
filters, so a team-less user's 401 still committed a `GamePassing` with `team_id NULL`. Both the
author's stats page and the *unauthenticated* results page dereference `game_passing.team.name`, and
no UI could delete the row. Fixed at the write; a one-shot migration removes existing rows and runs
automatically via `bin/docker-entrypoint`'s `db:prepare`.

**Two cross-game answer-log disclosures.** `show_game_log.html.erb` discarded the controller's scoped
`@logs` and re-queried `Log.of_game(level)` — and because Rails resolves an ActiveRecord object in a
`where` hash by its `id`, passing a **Level** rendered the log of whatever *game* shared that
integer. `show_full_log.html.erb` had the same shape and disclosed more: it never used `@logs` at
all, and since `logs.team`/`logs.level` are name strings, the query matched every game ever played,
rendering rows fully attributed under the level heading and inside the team's column.

**The second instance was not found by the original review.** It surfaced when a reviewer swept for
the *shape* of the bug after the first was fixed.

**User-directory dump.** The invitation page emitted every registered user's email — the app's login
identifier, and therefore a complete valid-username list — to anyone who created a team.

**Quiz option read oracle.** `post_options` built its echoed answer from unvalidated option ids, so a
player could read back option text from unreached levels and other games with no penalty charged.

**Password changes required no proof of identity** (CWE-620), in an app with no recovery flow — so
momentary access to a logged-in browser was a permanent, unrecoverable takeover.

**A stolen session cookie stayed valid indefinitely.** `reset_session` rotates only the requesting
browser; `CookieStore` keeps no server-side record and sets no `expire_after`.

**Single-round salted SHA-1 password hashing.** Now bcrypt, with legacy rows upgrading on their
owner's next successful login and the SHA-1 columns nilled once upgraded.

**No account recovery existed.** A reset flow now does: SHA-256-digested tokens, two-hour
server-side expiry, single use, `secure_compare`, and identical responses for registered and
unregistered addresses.

**Production database password in `argv`.** `ops/db-restore-scratch.sh` passed it on a `docker run`
command line; `/proc/<pid>/cmdline` is world-readable while `/proc/<pid>/environ` is not, on a host
`ansible/playbook.yml` describes as shared with other tenants. The variable was never consumed.

---

## Refuted during verification

Recorded so they are not re-raised:

- **Session fixation on signup.** The mechanic was real; the exploit was not. `SameSite=Lax` and
  `forgery_protection_origin_check` are mutually covering — the attacker capability that defeats one
  is what the other catches. Fixed anyway as consistency hardening, and labelled as such.
- **`:answer` missing from `filter_parameters`.** The same request already persists the answer to
  the `logs` table by design, and the app shows those codes to the author as a product feature.
- **`create-heroku-instance` leaking `SECRET_KEY_BASE`.** Heroku is a dead target; production is
  Kamal.

---

## What the fixes are actually backed by

The most transferable result of this work is not the list above. It is that **a green suite was
repeatedly weak evidence**, and the only thing that reliably distinguished a real test from a
decorative one was deliberately breaking the code and watching it fail.

**Four assertions could not fail.** Three were written by the planning process itself: one matched a
comment containing the searched word; one compared `session.id` objects that have no `#==`, so the
comparison never matched regardless; one asserted `position` on a request that only changes `text`.
Each was caught by mutation testing, never by inspection.

**Two security properties shipped untested.** The CSRF migration proved the new verbs worked and
never that the old ones stopped. The session-eviction work proved the model rotated its token and
never that authentication rejected a stale cookie — reverting `current_user` to its vulnerable
one-liner left the whole suite green at 888 examples.

**Four tests encoded a defect as expected behaviour.** A view spec built a `Log` row under
`game_id: level.id` with a comment calling it "a pre-existing oddity". Another asserted the password
field rendered as visible `type="text"`. A Cucumber step reloaded a URL in a way that only worked
because destructive actions were GETs. And an acceptance scenario asserted a password could be
changed without proving the old one — that one was inside the frozen contract and required an
explicit owner authorisation to amend.

**Eleven plan-authoring errors** were caught by implementers and reviewers checking rather than
trusting: stale line numbers three times, a wrong method signature, a false premise about what the
tests did before a change, a scope claim about 13 call sites that was wrong, a Rails lifecycle detail
(`password` is a sticky `attr_accessor`), a mailer URL with no host outside production, and design
prose that specified `secure_compare` while the accompanying sample code omitted it.

**One interaction bug emerged from two individually correct changes.** Session rotation keyed on the
password column being dirty, which held only because SHA-1 with a stored salt is deterministic.
bcrypt salts randomly, so every save re-hashed to a different digest, looked like a credential
change, and evicted the user's own session. Eleven specs went red immediately — the suite caught what
neither plan anticipated.

---

## Acceptance-contract changes

`CLAUDE.md` forbids editing `.feature` files except on an explicit, recorded owner decision. Two were
authorised during this work and both are recorded there with dates, reasons and counts:

- **2026-08-07** — one step added to "Изменение пароля пользователя", because the profile form now
  requires the current password. 234 scenarios unchanged; 2358 → 2359 steps.
- **2026-08-08** — signup no longer collects a password: two password-fill lines and a mail assertion
  amended in "Удачная регистрация", the "Подтверждение пароля не совпадает" scenario deleted, and
  `features/games/signup-password.feature` deleted. 234 → 232 scenarios.

The second is the only reduction in acceptance coverage in this work. Two behaviours — password
confirmation matching, and password fields being masked at signup — stopped being tested because
they stopped existing.
