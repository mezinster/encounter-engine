# load_test/

k6 scripts that drive the Rails app as real teams, against a manifest seeded
by `bin/rails load_test:seed[teams,levels]` (see `lib/load_test/seeder.rb`).
Phase 1 (Ruby) builds the cohort and writes the manifest; this directory is
Phase 2, the k6 side that reads it and hits the app's real routes.

| | |
|---|---|
| `lib/manifest.js` | Loads the manifest JSON once per run (via `SharedArray`, not per-VU) and hands out one team per VU. |
| `lib/auth.js` | Scrapes the CSRF token and logs a VU in through the real `/login` form. |
| `lib/play.js` | One play cycle: GET the current level, think, POST an answer (mostly wrong, by design), think again. |
| `main.js` | Entry point. Two phases, selected by `--env PHASE`: `ramp` (default) steps the number of **concurrent VUs** (one VU = one team) up through plateaus to find the ceiling and aborts on a threshold breach; `hold` holds a fixed VU count -- a fixed team count, not a request rate -- to completion regardless. |

## Running

```bash
export PATH="$HOME/.local/bin:$PATH"   # k6 is installed here, not /usr/local/bin
bin/rails 'load_test:seed[1,5]'         # source_game_id, teams -- prints the manifest path it wrote
bin/rails server &

k6 run --env MANIFEST=/tmp/<cohort>.json --env PHASE=ramp --env BASE_URL=http://localhost:3000 load_test/main.js
k6 run --env MANIFEST=/tmp/<cohort>.json --env PHASE=hold --env TEAMS=60 --env BASE_URL=http://localhost:3000 load_test/main.js
```

Both phases define their own `scenarios` in `options`, so **`--vus`/`--iterations`/`--duration`
on the CLI don't work here** — k6 treats any of those flags as a request to run a single
CLI-configured scenario against a function literally named `default`, which this script doesn't
export (`ramp`/`hold` both `exec: 'session'`), and refuses to start
(`function 'default' not found in exports`). To bound a local smoke test, either let the `ramp`
stages run (they're short near the start) or send the process a SIGINT after the desired time and
let k6 print its partial summary and exit, rather than passing `--duration`.

**A `target`/`TEAMS` number here is a team count, not a request rate.** Both scenarios are
VU-based (`ramping-vus` / `constant-vus`), and one VU is one team, deliberately: teams are a
*closed* population — a fixed number exist, and if the app slows down a team waits rather than
spawning a second one to compensate. An *arrival-rate* executor (`ramping-arrival-rate` /
`constant-arrival-rate`) models the opposite, *open* population, where `target`/`rate` means
iterations **started per unit time** — a different quantity from "concurrent teams" by a factor of
the iteration duration, which `lib/play.js`'s own think times (20-90s + 5-20s sleeps) make ~67.5s
on average. An earlier version of this file used `ramping-arrival-rate` with the same "10 → 120"
numbers the design doc calls team counts; read as an arrival rate they'd have asked for 675-8100
concurrent VUs and generated up to 240 req/s against a one-vCPU host, instead of the ~3.6 req/s
120 real, mostly-idling teams actually produce — and with the pool sized for the intended reading,
it would have starved before the *first* plateau, silently reporting k6's own VU exhaustion as
"the ceiling." See `main.js`'s comment on `RAMP` and `task-9-fix-report.md` for the numbers.

`--env BASE_URL` overrides the manifest's own `base_url` (useful for pointing
the same manifest at a different host without re-seeding). `--env TEAMS` sets the `hold` phase's
constant VU count (default 60 — pick something around 70% of the ramp's last clean plateau) and is
ignored by `ramp`, whose plateaus are fixed in `main.js`. `--env
WRONG_SHARE` (default 0.85) is `lib/play.js`'s share of deliberately-wrong answers — raise it
towards 1 for a smoke test you don't want to accidentally finish the seeded game.

**`WRONG_SHARE` is the share of answer POSTs that are wrong, not the app's own accept rate.**
`pickCode()` now draws a "correct" answer from `manifest().codes[team.level_id]` — the specific
level the team's manifest entry says it started on (`lib/load_test/seeder.rb`'s `build_team`),
never from every level's codes pooled together. Correctness in the app is per-level
(`GamePassing#check_answer!` matches through `current_level.find_question_by_answer`), so pooling
all codes together made a "correct" draw land on the team's actual current level only about
`1/levels` of the time — roughly 30x below the designed 15% on a typical game, which under-exercised
the expensive accept path (re-serialising `answered_questions`, writing to the points ledger)
relative to the cheap wrong-answer path (a log row). `level_id` is the team's *starting* level, so
this is exact at the top of a run and drifts low as the team actually answers correctly and
advances — accepted as much closer than the old behaviour, not perfect; this harness doesn't track
live level state.

**Never commit a manifest.** It carries live team passwords in plaintext.
Manifests are written to `/tmp` by the seeder and stay there.

## Why the CSRF token is cached, not re-scraped

Rails masks `authenticity_token` differently on every render but accepts any
valid unmasking for the session that issued it. `login()` in `lib/auth.js`
fetches it once per VU. Re-fetching before every POST would add a phantom GET
ahead of every write in the play loop Task 9 adds, which would distort the
read/write ratio the whole test exists to measure.

