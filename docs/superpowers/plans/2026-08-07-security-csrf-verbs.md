# CSRF Verb Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every destructive action off GET, so Rails' forgery protection actually covers it.

**Architecture:** CSRF protection is already enabled and working — `config.load_defaults 8.0` turns
on `protect_from_forgery with: :exception`. Rails deliberately skips verification for GET
(`verified_request?` returns true on `request.get?`), so the ~20 state-changing actions this app
routes as GET are simply outside it. The fix is mechanical: change the verb in `config/routes.rb`,
change `link_to` to `button_to` at each call site, and update the specs that pin the verb. **Path
helper names do not change** — Rails names `member do` routes `#{action}_#{member}` regardless of
verb — so no helper renaming is needed anywhere. Two step definitions carry the entire Cucumber
suite across the change.

**Tech Stack:** Rails 8.0 routing, ERB views, Capybara/Cucumber step definitions, RSpec routing,
controller, request and view specs.

## Global Constraints

- Ruby 3.3.12 via rbenv, **not on `PATH` in non-login shells**. Prefix every shell command with
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- **Never edit any file under `features/`** ending in `.feature`. Step definitions
  (`features/*/steps/*.rb`, `features/steps/*.rb`) are editable and this plan changes exactly two
  of them.
- Capture a green baseline with `bundle exec rspec` and `bundle exec cucumber` before starting.
- **This app has no Turbo and no rails-ujs.** `link_to ..., method: :delete` and
  `data: { turbo_method: ... }` do nothing here. `button_to` is the only construct that actually
  issues a non-GET request, and it is already the house style — there are 13 existing `button_to`
  call sites (e.g. `app/views/game_passings/index.html.erb:6,8,25,29`).
- `button_to` emits its own `authenticity_token` hidden field, so no token plumbing is needed.
  `config/environments/test.rb:7` disables forgery protection in test, so specs need no token
  either.
- Hash rockets (`:key => value`) throughout. Match the surrounding file.

## Verified before this plan was written

- **`/logout` is the only state-changing URL pinned as GET by the read-only feature suite.** Every
  `.feature` raw-navigation step (`захожу по адресу`) was enumerated: `/teams/new`, `/users`,
  `/signup`, `/dashboard`, `/logout`, `/login`. **Zero** occurrences of any URL in this plan. Every
  affected control is driven by *link text* through editable step definitions.
- **Path helper names are unchanged under the new verbs.** Confirmed by drawing a scratch
  `RouteSet`: `delete_game_path`, `move_up_game_level_path`, `delete_game_level_hint_path`,
  `exit_game_path`, `new_game_entry_path` all keep their names.
- **All 17 view-spec assertion lines survive unchanged** — they assert `include(<path>)` or
  `include(<label>)`, and `button_to` puts the same path in `action=` and the same label in the
  button text.
- **None of the six `delete` actions renders a confirmation page.** Every one destroys immediately.
  The comment at `config/routes.rb:68-72` claiming otherwise is factually wrong about both the
  current code and the Merb original it cites, and Task 7 deletes it.

---

## File Structure

**Modified:**
- `config/routes.rb` — 20 route lines across `:76, 85-87, 92, 102, 107, 115, 150-152, 154, 169-170,
  172-177`, plus the misleading comment block at `:64-73`.
- 11 view files, 19 call sites (enumerated per task).
- `features/steps/webrat_steps.rb:28-30` and `features/answers/steps/answers_steps.rb:17` — the two
  step definitions that drive everything.
- `spec/routing_spec.rb:126-192` — 14 blocks.
- 8 controller-spec `get :action` lines, 28 request-spec `get` lines across 10 files.

**Created:** nothing.

---

### Task 1: Teach the two step definitions to click buttons as well as links

**Files:**
- Modify: `features/steps/webrat_steps.rb:28-30`
- Modify: `features/answers/steps/answers_steps.rb:17`

