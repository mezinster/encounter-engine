# Security Follow-Up Queue — 2026-08-08

Everything the 2026-08-07/08 remediation surfaced that no plan covered. None of it is in
[`2026-08-07-findings-register.md`](2026-08-07-findings-register.md)'s closed list — that document
records what shipped; this one records what is still open.

Almost all of it was found by implementers and reviewers **checking claims rather than trusting
them**, usually while fixing something adjacent. The two structural items at the top are the ones
worth planning properly; the rest are individually small.

---

## Tier 1 — deserves its own plan

### 1. `logs` stores team and level as name strings, not foreign keys

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

### 3. `error_messages_for` renders validation messages as unescaped HTML

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

### 4. `GameEntry` has no uniqueness constraint, and `#new` creates a row per request

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

### 6. A partial clobbers controller instance variables mid-render

`app/views/games/_game_entries.html.erb` assigns `@team` and `@game` *inside its loop*, overwriting
the controller's ivars for everything rendered afterwards. Both call sites were traced and neither is
currently exploitable — on one, `@game` is overwritten with itself; on the other, the affected branch
is dead code after an early return. Benign today, one partial-reorder away from not being.

### 7. `t()` results interpolated into JavaScript string literals

`app/views/shared/_countdown.html.erb` and `app/views/games/show.html.erb`, with
`_countdown.html.erb` feeding the value to `elem.html(prefix + s)`. The source is a locale file, not a
user, so it is not a vulnerability — but it is the identical construct PR #32 removed, and it is
inconsistent with lines 5-10 of that same file, which correctly use `.to_json.html_safe`.

### 8. `data: { confirm: ... }` attributes are inert

Two call sites carry them. This app has no Turbo and no rails-ujs, so nothing reads them and no
confirmation dialog ever fires. Either wire up a confirm mechanism or drop the attributes and their
i18n keys — but not silently, because they read as protection that does not exist.

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

### 12. `authenticate` raises on a non-persisted record
The lazy bcrypt upgrade calls `update_columns`, which raises on a new or destroyed record where the
method previously returned a boolean. No current caller passes one; a console session or a future
caller would 500 on a *correct* password.

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

16. **`CLAUDE.md` doc drift.** The i18n section's leaf-key count, the RSpec and Cucumber counts, and
    the "Deployment: Heroku" section are all stale — production is Kamal. Worth one pass now that the
    queue has drained and the numbers have stopped moving.
17. **`features/support/env.rb`'s identity-counter reset may be justified by nothing.** Its stated
    reason was corrected during PR #33 after the original justification proved false; a grep found no
    remaining hardcoded id-1 dependency. Either substantiate it or drop it.
18. **`ops/db-restore-scratch.sh` breadcrumb placement.** The comment explaining the deliberately
    absent `POSTGRES_PASSWORD` sits at the old assignment site, not in the `docker run` block where
    someone would re-add it, and it hardcodes a line number that will drift.
19. **The restore rehearsal is still an open ops gate.** `ops/db-restore-scratch.sh` changed and the
    plan's mandated rehearsal was never run — no Docker, no Azure credentials, no production host
    available to automation. Run the **Database** workflow's `restore-to-scratch` action and watch:
    the base-backup fetch completing; the promotion check ending in ` f` not ` t`; and the row-count
    block printing integers, not `?`.

    **If it prints `?`, do not restore the `-e POSTGRES_PASSWORD` line.** That would not have fixed
    it — libpq reads `PGPASSWORD` and never `POSTGRES_PASSWORD`. The correct fallback is an
    `--env-file` on a `mktemp`ed 0600 file removed by the script's existing cleanup trap.
