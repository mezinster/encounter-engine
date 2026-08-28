# Data Exposure Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the per-game answer log rendering another game's submissions, and stop the restore
script putting the production database password on a command line where every local process can read
it.

**Architecture:** Two unrelated one-line-ish fixes that share a theme — data crossing a boundary it
was never meant to. They are in one plan because neither justifies its own, and they can be
implemented and reviewed in either order. Task 1 is application code with a test-suite consequence
that must be handled carefully; Task 2 is an ops script with a rehearsal to run.

**Tech Stack:** Rails 8.0 ERB views, ActiveRecord scopes, Cucumber; Bash, Docker, wal-g.

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every shell command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/`** ending in `.feature`. `features/support/env.rb` is a
  support file, not a scenario file, and **is** editable — Task 1 requires changing a comment in it.
- Capture a green baseline with `bundle exec rspec` and `bundle exec cucumber` before starting.
- Hash rockets (`:key => value`) throughout. Match the surrounding file.

---

## File Structure

**Modified:**
- `app/views/logs/show_game_log.html.erb:7` — use the controller's scoped collection.
- `features/support/env.rb:72-78` — a comment that documents the bug being fixed as load-bearing.
- `ops/db-restore-scratch.sh:40, 74` — delete two lines.

**Created:**
- `spec/requests/game_log_scope_spec.rb`

---

### Task 1: Scope the per-game answer log to its own game and team

**Files:**
- Modify: `app/views/logs/show_game_log.html.erb:7`
- Modify: `features/support/env.rb:72-78` (comment only)
- Test: `spec/requests/game_log_scope_spec.rb` (create)

**Interfaces:**
- Consumes: `@logs`, already built correctly by `LogsController#show_game_log`
  (`app/controllers/logs_controller.rb:39-41`) as `Log.of_game(@game).of_team(@team)`.
- Produces: nothing consumed elsewhere.

**Background:** the view discards `@logs` and re-queries inside the level loop:

```erb
<% logs = Log.of_game(level) %>
```

`Log.of_game` is `->(game) { where(game_id: game) }` (`app/models/log.rb:5`), and Rails resolves an
ActiveRecord object passed to a `where` hash by its `id`. Passing a **Level** therefore compiles to
`WHERE game_id = <level.id>` — the log of whatever *game* happens to share that integer, for all
teams. Verified by printing the generated SQL: `Log.of_game(<Level id=42>).to_sql` produces
`SELECT "logs".* FROM "logs" WHERE "logs"."game_id" = 42`, identical to passing `Game id=42`.

An author viewing their own game's log therefore sees, for each of their levels *L*, every
submission from the game whose id equals *L.id* — and submissions include correct codes. It also
silently drops the team filter for the author's *own* game, so the page titled "team X's log" shows
every team's rows.

Severity is tempered by the fact that only `time` and `answer` are rendered — not team, not level —
so the leak is an unattributed pile of strings, and steering it at a chosen victim requires an id
collision the attacker can only partly force. It fires naturally, though: the Cucumber suite depends
on exactly such a collision today.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/game_log_scope_spec.rb`:

```ruby
require "rails_helper"

