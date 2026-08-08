# Superadmin revival of ended games ("unfinish")

Date: 2026-08-08. Approved by the repository owner in session (design presented and
accepted; superadmin-only scope chosen explicitly).

## Problem

Ending a game (`GamesController#end_game`) stamps `games.author_finished_at` and is a
one-way door: nothing in the UI can clear that timestamp. Until PR #34 the stamp could
even be acquired by accident during a test run; the accident path is now guarded, but a
deliberate ending remains irreversible except by a console write against production —
which is exactly what had to be done for game 4 on 2026-08-08. The repository owner has
decided to add a revival capability, restricted to superadmins.

## Decision

Mirror the existing `withdraw!`/`restore!` pair — the codebase's established pattern for
a reversible, superadmin-only, audited lifecycle flag — as closely as possible.

### Model

`Game#unfinish!` → `update_column(:author_finished_at, nil)`, defined beside
`restore!`/`unlock_editing!`. The validation bypass is deliberate and matches those
methods: `game_starts_in_the_future` and `deadline_is_in_future` are skipped while
`author_finished_at` is set, so a game ended after its start date carries past dates
that a validated save would reject. Revival must not 422 on them — for the legitimate
"author ended the game too early, let it continue" case the past date is *correct*.

### Controller and route

- `post :unfinish` member route on games, beside `withdraw`/`restore`.
- `GamesController#unfinish`: `@game.unfinish!`, `record_admin_action("unfinish", @game)`,
  redirect to `admin_games_path` with `t("games.unfinished_notice")`.
- Added to the `find_game` and `require_superadmin!` before_action lists.

### Admin UI

In `app/views/admin/games/index.html.erb`'s `game-control` cell: a
«Возобновить» `button_to` (POST), rendered whenever `game.author_finished?`.
Independent of the withdraw/restore toggle — withdrawal and author-finish are separate
facts, and a withdrawn-and-finished game legitimately shows both buttons.

### i18n

New keys in all four locales (`ru`, `en`, `uk`, `ka` — keeping the documented key-set
parity):

- `admin.games.index.unfinish` — button label («Возобновить» / "Resume")
- `games.unfinished_notice` — flash after revival
- `admin.audit.action.unfinish` — audit-log label («Возобновил игру» / "Resumed the game")

### Deliberately out of scope

- **Team passings are untouched.** `end_game` marks non-exited passings
  `status: "ended"`; revival leaves them that way. Per-team repair already exists as the
  `reinstate` operator intervention (`GamePassing#reinstate!`), which clears the status
  *and* resets the level-entry clock so hints stay fair. A blanket un-end here would
  guess wrong for teams ended for other reasons and would contradict the interventions
  philosophy (per-record repair, no bulk state editor).
- **No author-facing flow.** Revival is incident repair, not a product feature.
- **No date handling.** A revived past-dated game immediately reports "running"; that is
  correct for the ended-too-early case and harmless otherwise, since ended passings
  cannot play until reinstated.

### Consequences worth knowing

- Reviving a past-dated game makes it count as running everywhere (`Game#status`,
  `count_by_status`, public listings).
- The acceptance contract is untouched: admin screens have no `.feature` coverage.

## Tests

Mirroring `spec/requests/withdrawal_spec.rb` ("can be withdrawn and restored by a
superadmin" and friends) and `spec/requests/admin_audit_spec.rb`:

1. A superadmin POSTing `unfinish` on a finished game clears `author_finished?`,
   redirects to the admin games list (request spec).
2. The game's author (non-superadmin) is refused and the game stays finished.
3. The action is recorded in the admin audit log with the `unfinish` label.
4. Team passings marked `ended` stay `ended` after revival (pins the out-of-scope
   decision).
5. Admin games index renders the unfinish button for a finished game and not for an
   unfinished one (wherever the existing admin index examples live).
