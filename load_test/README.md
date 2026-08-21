# load_test/

k6 scripts that drive the Rails app as real teams, against a manifest seeded
by `bin/rails load_test:seed[teams,levels]` (see `lib/load_test/seeder.rb`).
Phase 1 (Ruby) builds the cohort and writes the manifest; this directory is
Phase 2, the k6 side that reads it and hits the app's real routes.

| | |
|---|---|
| `lib/manifest.js` | Loads the manifest JSON once per run (via `SharedArray`, not per-VU) and hands out one team per VU. |
| `lib/auth.js` | Scrapes the CSRF token and logs a VU in through the real `/login` form. |
| `main.js` | Entry point. Currently login-only — Task 9 replaces it with the two-phase play loop. |

## Running

```bash
export PATH="$HOME/.local/bin:$PATH"   # k6 is installed here, not /usr/local/bin
bin/rails 'load_test:seed[1,5]'         # source_game_id, teams -- prints the manifest path it wrote
bin/rails server &

k6 run --env MANIFEST=/tmp/<cohort>.json --vus 2 --iterations 2 load_test/main.js
```

`--env BASE_URL` overrides the manifest's own `base_url` (useful for pointing
the same manifest at a different host without re-seeding). `--env PHASE` and
`--env RATE` are read by the two-phase runner Task 9 adds; `main.js` in its
current, login-only form does not use them.

**Never commit a manifest.** It carries live team passwords in plaintext.
Manifests are written to `/tmp` by the seeder and stay there.

## Why the CSRF token is cached, not re-scraped

Rails masks `authenticity_token` differently on every render but accepts any
valid unmasking for the session that issued it. `login()` in `lib/auth.js`
fetches it once per VU. Re-fetching before every POST would add a phantom GET
ahead of every write in the play loop Task 9 adds, which would distort the
read/write ratio the whole test exists to measure.

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