**Interfaces:**
- Produces: step definitions that work against both `<a>` and `<button>`. Every later task depends
  on this; do it first so no intermediate commit leaves Cucumber red.

**Why first:** `:link_or_button` matches links too, so this change is a no-op against today's markup
and can land before any route moves.

- [ ] **Step 1: Confirm the suite is green before touching anything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber
```

Record the numbers. Expected: 234 scenarios, 2358 steps, 2 undefined.

- [ ] **Step 2: Widen the generic link step**

`features/steps/webrat_steps.rb:28-30` is currently:

```ruby
When /иду по ссылке "(.*)"$/ do |link|
  first(:link, link).click
end
```

Replace with:

```ruby
When /иду по ссылке "(.*)"$/ do |link|
  first(:link_or_button, link).click
end
```

`first(...)` must be preserved, not replaced with `click_link_or_button`. The comment at
`features/steps/webrat_steps.rb:14-27` explains why `first` is used rather than
`Capybara.match = :first`; that reasoning survives the selector swap. Update the comment to say
"link or button" rather than "link", but keep its argument intact.

Two ambiguities this `first` is load-bearing for, both real:
- `"(принять)"` is the label of **both** the invitation accept control and the game-entry accept
  control.
- `"Подать заявку на регистрацию"` is a **prefix** of `"Подать заявку на регистрацию заново"`, and
  Capybara text matching is substring-based. `features/support/env.rb:64-69` already documents this
  dependency.

- [ ] **Step 3: Widen the answers step**

`features/answers/steps/answers_steps.rb:12-19` — change line 17 only:

```ruby
    click_link button_name
```

to:

```ruby
    click_link_or_button button_name
```

Leave `features/answers/steps/answers_steps.rb:26` (`click_link "(редактировать)"`) alone — the edit
link stays a GET link.

- [ ] **Step 4: Run Cucumber and confirm nothing moved**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber
```

Expected: identical to Step 1.

- [ ] **Step 5: Commit**

```bash
git add features/steps/webrat_steps.rb features/answers/steps/answers_steps.rb
git commit -m "Let the link steps click buttons too

Precondition for moving destructive actions off GET. No-op against today's
markup: :link_or_button matches links. first() is preserved -- two labels in
this suite are ambiguous and depend on it."
```

---

### Task 2: Games — delete, start_test, finish_test, end_game

**Files:**
- Modify: `config/routes.rb:76, 150, 151, 152`
- Modify: `app/views/games/show.html.erb:78, 106, 112`
- Modify: `app/views/admin/games/index.html.erb:63-64`
- Modify: `app/views/games/_list.html.erb:65`
- Modify: `app/views/game_passings/show_current_level.html.erb:60`
- Modify: `app/views/game_passings/show_results.html.erb:80`
- Test: `spec/routing_spec.rb:126-136, 146-148`; `spec/controllers/games/{delete,start_test,finish_test,end_game}_spec.rb`; `spec/requests/{game_deletion,admin_audit,superadmin_authorization,language_tabs}_spec.rb`

**Interfaces:**
- Consumes: Task 1's step definitions.
- Produces: `start_test_game_path(id)`, `finish_test_game_path(id)`, `end_game_game_path(id)` — new
  named helpers replacing hard-coded interpolated strings in views. `delete_game_path` is unchanged.

**Why this one matters most:** `GET /games/finish_test/:id` runs `GamePassing.of_game(@game).delete_all`
and `Log.of_game(@game).delete_all` (`app/controllers/games_controller.rb:144-145`) — `delete_all`,
so no callbacks, no audit row, nothing recoverable short of a database restore. It is not behind
`ensure_game_was_not_started`, so a live game is fair game, and `ensure_author` returns early for
superadmins, meaning a superadmin's session authorises the URL for *every game on the instance*.
One clicked link destroys every team's progress and the whole answer log.

- [ ] **Step 1: Change the routing spec first, and watch it fail**

