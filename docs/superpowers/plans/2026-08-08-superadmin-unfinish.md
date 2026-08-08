# Superadmin Unfinish (Revive Ended Games) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin clear `author_finished_at` on an ended game from the admin games screen, mirroring the withdraw/restore pattern.

**Architecture:** One `update_column` model method (`Game#unfinish!`), one POST member route + superadmin-only controller action with an audit record, one `button_to` on the admin games index, locale keys in all four locales. Team passings are deliberately untouched (per-team repair is the existing `reinstate` intervention). Spec: `docs/superpowers/specs/2026-08-08-superadmin-unfinish-design.md`.

**Tech Stack:** Rails 8, RSpec request specs, sqlite test DB.

## Global Constraints

- Never edit `features/**/*.feature` files (acceptance contract; admin screens have no coverage there, so none of this work goes near them).
- Hash-rocket syntax (`:key => value`) in code that sits beside hash-rocket code; match surrounding style.
- Locale keys must be added to **all four** locale files (`config/locales/{ru,en,uk,ka}.yml`) to keep the documented key-set parity; `spec/i18n_spec.rb` enforces ru↔en exact parity.
- Run commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` (Ruby is not on PATH in non-login shells).
- Validation bypass in `unfinish!` is deliberate — use `update_column`, NOT `update!` (a game ended after its start date has a past `starts_at` that a validated save rejects).

---

### Task 1: `Game#unfinish!`, route, controller action, notice + audit locale keys

**Files:**
- Modify: `app/models/game.rb` (beside `restore!`, ~line 115)
- Modify: `config/routes.rb` (the games member block that has `post :withdraw` / `post :restore`, ~line 77)
- Modify: `app/controllers/games_controller.rb` (`withdraw`/`restore` neighborhood, ~line 107; also the `find_game` and `require_superadmin!` before_action lists at lines 7 and 15)
- Modify: `config/locales/ru.yml`, `config/locales/en.yml`, `config/locales/uk.yml`, `config/locales/ka.yml` (`games.unfinished_notice` beside `restored_notice` ~line 147 in ru; `admin.audit.action.unfinish` beside `admin.audit.action.restore` ~line 44 in ru)
- Test: create `spec/requests/unfinish_spec.rb`

**Interfaces:**
- Consumes: `create_user` / `create_game` / `create_level` / `create_game_passing` (spec/spec_helpers/fixtures_helper.rb), `Game#finish_game!`, `GamePassing#end!`, `record_admin_action` (app/controllers/concerns/admin_audit.rb).
- Produces: `Game#unfinish!` (clears `author_finished_at` via `update_column`), `unfinish_game_path(game)` (POST). Task 2's view button posts to this route.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/unfinish_spec.rb`:

```ruby
require "rails_helper"

# Superadmin revival of an ended game -- the reverse of end_game, mirroring
# withdraw/restore. Design: docs/superpowers/specs/
# 2026-08-08-superadmin-unfinish-design.md. Ending a game was a one-way door
# (nothing in the UI clears author_finished_at); production repair required a
# console write (game 4, 2026-08-08).
describe "reviving an ended game", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    g.finish_game!
    g
  end

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user sets the password to "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "can be revived by a superadmin, who is audited" do
    sign_in(superadmin)
    post unfinish_game_path(game)

    expect(game.reload.author_finished?).to be false
    expect(response).to redirect_to(admin_games_path)
    action = AdminAction.order(:id).last
    expect(action.action).to eq("unfinish")
    expect(action.target_id).to eq(game.id)
  end

  it "cannot be revived by its own author" do
    sign_in(author)
    post unfinish_game_path(game)
    expect(game.reload.author_finished?).to be true
  end

  it "cannot be revived by an anonymous visitor" do
    post unfinish_game_path(game)
    expect(game.reload.author_finished?).to be true
  end

  # Pins the design's out-of-scope decision: revival touches only the game.
  # Teams marked "ended" stay ended until an operator reinstates each one
  # through the existing intervention (GamePassing#reinstate!), which also
  # resets the level clock -- a blanket un-end here would skip that.
  it "leaves ended team passings ended" do
    passing = create_game_passing(:level => create_level(:game => game))
    passing.end!

    sign_in(superadmin)
    post unfinish_game_path(game)

    expect(passing.reload.status).to eq("ended")
  end
end
```

- [ ] **Step 2: Run it to verify it fails on the missing route**

Run: `bundle exec rspec spec/requests/unfinish_spec.rb`
Expected: 4 failures, `NoMethodError`/`NameError` for `unfinish_game_path` (route does not exist yet).

- [ ] **Step 3: Implement — model method, route, controller action, locale keys**

`app/models/game.rb`, directly after `restore!` (keep the `update_column` shape and add the why):

```ruby
  # The reverse of finish_game!, superadmin-only (see GamesController). Same
  # update_column shape as withdraw!/restore! -- deliberately unvalidated,
  # because game_starts_in_the_future and deadline_is_in_future are skipped
  # while author_finished_at is set, so a game ended after its start date
  # carries past dates a validated save would reject. For the "ended too
  # early, let it continue" case those past dates are correct, not stale.
  def unfinish!
    update_column(:author_finished_at, nil)
  end
```

`config/routes.rb`, in the games member block beside `post :withdraw` / `post :restore`:

