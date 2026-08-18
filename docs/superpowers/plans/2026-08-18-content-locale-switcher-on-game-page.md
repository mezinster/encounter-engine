# Content-Language Switcher on the Game Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a signed-in reader change (and see) which language a game's authored content is rendered in from the game page itself, so a per-game content-language choice made on the play screen is no longer a one-way door.

**Architecture:** The write that persists `GameLocalePreference` moves into `ContentLocaleSelection` as `#store_content_locale`, and a second, additive entry point — `GamesController#set_content_locale`, guarded by exactly the same visibility filters as `#show` — calls it and redirects back to the game page. The existing play-screen route keeps its own action, its own play-time guards and its own redirect; only its body shrinks to a call to the shared method. `shared/_content_language_switcher` gains an optional `:switch_path` local so both screens render one partial pointed at their own route.

**Tech Stack:** Rails 8, RSpec (request + view specs), plain ERB, no Turbo/rails-ujs (so every control is a real `button_to` form).

**Spec:** No separate design doc — the problem, the evidence and the rejected alternative are in **Background** below. This plan is the spec.

## Background — what is broken, and the evidence

On 2026-08-18 the repository owner opened `/games/6` with profile language and UI language both English and read a Turkish title and description.

Production data (read-only queries against `encounter-engine-db`) shows the content itself is intact:

```
games:               id=6  name="5 следов (Веб-квест)"  primary_locale=ru  available_locales=ru,en,tr,be
content_translations for Game 6: name/description present and correct in be, en, tr
                     name.en = "5 Traces (Web Quest)"     name.tr = "5 iz (Web görevi)"
game_locale_preferences:
  id=2  user_id=1 (Evgeny)          game_id=6  locale=tr  created 2026-08-16 11:19  updated 2026-08-17 11:10
  id=3  user_id=7 (Dragon_Stupka)   game_id=6  locale=tr
  id=5  user_id=12 (Ирек)           game_id=6  locale=ru
```

`ContentLocaleSelection#content_locale_for` (`app/controllers/concerns/content_locale_selection.rb:25`) reads the stored per-game preference **before** the chrome locale:

```ruby
candidate = per_game_content_locale(game) || current_content_user_locale
```

That precedence is deliberate (see the class comment in `app/models/game_locale_preference.rb`: a player switching device mid-race keeps their language). **The defect is reachability, not precedence:** the only writer is `GamePassingsController#set_content_locale` (`:186`), which sits behind that controller's full filter stack — `require_authentication!`, `find_team`, `ensure_game_is_started`, `ensure_game_not_finished_by_author`, `ensure_team_member` — and redirects to `show_current_level_path`. The only place the switcher is rendered is `game_passings/show_current_level.html.erb:63`.

So the preference **applies** on `games#show` for a stopped draft, while it can only be **changed** from inside a running game by someone on a team in it. Stop the game and the reader is trapped in whichever language they last previewed, with nothing on the page saying so.

Level names on that page still render Russian because `app/views/levels/_list.html.erb:4` prints `level.name` — the raw column — rather than `translated()`. That is out of scope here; it is why the page looks half-switched, not why it is Turkish.

**Alternative considered and rejected:** make `games#show` ignore the per-game preference and follow the chrome locale. Smaller, but it splits the two screens — the game page and the play screen would show the same game in different languages, and the mid-race stickiness that the preference exists for would silently not apply where an author checks their work.

**Not in scope:** clearing the three existing production rows. That is a post-deploy operational step (see the end of this plan), and it needs the owner's go-ahead because it writes to production.

## Global Constraints