# app/views/logs/show_game_log.html.erb passed a Level to Log.of_game, whose
# scope is where(game_id: game) -- Rails resolves an AR object by #id, so a
# Level resolved to where(game_id: <level.id>), rendering the log of whatever
# GAME shared that integer, unfiltered by team.
describe "the per-game answer log", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.update_column(:starts_at, 1.hour.ago)
    g
  end
  let!(:level)  { create_level(:game => game) }
  let(:team)    { create_team(:captain => create_user) }

  before do
    put login_path, :params => { :email => author.email, :password => "1234" }
  end

  it "shows this team's submissions on this game" do
    Log.create!(:game_id => game.id, :level => level.name, :team => team.name,
                :time => Time.now, :answer => "МОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("МОЙ-КОД")
  end

  it "does not show submissions whose game id merely equals a level id" do
    Log.create!(:game_id => level.id, :level => level.name, :team => team.name,
                :time => Time.now, :answer => "ЧУЖОЙ-КОД")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖОЙ-КОД")
  end

  it "does not show another team's submissions on this game" do
    other = create_team(:captain => create_user)
    Log.create!(:game_id => game.id, :level => level.name, :team => other.name,
                :time => Time.now, :answer => "ЧУЖАЯ-КОМАНДА")

    get show_game_log_path(:game_id => game.id, :team_id => team.id)

    expect(response.body).not_to include("ЧУЖАЯ-КОМАНДА")
  end
end
```

Note the second example deliberately writes a `Log` row whose `game_id` equals `level.id`. If those
two integers happen to be equal in your test database, the example is meaningless — check that
`game.id != level.id` while writing it, and if the fixture ordering makes them collide, create a
throwaway game first to advance the counter.

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_log_scope_spec.rb
```

Expected: 3 examples, 2 failures — the foreign rows both render.

- [ ] **Step 3: Fix the view**

`app/views/logs/show_game_log.html.erb:7`, currently:

```erb
  <% logs = Log.of_game(level) %>
```

becomes:

```erb
  <%# @logs is already Log.of_game(@game).of_team(@team) -- see
      LogsController#show_game_log. This used to re-query with Log.of_game(level),
      and because that scope is where(game_id: game) and Rails resolves an AR
      object by #id, passing a Level rendered the log of whatever GAME shared
      that integer, for every team. %>
  <% logs = @logs.of_level(level) %>
```

`Log.of_level` (`app/models/log.rb:7`) is `where(level: level.name)`, matching what
`GamePassingsController#save_log` writes.

- [ ] **Step 4: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_log_scope_spec.rb
```

Expected: 3 examples, 0 failures.

- [ ] **Step 5: Run the log feature — this is the risky step, read it before running**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber features/logs
```

`features/support/env.rb:72-78` records that `features/logs/log.feature:53-82` **passes only because
game id 1 and level id 1 coincide** under the current buggy scoping. Correct scoping returns the
rows the scenario actually intends, so it is expected to keep passing — but if it does **not**:

**Stop. Do not edit the feature file.** Report the failure with the scenario name and the diff
between expected and actual rows. A red `log.feature` means either the fix is wrong or the scenario
encodes an expectation nobody has looked at in years; both are decisions for the repository owner,
not for this task.

- [ ] **Step 6: Update the now-stale comment in `features/support/env.rb`**

The identity-counter reset must stay — it has a second, independent justification (the
"Подать заявку на регистрацию" first-link problem, described immediately above it in the same
comment). Only the `log.feature` clause is stale. Replace the second paragraph
(`features/support/env.rb:72-78`) with:

```ruby
# The identity counters have to go too, not just the rows: Rails declares
# SQLite primary keys AUTOINCREMENT, so a leftover counter would stop the first
# game of a scenario from getting id 1, and the first-link behaviour above
# depends on a clean, predictable ordering. (This block used to carry a second
# reason: features/logs/log.feature:53-82 passed only because game id 1 and
# level id 1 coincided, because app/views/logs/show_game_log.html.erb passed a
# Level to Log.of_game. That scoping bug is fixed -- the view now uses the
# controller's @logs scoped by level -- so the scenario no longer depends on an
# id collision.)
```

- [ ] **Step 7: Run both full suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: baseline plus 3 new examples.

- [ ] **Step 8: Commit**

```bash
git add app/views/logs/show_game_log.html.erb features/support/env.rb spec/requests/game_log_scope_spec.rb
git commit -m "Scope the per-game answer log to its own game and team

The view discarded the controller's scoped @logs and re-queried with
Log.of_game(level). That scope is where(game_id: game), and Rails resolves an
AR object by #id, so passing a Level rendered the log of whatever GAME shared
that integer -- every team's submissions, including correct codes. It also
dropped the team filter for the author's own game."
```

---

### Task 2: Keep the production database password out of `argv`

**Files:**
- Modify: `ops/db-restore-scratch.sh` — delete lines 40 and 74

**Background:** the script lifts the live Postgres password out of the running production container
(`POSTGRES_PASSWORD=$(env_of POSTGRES_PASSWORD)`, line 40) and passes it as
`-e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"` on a `docker run` command line (line 74). On Linux
`/proc/<pid>/cmdline` is world-readable, while `/proc/<pid>/environ` is owner-only — that asymmetry
is the entire finding. The password already lives in the container's environment, where it is
reachable only through the docker socket or a 0400 file; putting it in `argv` widens the readership
to every local UID for the duration of the call.

The host is explicitly multi-tenant — `ansible/playbook.yml:2-4` says *"This host is in production
use for other things, and this app is one tenant on it rather than its owner."* — and Postgres
binds `127.0.0.1:5432`
(`config/deploy.yml:71`), so a captured password is directly usable from the same machine.

Realistic severity is **low**: the deploy user is already docker-group/root-equivalent and gains
nothing, so the only principal who benefits is a compromised network-facing co-tenant daemon
escalating from service-account RCE to full production database access. The window is about a
second per invocation. It is still a one-line fix with no downside.

**The `-e` is provably not load-bearing.** Three independent confirmations:
- `docs/runbooks/restore.md:169-176` performs the identical operation — same image, same
  `--entrypoint sleep ... infinity`, same `PGUSER`/`PGDATABASE`/`WALG_AZ_PREFIX`/
  `AZURE_STORAGE_ACCOUNT` — and passes no `POSTGRES_PASSWORD` at all.
- `ops/db-list.sh:18` runs wal-g against production with no password.
- `--entrypoint sleep` (line 77) bypasses `docker-entrypoint.sh`, so `initdb` — the only consumer of
  `POSTGRES_PASSWORD` in the official Postgres image — never runs. The later `psql` calls (lines 163
  and 174) go through `docker exec -u postgres ... psql -U encounter`, i.e. the local socket as unix
  user `postgres`, where libpq reads `PGPASSWORD` and never `POSTGRES_PASSWORD`.

- [ ] **Step 1: Confirm nothing else in the script reads the variable**

```bash
grep -n "POSTGRES_PASSWORD\|PGPASSWORD" ops/db-restore-scratch.sh ops/db-list.sh ops/host/* docs/runbooks/restore.md
```

Expected: hits only on `ops/db-restore-scratch.sh:40` and `:74`. **If any other line reads it, stop
and re-plan** — the fix would then be an `--env-file` on a `mktemp`ed 0600 file removed by the
script's existing `cleanup` trap, not a deletion.

- [ ] **Step 2: Delete the two lines**

Remove `ops/db-restore-scratch.sh:40`:

```bash
POSTGRES_PASSWORD=$(env_of POSTGRES_PASSWORD)
```

and `ops/db-restore-scratch.sh:74`:

```bash
  -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
```

Take care with the line continuations: line 74 sits inside the `docker run -d --name "$SCRATCH" \`
block that runs from line 71 to line 77. After deleting line 74, every remaining line of that block
except the last must still end in a backslash, and the last (`--entrypoint sleep "$IMAGE" infinity
>/dev/null`) must not.

Add a comment where line 40 was, so nobody helpfully restores it:

```bash
# POSTGRES_PASSWORD is deliberately NOT read or passed: --entrypoint sleep below
# skips initdb, which is its only consumer, and the psql calls later go over the
# local socket as unix user postgres. Passing it on the docker run command line
# published the production password to every local UID via /proc/<pid>/cmdline
# for the life of the call, on a host we share with other tenants
# (ansible/playbook.yml:2-4).
```

- [ ] **Step 3: Shell-check the script**

```bash
bash -n ops/db-restore-scratch.sh
```

Expected: no output. If `shellcheck` is available, run it too and compare against the pre-change
output rather than expecting zero findings.

- [ ] **Step 4: Rehearse the restore — required**

This script is the disaster-recovery path; a syntax-clean script that no longer restores is worse
than the finding it fixes. Run the rehearsal exactly as `docs/runbooks/restore.md` describes, against
the scratch container, and confirm:

- the base backup is fetched and `pg_is_in_recovery()` reaches `f` (the promotion check at line 163),
- the row-count sanity queries at line 174 and after return real numbers, not `?`,
- the cleanup trap removes the scratch container.

Record the rehearsal result in the runbook as the runbook itself instructs.

- [ ] **Step 5: Commit**

```bash
git add ops/db-restore-scratch.sh
git commit -m "Stop passing the production DB password on a docker run command line

/proc/<pid>/cmdline is world-readable while /proc/<pid>/environ is not, so this
published the password to every local UID on a host we share with other
tenants. The variable was never consumed: --entrypoint sleep skips initdb, and
the psql calls go over the local socket as unix user postgres. The runbook's
equivalent invocation already omits it."
```

---

## Definition of done

- Both suites green at baseline plus 3 new examples.
- `features/logs/log.feature` passes **without** any edit to the feature file.
- The stale `log.feature` justification is gone from `features/support/env.rb`, and the
  identity-counter reset it also justified is still in place.
- `grep POSTGRES_PASSWORD ops/db-restore-scratch.sh` returns only the explanatory comment.
- The restore rehearsal has actually been run and recorded, not assumed.
