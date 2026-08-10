# An operator entries console, and run-scoped logs with pagination — design

**Date:** 2026-08-10. **Decided by:** repository owner (`mezinster`), in session.

Two independent additions, specified together because they were commissioned together. They share no
file and can be implemented, reviewed and merged in either order.

1. **An entries console for the superadmin.** Opening a run is an operator power, but populating it
   is not — so today an operator who reruns a game cannot admit anyone without borrowing authorship.
2. **Run-scoped log screens, with pagination.** The §9 deferral from phase 3, plus the performance
   work the request implies.

Both follow the game-runs programme (specs of 2026-08-10, phases 1–3), all merged and deployed.

## 0. Why now

**The entries gap was hit in real use.** On 2026-08-10 a second run of «Викторина» was opened from the
console and a team registered for it. The operator could open the run but had no screen on which to
accept the application: `GameEntriesController#accept` is behind `ensure_author`, which *does* admit
superadmins, but `games/show.html.erb:47` gates the entries block on
`@current_user.author_of?(@game)`, which does **not**. So the action is permitted and the button is
never rendered. The only routes were to transfer authorship to oneself and back, or to edit the
database.

**The log gap is the phase 3 §9 deferral**, plus a defect found while designing this: the full log
issues one query per level × team cell.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| D1 | Where does the operator admit teams? | **A screen per game**, `/admin/games/:game_id/entries`. The console row gets one link with a pending count. |
| D2 | Which log screens gain pagination? | **The full log and the live channel.** The two per-team screens are left alone. |
| D3 | Gem or hand-rolled pagination? | **Hand-rolled** — one helper, one partial, no new dependency. |

### Why D1

The console row already carries **ten** controls (edit, withdraw/restore, unfinish, lock/unlock,
delete, plus the set-author and open-run forms). An entries list inline would grow one line per
applicant, and the console exists to be scanned at a glance.

Making `games/show`'s gate superadmin-aware was the one-line alternative. Rejected: it also exposes
edit, delete and hand-over on that page, which is a wider behaviour change than it looks, and it puts
an operator action on a player-facing screen.

### Why D2

The four screens have different shapes, and only two grow:

- **full log** — a matrix, `@levels` as rows × `@teams` as columns. Its rows are levels, so paging it
  means paging levels.
- **live channel** — a flat list, and the one whose length tracks how busy a game is.
- **game log** (one team, one game) and **level log** (one team, one level) do not grow enough to
  page. Paging them would add controls to screens that only ever have one page.

### Why D3

Two screens do not justify a dependency, and this codebase deliberately hand-rolls small things and
records why — the countdown plural rules and `AnsweredQuestionsCoder` are both precedents. The full
log also pages **levels**, not the log rows themselves, which sits awkwardly on a gem's idiom.

---

# Part A — the entries console

## A1. Routes and controller

```
GET  /admin/games/:game_id/entries                the screen
POST /admin/games/:game_id/entries/:id/accept
POST /admin/games/:game_id/entries/:id/reject
```

Nested under the game deliberately: `free_place_of_team!` is a method on `Game`, and the redirect
target is this screen, so both need the game in scope regardless.

`Admin::GameEntriesController`, filtered by `require_authentication!` then `require_superadmin!` —
the same pair `Admin::GamesController` uses.

## A2. What the screen shows

The **current run's** entries only, with the run named («Забег №2 — 10 августа 2026») so an operator
cannot mistake which cohort they are admitting to. Pending (`new`) and accepted are listed
separately; each pending row carries accept and reject.

Admitting to a run that is not the current one is not offered, because nothing else in the
application can address a non-current run for admission either.

## A3. Accept and reject mirror the author's own actions

Copied from `GameEntriesController`, guards included:

```ruby
def accept
  @entry.accept! if @entry.status == "new"
end

def reject
  if @entry.status == "new"
    @entry.reject!
    @game.free_place_of_team!
  end
end
```

**The `if @entry.status == "new"` guard on reject is load-bearing and must be copied, not
simplified.** Its comment in `GameEntriesController` records the failure: `free_place_of_team!`
firing unconditionally lets a double-clicked reject free a place that is not that entry's to free,
and the counter then drifts below what is actually taken, letting one extra team past
`max_team_number`. Production saw this with a captain double-clicking «Отозвать».

Both actions are audited — `accept_entry` and `reject_entry`, with the team's name in `details` —
because this is an operator acting on someone else's game. Both need a label under
`admin.audit.index.action.*` in all seven locales: the audit view falls back to the raw identifier,
so a missing label fails nowhere.

## A4. The console link

One link per row, «Заявки (N)», N being the pending count for that game's current run.

Counted in **one grouped query for the whole page**, not one per row. The console's own history makes
this non-negotiable: it shipped with a per-row `COUNT`, and the fix is recorded in
`Admin::GamesController#index`'s comment as "the one query pattern a screen that lists *everything*
can least afford".