- **No `.feature` file is created, edited or deleted by this plan.** The inherited contract stays at 228 scenarios / 2325 steps; the whole suite stays at 238 / 2386. Coverage here is RSpec only.
- **No new i18n keys.** The switcher's label reuses `game_passings.content_language`, which is present in all seven locale files (verified: `ru en uk ka tr be pl`). Adding a key would mean writing it seven times.
- **No new CSS.** `.content-language-switcher`, `.language-choice` and `form.button_to { display: inline-block }` already exist in `public/stylesheets/screens.css:262-276` and `:583`, so the buttons sit inline on both screens.
- Hash-rocket syntax (`:key => value`) throughout — match the surrounding files.
- Comments and identifiers in English; user-facing strings via `t()`.
- Ruby is not on `PATH` in non-login shells. Every command below assumes:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Work in a git worktree.** Another session shares this checkout; a branch switch here orphans its commits. Use `superpowers:using-git-worktrees`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `app/controllers/concerns/content_locale_selection.rb` | Resolves *and now persists* the per-game content locale | Modify: add `#store_content_locale` |
| `app/controllers/game_passings_controller.rb:186-193` | Play-screen switcher endpoint (play-time guards, redirects into the game) | Modify: body delegates to the concern |
| `app/controllers/games_controller.rb:5-19, action list` | Game-page switcher endpoint (same visibility guards as `#show`) | Modify: new action + filter lists |
| `config/routes.rb` (`resources :games do member do`) | `POST /games/:id/set_content_locale` | Modify: one member route |
| `app/views/shared/_content_language_switcher.html.erb` | The switcher markup, now reusable from two screens | Modify: optional `:switch_path` local |
| `app/views/games/show.html.erb` | Game page — renders the switcher for signed-in readers | Modify: one render |
| `spec/requests/game_content_locale_switch_spec.rb` | HTTP-level behaviour of the new endpoint, incl. the regression | Create |
| `spec/views/games_spec.rb` (`"games/show"` block, from `:240`) | Switcher shown / hidden in the right cases | Modify: three examples |

---

### Task 1: Persist a content-language choice from outside the play screen

**Files:**
- Modify: `app/controllers/concerns/content_locale_selection.rb`
- Modify: `app/controllers/game_passings_controller.rb:186-193`
- Modify: `app/controllers/games_controller.rb:7-11` (filter `only:` lists) and the public action list
- Modify: `config/routes.rb:124-136` (the `resources :games` member block)
- Test: `spec/requests/game_content_locale_switch_spec.rb` (create)

**Interfaces:**
- Consumes: `GameLocalePreference` (`user_id`, `game_id`, `locale`); `Game#available_locale_list -> Array<String>`; `ContentLocaleSelection#content_locale_for`.
- Produces:
  - `ContentLocaleSelection#store_content_locale(game, locale) -> true | false` — private controller method, writes the row for `current_user`, returns `false` (writing nothing) for a guest or a locale the game does not offer.
  - Route helper `set_content_locale_game_path(game, :locale => "en")` → `POST /games/:id/set_content_locale`, reaching `GamesController#set_content_locale`. Task 2 renders buttons that post to it.
  - The play-screen helper `set_content_locale_path(:game_id => id, :locale => l)` is unchanged and keeps working.

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/game_content_locale_switch_spec.rb`:

```ruby
require "rails_helper"

# The play screen has had a content-language switcher since the AI-translation
# work; this covers the game page's own, which is reachable when the game is
# NOT running -- the state the play-screen route refuses. See the plan at
# docs/superpowers/plans/2026-08-18-content-locale-switcher-on-game-page.md.
describe "switching content language from the game page", type: :request do
  # Mirrors spec/requests/translated_level_spec.rb: create_user builds every
  # user with password "1234".
  def login(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  let(:author) { create_user }

  # A draft, and deliberately so: ensure_author_if_game_is_draft keeps a draft
  # author-only, and a stopped draft is exactly the state in which the owner
  # got stuck in Turkish.
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en tr]
    g.save!
    g
  end

  it "stores the chosen locale for the signed-in user" do
    login(author)

    post set_content_locale_game_path(game, :locale => "en")

    preference = GameLocalePreference.find_by(:user_id => author.id, :game_id => game.id)
    expect(preference&.locale).to eq("en")
  end

  it "redirects back to the game page" do
    login(author)

    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to redirect_to(game_path(game))
  end

  it "updates the one row rather than accumulating a row per switch" do
    login(author)

    post set_content_locale_game_path(game, :locale => "tr")
    post set_content_locale_game_path(game, :locale => "en")

    rows = GameLocalePreference.where(:user_id => author.id, :game_id => game.id)
    expect(rows.count).to eq(1)
    expect(rows.first.locale).to eq("en")
  end

  # content_locale_for already ignores an undeclared locale at read time; this
  # keeps one from being written at all, so the row never has to be cleaned up
  # after an author narrows available_locales.
  it "writes nothing for a locale the game does not offer" do
    login(author)

    post set_content_locale_game_path(game, :locale => "ka")

    expect(GameLocalePreference.where(:game_id => game.id)).to be_empty
  end

  it "sends a signed-out visitor to the login page and writes nothing" do
    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to redirect_to(login_path)
    expect(GameLocalePreference.count).to eq(0)
  end

  # The regression this whole change exists for. Both requests are the same
  # intent; only the game-page route is reachable while the game is stopped.
  it "works on a stopped draft, where the play-screen route answers 401" do
    login(author)

    post set_content_locale_path(:game_id => game.id, :locale => "en")
    expect(response).to have_http_status(:unauthorized)
    expect(GameLocalePreference.count).to eq(0)

    post set_content_locale_game_path(game, :locale => "en")
    expect(GameLocalePreference.count).to eq(1)
  end

  # Same visibility rule as games#show: a stranger cannot see this draft, so
  # they cannot record a reading preference for it either.
  it "refuses a draft belonging to somebody else" do
    login(create_user)

    post set_content_locale_game_path(game, :locale => "en")

    expect(response).to have_http_status(:unauthorized)
    expect(GameLocalePreference.count).to eq(0)
  end