In `spec/routing_spec.rb`, change `method: :get` to the new verb in these blocks:

| lines | path | new method |
|---|---|---|
| `126-128` | `/games/start_test/7` | `:post` |
| `130-132` | `/games/finish_test/7` | `:post` |
| `134-136` | `/games/end_game/7` | `:post` |
| `146-148` | `/games/7/delete` | `:delete` |

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/routing_spec.rb
```

Expected: 4 failures, each saying the route was not recognised for the new verb.

- [ ] **Step 2: Change the routes**

`config/routes.rb:76`, inside `resources :games do member do`:

```ruby
      delete :delete
```

`config/routes.rb:150-152`:

```ruby
  post "/games/start_test/:id",  to: "games#start_test",  as: :start_test_game
  post "/games/finish_test/:id", to: "games#finish_test", as: :finish_test_game
  post "/games/end_game/:id",    to: "games#end_game",    as: :end_game_game
```

- [ ] **Step 3: Run the routing spec to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/routing_spec.rb
```

Expected: green.

- [ ] **Step 4: Convert the six view call sites**

`app/views/games/show.html.erb:78`:
```erb
    <%= button_to t("games.show.delete_link"), delete_game_path(@game), :method => :delete, :class => "btn btn--danger" %>
```

`app/views/games/show.html.erb:106`:
```erb
   <p><%= button_to t("games.show.start_test"), start_test_game_path(@game), :class => "btn" %></p>
```

`app/views/games/show.html.erb:112`:
```erb
     <%= button_to t("games.show.finish_test"), finish_test_game_path(@game), :class => "btn" %>
```

`app/views/admin/games/index.html.erb:63-64` — the `:data => { :confirm => ... }` attribute is inert
today (no UJS reads it). Carry it across unchanged rather than dropping it; removing it would orphan
the `admin.games.index.delete_confirm` key in all four locale files:
```erb
            <%= button_to t("admin.games.index.delete"), delete_game_path(game), :method => :delete, :class => "btn btn--danger",
                        :data => { :confirm => t("admin.games.index.delete_confirm", :name => game.name) } %>
```

`app/views/games/_list.html.erb:65` — keep the `<b>` wrapper:
```erb
            <b><%= button_to t("games.list.end_game"), end_game_game_path(game) if (game.started? and !game.author_finished?) %></b>
```

`app/views/game_passings/show_current_level.html.erb:60`:
```erb
    <%= button_to t("game_passings.show_current_level.finish_testing"), finish_test_game_path(@game), :class => "btn" %>
```

`app/views/game_passings/show_results.html.erb:80`:
```erb
  <p><%= button_to t("game_passings.show_results.finish_testing"), finish_test_game_path(@game) %></p>
```

- [ ] **Step 5: Update the controller and request specs**

Controller specs — change the verb:
- `spec/controllers/games/delete_spec.rb:47` — `get :delete` → `delete :delete`
- `spec/controllers/games/start_test_spec.rb:119` — `get :start_test` → `post :start_test`
- `spec/controllers/games/finish_test_spec.rb:50` — `get :finish_test` → `post :finish_test`
- `spec/controllers/games/end_game_spec.rb:47` — `get :end_game` → `post :end_game`

Request specs — change the verb and switch hard-coded strings to the new helpers:
- `spec/requests/game_deletion_spec.rb:60` — `get delete_game_path(game)` → `delete delete_game_path(game)`
- `spec/requests/admin_audit_spec.rb:49, 118, 140` — `get delete_game_path(...)` → `delete ...`
- `spec/requests/admin_audit_spec.rb:58, 95, 106` — `get "/games/end_game/#{game.id}"` → `post end_game_game_path(game)`
- `spec/requests/admin_audit_spec.rb:77` — `get "/games/start_test/#{game.id}"` → `post start_test_game_path(game)`
- `spec/requests/admin_audit_spec.rb:84` — `get "/games/finish_test/#{testing_game.id}"` → `post finish_test_game_path(testing_game)`
- `spec/requests/superadmin_authorization_spec.rb:85, 97` — `get "/games/finish_test/#{game.id}"` → `post finish_test_game_path(game)`
- `spec/requests/language_tabs_spec.rb:107, 123` — `get "/games/start_test/#{game.id}"` → `post start_test_game_path(game)`