```ruby
      post :unfinish
```

`app/controllers/games_controller.rb`:
- add `:unfinish` to the `before_action :find_game, only: [...]` list (line 7)
- add `:unfinish` to the `before_action :require_superadmin!, only: [:withdraw, :restore, :lock, :unlock]` list (line 15)
- add the action beside `restore` (~line 118):

```ruby
  def unfinish
    @game.unfinish!
    record_admin_action("unfinish", @game)
    redirect_to admin_games_path, :notice => t("games.unfinished_notice")
  end
```

Locale keys (place each beside its named neighbor):

`config/locales/ru.yml` — beside `restored_notice` (~line 147) and `admin.audit.action.restore` (~line 44):
```yaml
    unfinished_notice: "Игра возобновлена"
```
```yaml
          unfinish: "Возобновил игру"
```

`config/locales/en.yml` — same two spots:
```yaml
    unfinished_notice: "The game has been resumed"
```
```yaml
          unfinish: "Resumed the game"
```

`config/locales/uk.yml`:
```yaml
    unfinished_notice: "Гру відновлено"
```
```yaml
          unfinish: "Відновив гру"
```

`config/locales/ka.yml`:
```yaml
    unfinished_notice: "თამაში აღდგენილია"
```
```yaml
          unfinish: "აღადგინა თამაში"
```

- [ ] **Step 4: Run the spec to verify it passes, plus the i18n parity spec**

Run: `bundle exec rspec spec/requests/unfinish_spec.rb spec/i18n_spec.rb`
Expected: all pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/game.rb config/routes.rb app/controllers/games_controller.rb config/locales spec/requests/unfinish_spec.rb
git commit -m "Let a superadmin revive an ended game, mirroring withdraw/restore"
```

---

### Task 2: «Возобновить» button on the admin games screen

**Files:**
- Modify: `app/views/admin/games/index.html.erb` (the `game-control` div, ~line 50)
- Modify: `config/locales/ru.yml`, `en.yml`, `uk.yml`, `ka.yml` (`admin.games.index.unfinish` beside `admin.games.index.restore`, ~line 99 in ru)
- Test: extend `spec/requests/admin_console_spec.rb`

**Interfaces:**
- Consumes: `unfinish_game_path(game)` from Task 1; `Game#author_finished?`.
- Produces: nothing downstream — terminal UI task.

- [ ] **Step 1: Write the failing test**

Add to `spec/requests/admin_console_spec.rb`, after the "offers withdrawal but not deletion" example (~line 76), reusing the file's existing `author`/`superadmin` lets and `sign_in` helper:

```ruby
  # The unfinish button is the only UI door out of the "Завершена" state
  # (everything else about that state is one-way -- see
  # docs/superpowers/specs/2026-08-08-superadmin-unfinish-design.md), so its
  # visibility is part of the feature: present exactly on finished games.
  it "offers revival for a finished game and not for a running one" do
    finished = create_game(:author => author, :is_draft => false)
    finished.finish_game!
    running = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)

    get admin_games_path

    expect(response.body).to include(unfinish_game_path(finished))
    expect(response.body).not_to include(unfinish_game_path(running))
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/admin_console_spec.rb`
Expected: the new example fails (`response.body` does not include the unfinish path — button not rendered); every other example still passes.

- [ ] **Step 3: Render the button**

`app/views/admin/games/index.html.erb`, inside `<div class="game-control">`, after the withdraw/restore `if/else` block:

```erb
          <% if game.author_finished? %>
            <%= button_to t("admin.games.index.unfinish"), unfinish_game_path(game), :method => :post, :class => "btn" %>
          <% end %>
```

(Independent of the withdraw/restore toggle — withdrawal and author-finish are separate facts, and a withdrawn-and-finished game legitimately shows both buttons.)

Locale keys, beside `admin.games.index.restore` in each file:

`ru.yml`: `unfinish: "Возобновить"`
`en.yml`: `unfinish: "Resume"`
`uk.yml`: `unfinish: "Відновити"`
`ka.yml`: `unfinish: "აღდგენა"`

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bundle exec rspec spec/requests/admin_console_spec.rb spec/i18n_spec.rb`
Expected: all pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/views/admin/games/index.html.erb config/locales spec/requests/admin_console_spec.rb
git commit -m "Offer the revival button on the admin games screen"
```

---

### Task 3: Full verification and PR

**Files:** none new — verification only.

**Interfaces:**
- Consumes: everything above.
- Produces: the pull request.

- [ ] **Step 1: Full RSpec suite**

Run: `bundle exec rspec`
Expected: 0 failures (baseline on merged master was 884 examples / 6 pending; this branch adds 5 examples → 889).

- [ ] **Step 2: Full Cucumber suite**

Run: `bundle exec cucumber`
Expected: 234 scenarios, 0 failures (232 passed + 2 pre-existing undefined placeholders). No `.feature` file was touched — verify with `git diff origin/master --stat -- features/` printing nothing.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feature/superadmin-unfinish
gh pr create --base master --title "Let a superadmin revive an ended game" --body "<summary per repo convention: problem, pattern mirrored, out-of-scope note on team passings, verification numbers; footer: 🤖 Generated with [Claude Code](https://claude.com/claude-code)>"
```