end
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_content_locale_switch_spec.rb
```

Expected: every example errors with `NameError: undefined local variable or method 'set_content_locale_game_path'` — the route does not exist yet. An example failing on anything else means the harness is wrong, not the feature.

- [ ] **Step 3: Add the shared writer to the concern**

In `app/controllers/concerns/content_locale_selection.rb`, add below `#content_locale_for` (keeping it above the `private` helpers it uses):

```ruby
  # Persist a per-game content-language choice for the signed-in user.
  # Returns false, writing nothing, for a guest or for a locale the game does
  # not offer.
  #
  # Both switchers write through this. They differ only in which filters guard
  # them and where they redirect; a second copy of the find_or_initialize would
  # be a second place to forget the available_locale_list check.
  def store_content_locale(game, locale)
    return false unless respond_to?(:current_user, true) && current_user
    return false unless game.available_locale_list.include?(locale.to_s)

    preference = GameLocalePreference.find_or_initialize_by(:user_id => current_user.id,
                                                           :game_id => game.id)
    preference.locale = locale.to_s
    preference.save!
    # content_locale_for memoises per game for the life of the request. Both
    # callers redirect, so nothing re-reads it here today -- but a stale
    # memo is exactly the kind of thing a later render would inherit silently.
    @content_locales = nil
    true
  end
```

- [ ] **Step 4: Point the play-screen action at it**