Leave alone — these assert on strings in a rendered body and survive unchanged:
`spec/requests/admin_console_spec.rb:74`, `spec/views/games_spec.rb:51, 66, 258, 274-275`.

- [ ] **Step 6: Run everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: both at baseline. Cucumber exercises these through
`features/games/steps/games_steps.rb:277, 375, 381` and
`features/games/delete-game.feature:13`, all via the widened step from Task 1.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/views spec
git commit -m "Move game lifecycle actions off GET

finish_test runs delete_all on every GamePassing and Log for the game, with no
callbacks and no audit row, and is not behind the started-game guard. Over GET
that was one clicked link away for any author -- and ensure_author admits
superadmins, so a superadmin's session authorised it for every game on the
instance. Rails skips CSRF verification for GET by design."
```

---

### Task 3: Levels — delete, move_up, move_down

**Files:**
- Modify: `config/routes.rb:85, 86, 87`
- Modify: `app/views/levels/show.html.erb:101`, `app/views/levels/_list.html.erb:5-6`
- Test: `spec/routing_spec.rb:150-152`; `spec/controllers/levels/{move_up,move_down}_spec.rb`;
  `spec/requests/level_authorization_spec.rb:48, 54, 59`

- [ ] **Step 1: Change the routing spec and watch it fail**

`spec/routing_spec.rb:150-152` — `/games/7/levels/9/delete` from `method: :get` to `method: :delete`.
There is no routing spec for `move_up`/`move_down`; add one alongside, matching the file's existing
`it_recognizes` idiom:

```ruby
  it_recognizes "keeps /games/:game_id/levels/:id/move_up",
                :method => :post, :path => "/games/7/levels/9/move_up",
                :controller => "levels", :action => "move_up",
                :game_id => "7", :id => "9"
```

Read the surrounding block first and match its exact helper signature — `it_recognizes` is local to
that file.

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/routing_spec.rb
```

Expected: failures on the changed and added blocks.

- [ ] **Step 2: Change the routes**

`config/routes.rb:85-87`:

```ruby
        delete :delete
        post :move_up
        post :move_down
```

- [ ] **Step 3: Convert the view call sites**

`app/views/levels/show.html.erb:101`:
```erb
  <%= button_to t("levels.show.delete_level"), delete_game_level_path(@game, @level), :method => :delete, :class => "btn btn--danger" %>
```

`app/views/levels/_list.html.erb:5-6` — these are the ↑/↓ reorder arrows and sit inline; a
`button_to` renders a form, so give it the inline modifier the codebase already uses for this shape
(`:form_class => "button_to button_to--inline"` if such a class exists in
`app/assets/stylesheets`; otherwise keep the default and check the rendered list visually in
Step 6):
```erb
    <%= button_to "↑", move_up_game_level_path(level.game, level) unless level.first? %>
    <%= button_to "↓", move_down_game_level_path(level.game, level) unless level.last? %>
```

- [ ] **Step 4: Update the specs**

- `spec/controllers/levels/move_up_spec.rb:48` — `get :move_up` → `post :move_up`
- `spec/controllers/levels/move_down_spec.rb:53` — `get :move_down` → `post :move_down`
- `spec/requests/level_authorization_spec.rb:48` — `get delete_game_level_path(...)` → `delete ...`
- `spec/requests/level_authorization_spec.rb:54` — `get move_up_game_level_path(...)` → `post ...`
- `spec/requests/level_authorization_spec.rb:59` — `get move_down_game_level_path(...)` → `post ...`