---

# Part B — run-scoped logs with pagination

## B1. All four screens take a run

`?run=<ordinal>`, resolved and falling back exactly as the results page does: unknown or malformed
lands on the default rather than 404ing.

**No started-run guard applies here.** The log screens are gated by `ensure_author` and
`ensure_full_log_access`, not by `ensure_game_is_started`, so the defect fixed this morning — a
switcher offering a link the guard refuses — cannot recur on these screens. Whatever run link they
show is one they will serve.

## B2. The full log's N+1

`show_full_log.html.erb` renders `@levels.each` × `@teams.each` and calls
`@logs.of_team(team).of_level(level)` in each cell. `@logs` is an **unloaded relation**, so that is
one query per cell — for «Викторина» as it stands, 77 levels × 3 teams ≈ **231 queries** on one page.

Fixed by loading `@logs` once and grouping in Ruby on `[team_id, level_id]`. That is ~231 → ~3, and
it stops scaling with levels × teams.

This is a defect that exists today, independent of runs; it is fixed here because this is the phase
that touches the screen.

## B3. Pagination

```ruby
# app/helpers/pagination_helper.rb
page_of(scope, page_param, :per => 20)   # => [records, current_page, total_pages]
```

Clamps the requested page into `1..total_pages`, so no `?page=` can produce an empty table or a 500 —
the same forgiving rule `?run=` follows. Clamping is directional and both directions are deliberate:
a page **beyond the end** lands on the **last** page, because someone asking for the end should get
it; a **zero, negative or malformed** page lands on the **first**, because `"не-число".to_i` is 0 and
there is nothing better to mean.

| Screen | Paged over | Per page |
|---|---|---|
| full log | **levels** (its rows) | 20 |
| live channel | logs, **newest first** | 50 |
| game log | not paged | — |
| level log | not paged | — |

The full log pages levels **in their existing order** — `Level.of_game(@game)`, which `Level`
`acts_as_list` keeps ordered by `position`. Page 1 is levels 1–20, and the page contents are
therefore stable rather than arbitrary.

The live channel's ordering moves into SQL as `order(:time => :desc)`. **That is the order it
already renders**, verified rather than assumed: its comparator returns `1` when
`left.time <= right.time`, which sorts newest first. Worth stating, because reversing it would
silently change a page `features/logs/log.feature` renders — and equal timestamps are ordered
arbitrarily under both the old comparator and the new SQL, so nothing there changes either.

Moving that sort into SQL is also what lets the live channel stop loading every log for the run,
which is the part that hurts first on a busy game.

Paging the full log by level also shrinks its remaining query: only that page's levels' logs are
loaded.

Three locale keys × seven files: «Назад», «Далее», «%{current} из %{total}».

## B4. The pager renders nothing on a single page

`features/logs/log.feature` drives the full log (`:105`) and a finished player's access to it
(`:113`). **The pager must emit no markup at all when `total_pages <= 1`** — exactly as the run
switcher emits nothing for a single-run game.

This is stated as a requirement rather than left to taste because the equivalent rule has already
been broken once in this programme: the run switcher linked a run its own guard refused, and only a
real production run surfaced it.

---

## Testing

**Entries console**

- accepting moves the entry to `accepted`, and the team can then play that run;
- rejecting frees a place, and **a second reject does not free another** — the production bug A3's
  guard exists for, asserted directly rather than trusted to the copied code;
- a non-superadmin is refused;
- each action writes exactly one audit row, and the log renders a sentence rather than the raw action
  name (asserted by the identifier being **absent**, since the view falls back to it);
- the screen lists only the **current run's** entries, proved by building a second run;
- the console's pending count is correct **and adds no query per game** — a count-based guard, the
  same shape `spec/requests/admin_console_spec.rb` already uses.

**Logs**

- `?run=1` shows run 1's answers after run 2 exists; an unknown ordinal falls back;
- **the full log's query count does not grow with the number of levels** — this is the example that
  actually pins B2, and a count-based guard is the only way to assert it;
- the live channel returns newest first;
- the pager appears once there are two pages and **not before**;
- a `?page=` beyond the end renders the **last** page, and a malformed one renders the **first**.

**Both**

- **Cucumber must stay at exactly 232 scenarios / 2342 steps.** The log screens are frozen-scenario
  territory.
- No locale key is removed; the new ones exist in all seven files.

## Frozen acceptance surface

No `features/**/*.feature` file is edited. The log screens are driven by `features/logs/log.feature`
and `features/games/game_full_log.feature`; every change here is either invisible on a single page
(the pager), invisible on a single-run game (the run parameter), or behind the admin console (the
entries screen).

## Out of scope

No pagination on the game log or level log. No pagination gem. No change to who may see a log —
`ensure_full_log_access` and `ensure_author` are untouched. The entries console admits to the current
run only. Nothing here drops the eight stale `games` columns; that remains its own separate change.