In `app/controllers/game_passings_controller.rb`, replace the body of `#set_content_locale` (keep the comment block above the method — its point about not trusting the filter silently is now carried by the concern's own guard):

```ruby
  # Writes on behalf of current_user, which require_authentication! (see the
  # before_action list above) already guarantees is present for every action
  # on this controller except :index and :show_results -- but that filter's
  # job is authentication, not this action's, so store_content_locale still
  # checks rather than trusting it silently and letting a future filter change
  # turn this into a NoMethodError on nil instead of a no-op.
  #
  # The game page has its own switcher (GamesController#set_content_locale),
  # reachable when the game is not running. Same write, different guards and a
  # different redirect -- which is why the action stays here rather than the
  # two screens sharing one endpoint.
  def set_content_locale
    store_content_locale(@game, params[:locale])
    redirect_to show_current_level_path(:game_id => @game.id)
  end
```

- [ ] **Step 5: Add the game-page action and its filters**

In `app/controllers/games_controller.rb`, add `:set_content_locale` to the four `only:` lists that give `#show` its visibility rules, plus `find_game`:

```ruby
  before_action :find_game, only: [:show, :edit, :update, :delete, :end_game, :start_test, :finish_test, :withdraw, :restore, :unfinish, :lock, :unlock, :hand_over, :set_content_locale]
  before_action :find_team, only: [:show]
  before_action :ensure_author_if_game_is_draft, only: [:show, :set_content_locale]
  before_action :ensure_author_if_no_start_time, only: [:show, :set_content_locale]
  before_action :ensure_author_if_game_is_withdrawn, only: [:show, :set_content_locale]
  before_action :ensure_author_if_game_is_testing, only: [:show, :set_content_locale]
```

`require_authentication!` excludes only `[:index, :show]`, so the new action is authenticated already — do not touch that line.

Add the action itself, next to the other small member actions:

```ruby
  # Which language this reader wants THIS game's authored content in.
  #
  # The play screen has the same switcher, but its route is behind the
  # play-time filters -- started game, on a team in it. An author who picked
  # another language while testing a translation was then stuck with it on
  # this page, with nothing here to change it back and no way to reach the
  # play screen once the game was stopped.
  #
  # Guarded by exactly the filters #show is guarded by: if you can read the
  # game, you can record which language you read it in.
  def set_content_locale
    store_content_locale(@game, params[:locale])
    redirect_to game_path(@game)
  end
```

- [ ] **Step 6: Add the route**

In `config/routes.rb`, inside `resources :games do member do ... end end` (after `post :hand_over`):

```ruby
      # Which language this reader sees the game's authored content in.
      # POST because it writes; a member route because the preference is
      # per-game. The play screen keeps its own route (set_content_locale_path,
      # under /play) -- same write, different guards and redirect.
      post :set_content_locale
```

This generates `set_content_locale_game_path` → `POST /games/:id/set_content_locale`. It does not collide with the play route's `set_content_locale_path`.

- [ ] **Step 7: Run the spec — all green**

```bash
bundle exec rspec spec/requests/game_content_locale_switch_spec.rb
```

Expected: 7 examples, 0 failures.

- [ ] **Step 8: Prove the play screen still works**

```bash
bundle exec rspec spec/requests/content_locale_spec.rb spec/requests/translated_level_spec.rb spec/routing_spec.rb spec/views/game_passings_spec.rb
```

Expected: 0 failures. `spec/routing_spec.rb` still pins that `game_passings#set_content_locale` is not reachable over `GET /stats/...`.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/concerns/content_locale_selection.rb \
        app/controllers/game_passings_controller.rb \
        app/controllers/games_controller.rb \
        config/routes.rb \
        spec/requests/game_content_locale_switch_spec.rb
git commit -m "Let a reader set a game's content language off the play screen"
```

---

### Task 2: Show the switcher on the game page

**Files:**
- Modify: `app/views/shared/_content_language_switcher.html.erb`
- Modify: `app/views/games/show.html.erb:7-11` (after the draft label, above the details panel)
- Test: `spec/views/games_spec.rb` — the `RSpec.describe "games/show"` block that starts at line 240

**Interfaces:**
- Consumes: `set_content_locale_game_path(game, :locale => l)` from Task 1; `Game#multilingual?`; `t("game_passings.content_language")`; `t("locales.#{l}")`.
- Produces: the partial's new optional local — `render "shared/content_language_switcher", :game => g, :switch_path => ->(locale) { ... }`. Omit `:switch_path` and it posts to the play-screen route exactly as before, so `game_passings/show_current_level.html.erb:63` needs no edit.

- [ ] **Step 1: Write the failing view specs**

Append to the `RSpec.describe "games/show", type: :view do` block in `spec/views/games_spec.rb` (it starts at line 240):

```ruby
  # A game page renders authored content through content_locale_for, which
  # prefers a stored per-game preference over the reader's chrome locale. The
  # switcher is what makes that visible and reversible here -- until it was
  # added, a preference set on the play screen could not be changed once the
  # game stopped.
  it "offers the content-language switcher to a signed-in reader of a multilingual game" do
    game = create_game
    game.available_locale_list = %w[ru en]
    game.save!
    reader = create_user

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    # games/show.html.erb:46 asks @current_user.author_of?, so a logged-in
    # render needs the ivar as well as the helper.
    assign(:current_user, reader)
    view.define_singleton_method(:logged_in?)   { true }
    view.define_singleton_method(:current_user) { reader }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).to include(I18n.t("game_passings.content_language"))
    expect(rendered).to include(set_content_locale_game_path(game, :locale => "en"))
    # The game page's own route, not the play screen's -- posting to the
    # latter from here 401s on a game that is not running.
    expect(rendered).not_to include(set_content_locale_path(:game_id => game.id, :locale => "en"))
  end

  it "shows no switcher for a game with a single declared locale" do
    game = create_game
    reader = create_user

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    assign(:current_user, reader)
    view.define_singleton_method(:logged_in?)   { true }
    view.define_singleton_method(:current_user) { reader }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).not_to include(I18n.t("game_passings.content_language"))
  end

  # store_content_locale writes on behalf of current_user, so a guest pressing
  # one of these would get a redirect to the login page and no preference.
  # Better not to offer it: a guest's content locale already follows the
  # header's language switcher.
  it "shows no switcher to a guest" do
    game = create_game
    game.available_locale_list = %w[ru en]
    game.save!

    assign(:game, game)
    assign(:game_entries, [])
    assign(:teams, [])
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:content_locale_for) { |g| g.primary_locale }

    render

    expect(rendered).not_to include(I18n.t("game_passings.content_language"))
  end
```

- [ ] **Step 2: Run them and watch the first one fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/views/games_spec.rb -e "content-language switcher"
```

Expected: FAIL — `expected "..." to include "Язык содержимого"` (the switcher is not rendered on this page yet). The two negative examples pass already; that is fine, they are there to keep passing.

- [ ] **Step 3: Give the partial an optional target**

Rewrite `app/views/shared/_content_language_switcher.html.erb`:

```erb
<%# app/views/shared/_content_language_switcher.html.erb %>
<%# Only worth showing when there is actually a choice to make. %>
<% if game.multilingual? %>
  <%# Two screens render this, and each has to post to its own route: the play
      screen's is behind the play-time filters and redirects into the game,
      the game page's is behind the same filters as games#show and redirects
      back there. Defaulting to the play route keeps show_current_level's
      render unchanged. %>
  <% switch_path = local_assigns.fetch(:switch_path,
       ->(locale) { set_content_locale_path(:game_id => game.id, :locale => locale) }) %>
  <div class="content-language-switcher">
    <%= t("game_passings.content_language") %>:
    <% game.available_locale_list.each do |locale| %>
      <%# The language switcher added during the Merb->Rails port
          (app/views/layouts/_header.html.erb) already names these
          "locales.<code>" ("Русский", "English", ...) -- reuse it rather
          than inventing a second key for the same list of names. %>
      <%= button_to t("locales.#{locale}"),
                    switch_path.call(locale),
                    :method => :post, :class => "language-choice" %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 4: Render it on the game page**

In `app/views/games/show.html.erb`, immediately after the draft-label block (currently lines 7-9) and before `<div class="panel">`:

```erb
<%# Directly under the title, because the title itself is translated content:
    a reader who wonders why the name reads Turkish finds the control that
    says so in the same glance. Signed-in only -- the preference is stored per
    user, and a guest's content locale already follows the header switcher. %>
<% if logged_in? %>
  <%= render "shared/content_language_switcher", :game => @game,
             :switch_path => ->(locale) { set_content_locale_game_path(@game, :locale => locale) } %>
<% end %>
```

- [ ] **Step 5: Run the view specs — all green**

```bash
bundle exec rspec spec/views/games_spec.rb spec/views/game_passings_spec.rb
```

Expected: 0 failures. `game_passings_spec.rb` proves the play screen's own render still works with the local omitted.

- [ ] **Step 6: Commit**

```bash
git add app/views/shared/_content_language_switcher.html.erb \
        app/views/games/show.html.erb \
        spec/views/games_spec.rb
git commit -m "Show the content-language switcher on the game page"
```

---

## Verification before the branch is finished

Run these yourself — do not delegate a full-suite run to a subagent.

- [ ] **Full RSpec.** `bundle exec rspec` — expect 0 failures, 6 pending. Re-measure the example count rather than quoting one; the figure in CLAUDE.md has been stale four times.
- [ ] **The inherited Cucumber contract**, which this change must not move:

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: 228 scenarios (226 passed, 2 undefined), 2325 steps. No `.feature` file was touched, so a moved count means something is badly wrong.

- [ ] **Whole Cucumber suite:** `bundle exec cucumber` — 238 scenarios / 2386 steps.
- [ ] **Eyeball it.** `bin/rails server`, open a multilingual game's page signed in, press each language, confirm the title and description change and the page comes back to `/games/:id`. Four locales' buttons must sit on one row on a phone width (`form.button_to { display: inline-block }` in `public/stylesheets/screens.css:583` is what makes that true) — if they stack, stop and re-measure with `bin/measure-play-screen`'s approach rather than adding CSS blind.

## Post-deploy: the three stuck production rows

Not a code task, and **not to be run without the repository owner's explicit go-ahead** — it writes to production.

Once the change is deployed, the owner can clear their own preference from the page itself, which is the point of the change. If they would rather have it cleared directly:

```sql
-- Evgeny's Turkish pin on game 6, the row that prompted this work.
DELETE FROM game_locale_preferences WHERE id = 2;
```

Row 3 (Dragon_Stupka → tr) and row 5 (Ирек → ru) are other people's reading choices on the same game. Leave them: after this change each of those users can see and change their own, and deleting someone else's preference is not this plan's business.