`csrfFrom` reads the `<meta name="csrf-token">` tag before the hidden form
field, because `csrf_meta_tags` is rendered by both layouts
(`application.html.erb` and `in_game.html.erb`) and so is present on every
page in the app, including the dashboard a captain lands on after login and
the play screen Task 9 drives. A hidden `authenticity_token` form field is
not guaranteed on those pages — the dashboard renders one only if some
unrelated, not-yet-started game happens to exist in whatever database the
run points at, which is incidental global state, not a property of being
logged in. The form-field regex stays as a fallback for pages that render a
form but no meta tag (there are none in this app today, but the fallback is
cheap and keeps the function from being tied to one specific page's markup).

## Why every check asserts on body, never on status alone

k6 follows redirects by default. A failed `POST /login` still lands on a `200`
(the re-rendered form, or wherever a redirect chain ends), so a check that
only looks at `res.status` reports a flawless run against an app it never
actually authenticated to.

`login()`'s check is a **positive** body assertion — `r.body.includes('href="/logout"')`,
the one string that only ever appears on a page rendered for a logged-in user
(the left-menu logout link). It has to be positive, not merely "the login
form isn't showing again": a wrong password re-renders the form (catchable by
checking for the absent `name="password"` field), but a wrong or expired CSRF
token makes Rails' `protect_from_forgery` raise *before* any form renders —
in development that's the interactive debug page, in production it would be
whatever generic body Rails falls back to (this app ships no `public/422.html`).
Neither contains `name="password"` either, so the negative form of the check
passes on a CSRF failure too. This was measured directly against this app's
real `/login`, not assumed: writing the check as `!r.body.includes('name="password"')`
reported **100% success** on a run where every `POST /login` was rejected
with `422` — see Step 7 in `task-8-report.md` for the actual console output.

This is not a theoretical risk in this codebase — see the `CLAUDE.md` entries
on the countdown examples that reported *pending* for a fortnight, and the
HEIC probe that reported success on a machine that couldn't decode a single
HEIC byte. Both were checks that couldn't actually fail. The mutation tests
below exist so this harness isn't a third instance — and, in this case, one
of them caught it before the harness shipped.

## Mutation-testing this harness

A check that can't go red is worthless, so both checks here are proven
capable of failing, not just of passing:

- **Wrong password.** Corrupt every team's password in a copy of the manifest
  and re-run — expect the run to fail with `login failed`, not a quiet 100%.
- **Wrong CSRF token.** Temporarily hardcode `csrfFrom` to return an invalid
  token and re-run — expect Rails' `protect_from_forgery` to answer `422`,
  surfaced as a failed check.

Re-run both whenever `lib/auth.js` changes in a way that touches what a check
asserts on — including a change to `login()`'s own check predicate, which is
exactly what broke the first time (see above).

## Why `main.js` sets `noCookiesReset: true`

k6 resets each VU's cookie jar at the **start of every iteration** by default. JS module scope
(the `let token = null;` cache in `main.js`) is per-VU and survives fine, but the session cookie
that token depends on does not: without this flag, a VU logs in successfully on iteration 1, k6
throws its cookies away before iteration 2, `GET /play/:id` on iteration 2 comes back
unauthenticated (redirected to `/login`), and the still-cached token from iteration 1 no longer
matches that reset session — so `POST /play/:id` 422s with "Can't verify CSRF token authenticity"
on every iteration from the second one onward, for the rest of the VU's life. Confirmed directly
with a scratch script that dumped `http.cookieJar().cookiesForURL()`: `{}` at the top of iteration
2 on the same VU that had just logged in. `noCookiesReset: true` makes the jar persist across a
VU's iterations, matching what the per-VU login cache assumes. If you ever see `checks` pass on
iteration 1 of a smoke test and then collapse afterward, this is the first thing to check.

## Mutation-testing the abort brake

`ramp`'s `abortOnFail` thresholds are the one safety property standing between a runaway local
script and a production host with co-tenant services on it. Prove they actually fire, not just
that they're present in the options object: temporarily change `p(95)<2000` to something no real
response can satisfy (`p(95)<1`) and re-run `PHASE=ramp`. Expect k6 to exit non-zero (99) within
roughly the `delayAbortEval` window with `thresholds on metrics '...' were crossed; at least one
has abortOnFail enabled, stopping test prematurely`, and the run summary to show interrupted
iterations rather than a clean stop. **Restore the real threshold afterward** — this is not a
committed test, it's a manual check to re-run whenever the threshold values or `abortOnFail`
wiring change. `hold` deliberately has no brake of its own: its whole purpose is to keep running
past the point where the VM's CPU credits run out, which is a threshold breach by design.

## `playbar-form` has two known false negatives, both legitimate states

Both checks in `lib/play.js` look for the `playbar-form` marker (`app/views/game_passings/
show_current_level.html.erb:220`), which repo-wide appears in exactly that one view and its own
CSS rule — nothing else in the app renders it, so a positive match is trustworthy. A *negative*
match is not automatically a bug, though: two states genuinely render `show_current_level` (or,
for the POST check, a real "the app accepted this" response) without the marker.

- **A paused game.** The form is wrapped `unless @game.paused?` in the view, so a game an author
  has paused mid-run serves a 200 with no `playbar-form` while the play screen is otherwise showing
  correctly. If a whole cohort's "on the level screen" check rate drops together, check whether the
  game got paused before chasing a script or app bug.
- **A correct answer that finishes the whole game.** `GamePassingsController#post_answer` renders
  `render_finished_passing` instead of `show_current_level` when `check_answer!` completes the last
  level — a real, successful POST, correctly reported by the `status !== 422 && status < 500` half
  of the check, but the `playbar-form` half will be false for that one request. With the default
  `WRONG_SHARE=0.85` this is rare (15% of answers are even candidates, and only on the game's last
  level), but it means the "answer accepted" check can never reach a true 100% pass rate against a
  cohort that's actually being played to completion — a small, expected amount of noise, not a
  regression to chase.