`spec/views/levels_spec.rb:15-18, 90` assert `include(<path>)` and survive unchanged.

- [ ] **Step 5: Run the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: baseline. `features/levels/delete-level.feature:16` drives the delete via the widened
step. `move_up`/`move_down` have zero Cucumber coverage.

- [ ] **Step 6: Check the level list visually**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails server
```

Open a game with three or more levels as its author. The ↑/↓ controls must still sit on one line per
level and still reorder. `button_to` wraps each in a `<form>`, which is block-level by default — if
the arrows now stack vertically, add `display: inline-block` for those forms in the relevant
stylesheet rather than reverting the verb.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/views/levels spec
git commit -m "Move level deletion and reordering off GET"
```

---

### Task 4: Hints, questions, answers, options — delete

**Files:**
- Modify: `config/routes.rb:92, 102, 107, 115`
- Modify: `app/views/hints/_list.html.erb:11`, `app/views/levels/show.html.erb:45-48`,
  `app/views/answers/index.html.erb:19`, `app/views/options/index.html.erb:52-54`
- Test: `spec/routing_spec.rb:154-156, 158-160`; `spec/requests/code_deletion_spec.rb` (7 lines);
  `spec/requests/quiz_authoring_spec.rb:87`

**Note on guard coverage, worth knowing while you are in here:** `hints#delete`, `answers#delete`
and `options#delete` carry **no** `ensure_game_was_not_started` filter, so they are destroyable
mid-game. That is a separate authorization question and is deliberately *not* in scope for this
plan — do not add the filter here, but do not be surprised by it either.

- [ ] **Step 1: Change the routing specs and watch them fail**

`spec/routing_spec.rb:154-156` (hints) and `:158-160` (answers): `method: :get` → `method: :delete`.
There are no routing specs for questions or options; leave that gap as-is rather than expanding
scope.

- [ ] **Step 2: Change the routes**

`config/routes.rb:92` (hints), `:102` (questions), `:107` (answers), `:115` (options) — each
`get :delete` becomes:

```ruby
          delete :delete
```

Preserve each line's existing indentation; they are at four different nesting depths.

- [ ] **Step 3: Convert the view call sites**

`app/views/hints/_list.html.erb:11` — sits inside an `<em>` next to the edit link:
```erb
              <%= button_to t("shared.delete_short"), delete_game_level_hint_path(hint.level.game, hint.level, hint), :method => :delete unless @level.game.started? %>
```

`app/views/levels/show.html.erb:45-48` — carry the inert `:data => { :confirm => ... }` across:
```erb
          <%= button_to t("levels.show.delete_code"),
                      delete_game_level_question_path(@game, @level, question),
                      :method => :delete,
                      :class => "btn btn--danger",
                      :data => { :confirm => t("levels.show.delete_code_confirm", :code => question.correct_answer) } %>
```

`app/views/answers/index.html.erb:19` — inside a `<td>`, in a row anchored by
`id="answer-<%= answer.id %>"` which the step definition scopes to. Keep the row id:
```erb
    <td><%= button_to t("shared.delete_short"), delete_game_level_question_answer_path(@game, @level, @question, answer), :method => :delete, :class => "btn btn--danger" %></td>
```

`app/views/options/index.html.erb:52-54`:
```erb
            <%= button_to t("shared.delete_short"),
                        delete_game_level_question_option_path(@game, @level, @question, option),
                        :method => :delete,
                        :class => "btn btn--danger" %>
```

- [ ] **Step 4: Update the request specs**

- `spec/requests/code_deletion_spec.rb:20, 32, 45, 56, 67, 75, 84` — `get delete_game_level_question_path(...)` → `delete ...`
- `spec/requests/quiz_authoring_spec.rb:87` — `get delete_game_level_question_option_path(...)` → `delete ...`

`spec/views/{hints,answers}_spec.rb` assertions survive unchanged.

