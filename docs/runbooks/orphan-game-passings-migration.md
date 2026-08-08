# Migration: deleting orphan `game_passings` rows

`db/migrate/20260807103000_delete_orphan_game_passings.rb` — runs automatically on the next
deploy (`bin/docker-entrypoint` calls `bin/rails db:prepare` on every puma boot), no manual step
required.

## What it does

Deletes every row in `game_passings` where `team_id IS NULL`, and logs the count it removed
(`say "deleted N orphan game_passings row(s) with team_id NULL"`, visible in the deploy log).

## Why these rows exist

`GamePassingsController#find_or_create_game_passing` runs ahead of `ensure_team_member` in the
filter chain, and always has — that ordering was never the guard against this. Before the
2026-08-07 gameplay access-control remediation, a request from a logged-in user who was on no team
could still reach `GamePassing.create!` and get a row with `team_id` NULL before `ensure_team_member`
ever ran. That path is now closed by an explicit nil check: `may_start_passing?` (also in
`app/controllers/game_passings_controller.rb`) starts with `return false if @team.nil?`, so
`find_or_create_game_passing` raises `Authentication::Unauthorized` instead of reaching
`GamePassing.create!`. No running code can produce a new orphan row.

## Why they need to go, not just sit there

They are not dormant:

- `game_passings/index.html.erb` (the author's stats page) dereferences `game_passing.team.name`
  unconditionally, so any orphan permanently 500s that page for its game.
- `GamesController#end_game` calls `.end!` over every passing for the game, orphans included,
  stamping `status = "ended"` on them too. `show_results.html.erb` — the **public,
  unauthenticated** results page — makes the same `team.name` dereference. One orphan row breaks a
  page anyone on the internet can hit, permanently, with no UI able to remove it.

## Why deleting is safe

The data cannot be recreated by design (the writing code path is gone), so there is nothing "in
progress" to lose and nothing a later feature could need to read back. This is why the migration
deletes outright rather than soft-flagging the rows — the usual objection to a destructive
migration (irrecoverable state that might still be needed) does not apply to rows nothing can
produce and nothing renders.

## If this needs undoing anyway

The migration's `down` deliberately raises `ActiveRecord::IrreversibleMigration` rather than
faking a rollback — there is no data to restore from within the app. The actual rollback path is
`docs/runbooks/restore.md`: a WAL-based point-in-time restore to just before this migration ran.