- [ ] **Step 5: Run the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: baseline. The answers delete is driven by
`features/answers/managing-answers.feature:48, 58` through the step widened in Task 1 —
`features/answers/steps/answers_steps.rb:16-18` scopes to `#answer-<id>` before clicking, which is
why the row id had to be preserved in Step 3. The hints delete has no live coverage
(`features/hints/delete-hint.feature:14-20` is entirely commented out).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/views spec
git commit -m "Move hint, code, answer and option deletion off GET"
```

---

### Task 5: Exit game

**Files:**
- Modify: `config/routes.rb:154`
- Modify: `app/views/game_passings/show_current_level.html.erb:57`
- Test: `spec/routing_spec.rb:138-140`; `spec/requests/paused_gameplay_spec.rb:62`

**Note:** `exit_game_path` keeps its name. `spec/routing_spec.rb:64` — the negative guard asserting
these actions are unreachable through `/stats/:action/:game_id` — is unaffected; do not touch it.

- [ ] **Step 1: Change the routing spec and watch it fail**

`spec/routing_spec.rb:138-140` — `/game_passings/exit_game/7` from `method: :get` to `method: :post`.

- [ ] **Step 2: Change the route**

`config/routes.rb:154`:

```ruby
  post "/game_passings/exit_game/:game_id", to: "game_passings#exit_game", as: :exit_game
```

- [ ] **Step 3: Convert the call site**

`app/views/game_passings/show_current_level.html.erb:57` (inside the `current_user.captain?` guard
on line 56):
```erb
      <%= button_to t("game_passings.show_current_level.exit_game"), exit_game_path(:game_id => @game_passing.game_id), :class => "btn" %>
```

- [ ] **Step 4: Update the request spec**

`spec/requests/paused_gameplay_spec.rb:62` — `get exit_game_path(...)` → `post exit_game_path(...)`.

`spec/views/game_passings_spec.rb:102-103` asserts label and path inclusion; both survive.

- [ ] **Step 5: Run the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber features/game-passing
bundle exec cucumber
```

Expected: baseline. `features/game-passing/throw_in_the_towel.feature:21` drives this through
`features/game-passing/steps/game-passing_steps.rb:106`; lines 20 and 36 of that feature assert on
text only and are satisfied by a button.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/views/game_passings/show_current_level.html.erb spec
git commit -m "Move exit_game off GET

config/routes.rb:186-193 already documents this action as the motivating case
for removing the dynamic :action route -- a captain who followed a crafted link
quit their team out of a live game. The dynamic route went; the explicit GET
route to the same action stayed."
```

---

### Task 6: Invitations — accept and reject

**Files:**
- Modify: `config/routes.rb:169-170`
- Modify: `app/views/dashboard/_my_team.html.erb:18-19`
- Test: `spec/routing_spec.rb:162-164, 166-168`;
  `spec/controllers/invitations/{accept,reject}_spec.rb`

**Naming collision — read before writing the route:** `resources :invitations`
(`config/routes.rb:61`) already owns `invitation_path` with `DELETE /invitations/:id →
invitations#destroy`. Do **not** reuse that helper or name these `delete_invitation`.

**The DOM ids are load-bearing.** `features/invitations/steps/invitations_steps.rb:35,47` locate
these controls by id (`accept-invitation-<id>` / `reject-invitation-<id>`).
`button_to "…", path, :id => "x"` puts the id on the `<button>` element, and Capybara's `:button`
selector matches on id — so the ids must move onto the button, which is what the code below does.

- [ ] **Step 1: Change the routing specs and watch them fail**

`spec/routing_spec.rb:162-164` (accept) and `:166-168` (reject): `method: :get` → `method: :post`.

- [ ] **Step 2: Change the routes**

`config/routes.rb:169-170`:

```ruby
  post "/invitations/accept/:id", to: "invitations#accept", as: :accept_invitation
  post "/invitations/reject/:id", to: "invitations#reject", as: :reject_invitation
```

- [ ] **Step 3: Convert the call sites**

`app/views/dashboard/_my_team.html.erb:18-19`:
```erb
        <em><%= button_to t("dashboard.my_team.accept"), accept_invitation_path(invitation), :id => "accept-invitation-#{invitation.id}" %></em>
        <em><%= button_to t("dashboard.my_team.decline"), reject_invitation_path(invitation), :id => "reject-invitation-#{invitation.id}" %></em>
```

- [ ] **Step 4: Update the controller specs**

- `spec/controllers/invitations/accept_spec.rb:78` — `get :accept` → `post :accept`
- `spec/controllers/invitations/reject_spec.rb:70` — `get :reject` → `post :reject`

`spec/views/dashboard_spec.rb:17, 19` assert the path appears in the rendered output and survive.

- [ ] **Step 5: Run the suites**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber features/invitations features/teams
bundle exec rspec
bundle exec cucumber
```

Expected: baseline. These are driven two ways — by DOM id
(`features/invitations/steps/invitations_steps.rb:35,47`) and by label
(`features/teams/steps/team_steps.rb:32`, `"(принять)"`). If the id-driven steps fail, the id landed
on the wrapping form instead of the button; pass `:id` directly to `button_to` rather than through
`:form`.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/views/dashboard/_my_team.html.erb spec
git commit -m "Move invitation accept and reject off GET

GET /invitations/accept/:id joins the current user to a team and deletes all
their other invitations."
```

---

### Task 7: Game entries, and the misleading routes comment

**Files:**
- Modify: `config/routes.rb:64-73` (comment), `:172-177` (routes)
- Modify: `app/views/games/_game_entries.html.erb:14-15`,
  `app/views/shared/_game_entry_controls.html.erb:5, 7, 10, 21`
- Test: `spec/routing_spec.rb:170-192`;
  `spec/requests/game_entry_authorization_spec.rb:39, 49, 59, 73, 86, 96, 111`;
  `spec/requests/game_capacity_spec.rb:17, 25`

- [ ] **Step 1: Change the routing specs and watch them fail**

`spec/routing_spec.rb:170-172` (new), `174-176` (reopen), `178-180` (accept), `182-184` (reject),
`186-188` (recall), `190-192` (cancel): `method: :get` → `method: :post` in all six.

- [ ] **Step 2: Change the routes**

`config/routes.rb:172-177`:

```ruby
  post "/game_entries/new/:game_id/:team_id", to: "game_entries#new", as: :new_game_entry
  post "/game_entries/reopen/:id", to: "game_entries#reopen", as: :reopen_game_entry
  post "/game_entries/accept/:id", to: "game_entries#accept", as: :accept_game_entry
  post "/game_entries/reject/:id", to: "game_entries#reject", as: :reject_game_entry
  post "/game_entries/recall/:id", to: "game_entries#recall", as: :recall_game_entry
  post "/game_entries/cancel/:id", to: "game_entries#cancel", as: :cancel_game_entry
```

`GameEntriesController#new` (`app/controllers/game_entries_controller.rb:15-21`) *creates* an entry
and consumes a capacity slot despite its name — it belongs on POST with the rest.

- [ ] **Step 3: Convert the call sites**

`app/views/games/_game_entries.html.erb:14-15`:
```erb
    <em><%= button_to t("games.game_entries.accept"), accept_game_entry_path(entry) %></em>
    <em><%= button_to t("games.game_entries.reject"), reject_game_entry_path(entry) %></em>
```

`app/views/shared/_game_entry_controls.html.erb:5, 7, 10, 21`:
```erb
    <%= button_to t("shared.game_entry_controls.recall"), recall_game_entry_path(game_entry) %>
```
```erb
    <%= button_to t("shared.game_entry_controls.decline"), cancel_game_entry_path(game_entry) %>
```
```erb
      <%= button_to t("shared.game_entry_controls.reapply"), reopen_game_entry_path(game_entry) %>
```
```erb
    <%= button_to t("shared.game_entry_controls.apply"), new_game_entry_path(:game_id => game.id, :team_id => team.id) %>
```

- [ ] **Step 4: Update the request specs**

All of these become `post`, and the hard-coded strings become the new helpers:
- `spec/requests/game_entry_authorization_spec.rb:39` (recall), `:49` (cancel), `:59` (reopen),
  `:86` (recall), `:111` (accept)
- `spec/requests/game_entry_authorization_spec.rb:73, 96` — `get "/game_entries/new/..."` →
  `post new_game_entry_path(:game_id => ..., :team_id => ...)`
- `spec/requests/game_capacity_spec.rb:17, 25` — same shape

`spec/views/games_spec.rb:134, 136`, `spec/views/shared_spec.rb:9, 12, 20, 23` and
`spec/views/dashboard_spec.rb:66` survive unchanged.

- [ ] **Step 5: Delete the misleading routes comment**

`config/routes.rb:64-73` currently claims these controllers "define `delete` (a GET-rendered
confirmation page …)". That is false — every one of the six `delete` actions destroys immediately,
and so did the Merb original it cites. Leaving it in place is how this gets waved through next time.
Replace the second half of that comment with:

```ruby
  # Merb's `resources` auto-added `GET /<resource>/:id/edit` AND
  # `GET /<resource>/:id/delete` to every `resources` call by default
  # (merb-core/lib/merb-core/dispatch/router/resources.rb:80, removed by
  # Task 13 -- see git history -- `member = { :edit => :get, :delete => :get }`).
  # Rails' `resources` only adds :edit.
  #
  # These controllers define `delete`, not Rails' conventional `destroy`, and
  # the action name is kept -- but the VERB is DELETE, not GET. Every one of
  # these actions destroys immediately; none renders a confirmation page (an
  # earlier version of this comment claimed otherwise, which was wrong about
  # both this code and the Merb original). Rails skips CSRF verification for
  # GET by design, so a destructive action on GET is a destructive action with
  # no CSRF protection. The views drive these with button_to; this app has no
  # Turbo and no rails-ujs, so link_to with :method does nothing here.
```

- [ ] **Step 6: Run everything, including a full clean pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: both exactly at baseline.

- [ ] **Step 7: Verify no GET route still mutates**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails routes | grep -E "^\s*\S*\s+GET" | grep -Ei "delete|destroy|accept|reject|recall|cancel|reopen|end_game|start_test|finish_test|exit_game|move_up|move_down"
```

Expected: **no output.** Any line here is a route this plan missed.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/views spec
git commit -m "Move game entry transitions off GET, and correct the routes comment

Every game-entry transition mutates state, and #new creates an entry and
consumes a capacity slot despite its name. The comment claiming these delete
routes were GET-rendered confirmation pages was wrong about this code and about
the Merb original it cited; it is the reason the routes survived review."
```

---

## Definition of done

- `bundle exec rspec` and `bundle exec cucumber` both exactly at baseline.
- `git status features/` shows only the two step-definition files changed, no `.feature` file.
- The `bin/rails routes` grep in Task 7 Step 7 returns nothing.
- Seven commits, each independently revertable.
- The level-list ↑/↓ arrows have been checked visually (Task 3 Step 6).

## Out of scope, deliberately

- `GET /logout` stays. `features/authentication/logout.feature:9` drives it with a raw GET and
  feature files are read-only. Both the GET and DELETE routes are kept, as documented in
  `config/routes.rb:29-35` and `CLAUDE.md`.
- Adding `ensure_game_was_not_started` to `hints#delete`, `answers#delete` and `options#delete`.
  Real gap, different question, separate change.
- Making the two `data: { confirm: ... }` attributes actually work. They are inert without UJS;
  carrying them across unchanged keeps the i18n keys live for whenever a confirm mechanism is added.
