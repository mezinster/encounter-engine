# Per-User Timezone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each user choose their own timezone so every timestamp renders in it, while a user who never chooses one sees exactly what they see today.

**Architecture:** Tasks 1–3 are the timezone feature — a nullable column, an `around_action` concern mirroring `LocaleSelection`, the profile control, and the rendering changes. Tasks 4–5 are unrelated carried-forward bug fixes the repository owner asked to fold in; they touch nothing the timezone work touches and can be reordered or dropped without affecting it.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, sqlite (dev/test), RSpec, Cucumber (Russian Gherkin). No asset pipeline.

## Global Constraints

- Ruby is not on `PATH` in non-login shells. Prefix every command: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- Branch `design/per-user-timezone`, cut from master at `eb418d4`, already carries the spec. **Measured baseline: 730 rspec examples / 0 failures / 6 pending**, and **234 cucumber scenarios (2 pre-existing "undefined") / 2362 steps**.
- **No `.feature` file may be edited, for any reason, in any task.** Step definitions are editable.
- **The binding constraint:** four frozen features assert exact wall-clock strings — `features/games/create-game.feature:87` (`2050-03-21 18:01`), `features/games/registration-deadline.feature:21` (`2010-05-27 00:00`), `features/time/time-in-header.feature:15` (`2050-05-20 00:00`), `features/games/hide-left-column-when-in-game.feature:25` (`Личный кабинет 2009-02-02 15:01`). Cucumber's users never set a timezone, so **a user with no timezone must render byte-identically to today**. If any of those four moves, the fallback path is wrong — fix the fallback, never the feature.
- The test environment's `Time.zone` is **UTC** (`config.time_zone = ENV.fetch("TZ", "UTC")` and `TZ` is unset). Write assertions against `Time.zone` rather than hardcoding `"UTC"`, so they stay correct if someone sets `TZ`.
- Every user-facing string is a `t()` key in **all four** of `config/locales/{ru,en,uk,ka}.yml`. Use the exact translations in this plan.
- Hash rockets (`:key => value`) for symbol keys; match the surrounding file.
- Run `bin/rails db:test:prepare` after the migration.

---

### Task 1: The column and `TimeZoneSelection`

**Files:**
- Create: `db/migrate/<timestamp>_add_timezone_to_users.rb`
- Create: `app/controllers/concerns/time_zone_selection.rb`
- Modify: `app/controllers/application_controller.rb:4` (the include list)
- Test: `spec/requests/time_zone_selection_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `users.timezone` (string, nullable); `TimeZoneSelection`, included by `ApplicationController`, wrapping every action in `Time.use_zone`.

Nothing renders differently for an existing user after this task — the column is NULL for everyone, which means "instance default".

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/time_zone_selection_spec.rb`:

```ruby
require "rails_helper"

describe "the viewer's timezone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  # An absolute instant, so the assertions below are about rendering and not
  # about how the fixture's string was parsed. 2099-01-01 12:00 UTC is 13:00 in
  # Berlin (CET, +1 in January) and 16:00 in Tbilisi (+4).
  before { game.update_column(:starts_at, Time.utc(2099, 1, 1, 12, 0, 0)) }

  def sign_in(u)
    put login_path, :params => { :email => u.email, :password => "1234" }
  end

  it "renders a time in the user's chosen zone" do
    user.update!(:timezone => "Berlin")
    sign_in(user)

    get game_path(game)

    expect(response.body).to include("2099-01-01 13:00")
  end

  it "renders a different user's chosen zone differently for the same instant" do
    user.update!(:timezone => "Tbilisi")
    sign_in(user)

    get game_path(game)

    expect(response.body).to include("2099-01-01 16:00")
  end

  # THE compatibility contract. Four frozen features assert exact wall-clock
  # strings and their users never set a timezone; if this example breaks, those
  # features are about to break too.
  it "falls back to the instance default when the user has not chosen one" do
    expect(user.timezone).to be_nil
    sign_in(user)

    get game_path(game)

    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  # A stored zone can go stale when the tzdata Rails ships changes. A profile
  # column must never be able to 500 every page the user visits.
  it "falls back rather than raising on a zone name Rails does not know" do
    user.update_column(:timezone, "Middle/Earth")
    sign_in(user)

    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  it "applies the instance default to a signed-out visitor" do
    get game_path(game)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.l(Time.utc(2099, 1, 1, 12, 0, 0).in_time_zone(Time.zone), :format => :short))
  end

  # This is what around_action buys over before_action, and it is invisible to
  # every other example here: a before_action version would leak the last
  # request's zone into whatever runs next on the same thread, and all the
  # examples above would still pass.
  it "does not leak the zone past the request" do
    instance_default = Time.zone.name
    user.update!(:timezone => "Tbilisi")
    sign_in(user)

    get game_path(game)

    expect(Time.zone.name).to eq(instance_default)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/time_zone_selection_spec.rb
```

Expected: the first two fail on the rendered time; `update!(:timezone => ...)` raises `NoMethodError` before that, since the column does not exist yet.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration AddTimezoneToUsers
```

```ruby
class AddTimezoneToUsers < ActiveRecord::Migration[8.0]
  def change
    # Nullable, no default, no backfill. NULL means "use the instance default",
    # which is what lets every existing user keep rendering exactly as they do
    # today without touching a single row -- and it keeps "never chose one"
    # distinguishable from "chose the instance zone".
    add_column :users, :timezone, :string
  end
end
```

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 4: Write the concern**

Create `app/controllers/concerns/time_zone_selection.rb`:

```ruby
# Mirrors LocaleSelection: a per-user preference with an instance-wide
# fallback. Where that one wraps I18n.with_locale, this wraps Time.use_zone.
module TimeZoneSelection
  extend ActiveSupport::Concern

  included do
    # around_action, NOT before_action. Time.use_zone restores the previous
    # zone in an ensure block; assigning Time.zone in a before_action would
    # leak the last request's zone into whatever runs next on that thread.
    around_action :use_time_zone
  end

  private

  # Precedence: the signed-in user's stored preference, then the instance
  # default from config.time_zone (ENV["TZ"]).
  #
  # Deliberately no ?timezone= override. LocaleSelection has one so an
  # organiser can preview a translation; there is no equivalent need here.
  def use_time_zone(&block)
    Time.use_zone(current_user_time_zone || Time.zone, &block)
  end

  # ActiveSupport::TimeZone[] returns nil for a name it does not know, so one
  # expression covers both "not set" and "no longer valid". Defensive in the
  # same shape as LocaleSelection#current_user_locale: a stored zone can go
  # stale when the tzdata Rails ships changes, and a profile column must never
  # be able to 500 every page the user visits.
  def current_user_time_zone
    return nil unless respond_to?(:current_user, true) && current_user

    ActiveSupport::TimeZone[current_user.timezone.to_s]
  end
end
```

- [ ] **Step 5: Include it**

In `app/controllers/application_controller.rb`, add after `include LocaleSelection`:

```ruby
  include TimeZoneSelection
```

Leave `include ContentLocaleSelection` and the `before_action :set_current_user` line where they are. That file carries a comment explaining `set_current_user` must not be reordered ahead of `set_locale`; this include adds an `around_action`, which wraps rather than reorders, so nothing there changes.

- [ ] **Step 6: Run the spec, then the full suites**

```bash
bundle exec rspec spec/requests/time_zone_selection_spec.rb
bin/rails zeitwerk:check
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (6 examples); `zeitwerk:check` prints `All is good!`; the full suite is **730 + 6 = 736 examples, 0 failures, 6 pending**; cucumber is **234 scenarios (2 undefined) / 2362 steps**.

**If any of the four exact-time scenarios fails**, the fallback is wrong — a user with no timezone is not landing on `Time.zone`. Fix `current_user_time_zone`; do not touch the feature.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/controllers/concerns/time_zone_selection.rb \
        app/controllers/application_controller.rb spec/requests/time_zone_selection_spec.rb
git commit -m "Render times in the viewer's timezone

A nullable users.timezone with no backfill: NULL means the instance default,
so every existing user renders exactly as before and nothing needed writing.

around_action, not before_action -- Time.use_zone restores the previous zone
on the way out, where an assignment would leak this request's zone into
whatever ran next on the thread. A spec pins that, because every other
assertion here passes either way.

An unknown stored zone falls back rather than raising: tzdata changes, and a
profile column must not be able to 500 every page a user visits."
```

---

### Task 2: Choosing it

**Files:**
- Modify: `app/views/users/edit.html.erb` (after the `:locale` field, ~line 30)
- Modify: `app/views/users/index.html.erb`
- Modify: `app/controllers/users_controller.rb:81` (`profile_params`)
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/timezone_preference_spec.rb`

**Interfaces:**
- Consumes: `users.timezone` from Task 1.
- Produces: locale keys `users.edit.timezone_label`, `users.edit.timezone_default`, `users.index.timezone_label`.

- [ ] **Step 1: Add the locale keys, all four files**

Under `users.edit`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `timezone_label` | `Часовой пояс` | `Time zone` | `Часовий пояс` | `დროის სარტყელი` |
| `timezone_default` | `По умолчанию для сервера` | `Server default` | `За замовчуванням для сервера` | `სერვერის ნაგულისხმევი` |

Under `users.index`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `timezone_label` | `Часовой пояс:` | `Time zone:` | `Часовий пояс:` | `დროის სარტყელი:` |

**Check for a duplicate key before inserting.** These locale files already contain more than one `questions:` section at different nesting levels, and YAML silently lets the last duplicate win — an inserted block under a duplicated key is discarded with **no error**, and `spec/i18n_spec.rb` cannot catch it because it compares the already-parsed hashes. Verify:

```bash
for L in ru en uk ka; do echo -n "$L: "; grep -c "^  users:" config/locales/$L.yml; done
```

Expected: `1` for each. If any prints more, merge into the existing section instead of adding another.

- [ ] **Step 2: Write the failing spec**

Create `spec/requests/timezone_preference_spec.rb`:

```ruby
require "rails_helper"

describe "choosing a timezone in the profile", type: :request do
  let(:user) { create_user }

  before { put login_path, :params => { :email => user.email, :password => "1234" } }

  # NOTE: time_zone_select emits Rails' FRIENDLY zone names -- the option value
  # is "Berlin", not "Europe/Berlin", and the label is "(GMT+01:00) Berlin".
  # ActiveSupport::TimeZone[] resolves both forms, so the concern works either
  # way, but these examples must use what the form actually submits.
  it "offers the control on the profile form" do
    get edit_user_path(user)

    expect(response.body).to include(I18n.t("users.edit.timezone_label"))
    expect(response.body).to include(%{value="Berlin"})
  end

  it "saves the choice" do
    patch user_path(user), :params => { :user => { :nickname => user.nickname, :timezone => "Berlin" } }

    expect(user.reload.timezone).to eq("Berlin")
  end

  # include_blank is what makes the setting reversible. Without it NULL stops
  # being reachable through the UI the moment anyone picks a zone, and
  # "instance default" becomes a state you can leave but never return to.
  it "can be cleared back to the instance default" do
    user.update!(:timezone => "Berlin")

    patch user_path(user), :params => { :user => { :nickname => user.nickname, :timezone => "" } }

    expect(user.reload.timezone).to be_blank
  end

  it "shows the chosen zone on the profile page" do
    user.update!(:timezone => "Berlin")

    get users_path

    expect(response.body).to include(I18n.t("users.index.timezone_label"))
    expect(response.body).to include("Berlin")
  end

  it "shows the instance default on the profile page when none is chosen" do
    get users_path

    expect(response.body).to include(I18n.t("users.edit.timezone_default"))
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/timezone_preference_spec.rb
```

Expected: all five fail on the missing markup.

- [ ] **Step 4: Permit the attribute**

In `app/controllers/users_controller.rb`, `profile_params` (~line 81):

```ruby
          .permit(:nickname, :date_of_birth, :icq_number, :jabber_id,
                   :phone_number, :locale, :timezone, :password, :password_confirmation)
```

Update the comment above it that enumerates the permitted list.

- [ ] **Step 5: Add the control to the profile form**

In `app/views/users/edit.html.erb`, immediately after the `:locale` field's `div.field` and before the `:password` one:

```erb
  <div class="field">
    <%= f.label :timezone, t("users.edit.timezone_label") %>
    <%# include_blank is load-bearing: it is the only way back to NULL, and
        NULL is what "use the instance default" means. Without it the setting
        is one-way. %>
    <%= f.time_zone_select :timezone, nil, :include_blank => t("users.edit.timezone_default") %>
  </div>
```

- [ ] **Step 6: Show it on the profile page**

In `app/views/users/index.html.erb`, after the `date_of_birth_label` row:

```erb
  <tr><th><%= t("users.index.timezone_label") %></th>
      <td><%= current_user.timezone.presence || t("users.edit.timezone_default") %></td></tr>
```

- [ ] **Step 7: Run everything**

```bash
bundle exec rspec spec/requests/timezone_preference_spec.rb
bundle exec rspec spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (5 examples); the full suite is **736 + 5 = 741 examples, 0 failures, 6 pending**; cucumber unchanged at **234 / 2362**.

- [ ] **Step 8: Commit**

```bash
git add app/views/users app/controllers/users_controller.rb config/locales \
        spec/requests/timezone_preference_spec.rb
git commit -m "Let a user choose their timezone in their profile

time_zone_select with include_blank, which is the only route back to NULL --
and NULL is what \"use the instance default\" means, so without it the setting
would be one-way."
```

---

### Task 3: The zone label, and a countdown that was already wrong

**Files:**
- Modify: `app/helpers/application_helper.rb`
- Modify: `app/views/games/show.html.erb:19,26` (the two labelled times) and `:89` (the countdown)
- Modify: `app/views/game_passings/show_results.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/timezone_rendering_spec.rb`

**Interfaces:**
- Consumes: `TimeZoneSelection` from Task 1.
- Produces: `ApplicationHelper#l_with_zone(time, format:)`.

- [ ] **Step 1: Add the locale key, all four files**

Under `game_passings.show_results`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `times_in_zone` | `Время показано в поясе %{zone}` | `Times shown in %{zone}` | `Час показано в поясі %{zone}` | `დრო ნაჩვენებია სარტყელში %{zone}` |

- [ ] **Step 2: Write the failing spec**

Create `spec/requests/timezone_rendering_spec.rb`:

```ruby
require "rails_helper"

describe "timestamps that carry their zone", type: :request do
  let(:user) { create_user }
  let(:game) { create_game(:author => user, :is_draft => false) }

  before do
    game.update_column(:starts_at, Time.utc(2099, 1, 1, 12, 0, 0))
    game.update_column(:registration_deadline, Time.utc(2098, 12, 1, 10, 0, 0))
    user.update!(:timezone => "Berlin")
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "labels the game start with its offset" do
    get game_path(game)

    expect(response.body).to include("2099-01-01 13:00 (+01:00)")
  end

  it "labels the registration deadline with its offset" do
    get game_path(game)

    expect(response.body).to include("2098-12-01 11:00 (+01:00)")
  end

  # The countdown used to emit new Date(2099,0,1,13,0,0) -- bare numbers the
  # BROWSER reads in ITS own zone, so the countdown disagreed with the time
  # printed directly above it for anyone whose browser zone differed from the
  # server's. Milliseconds since the epoch is zone-free by construction.
  it "gives the countdown an absolute instant, not a local-time tuple" do
    get game_path(game)

    expect(response.body).to include("new Date(#{(game.starts_at + 1).to_i * 1000})")
    expect(response.body).not_to match(/new Date\(\d{4},\d+,\d+,/)
  end
end

describe ApplicationHelper, "#l_with_zone", type: :helper do
  it "appends the offset of the current zone" do
    Time.use_zone("Berlin") do
      expect(helper.l_with_zone(Time.utc(2099, 1, 1, 12, 0, 0), :format => :short))
        .to eq("2099-01-01 13:00 (+01:00)")
    end
  end

  it "returns nil for a nil time, so callers can guard on presence" do
    expect(helper.l_with_zone(nil, :format => :short)).to be_nil
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/timezone_rendering_spec.rb
```

Expected: failures on the missing offset and on `l_with_zone` being undefined.

- [ ] **Step 4: Add the helper**

In `app/helpers/application_helper.rb`, inside `module ApplicationHelper`:

```ruby
  # "2099-01-01 13:00 (+01:00)". Only for the timestamps a user acts on --
  # game start, registration deadline, and the results screen's heading. A zone
  # marker on every line of an answer log is noise that makes the few that
  # matter harder to notice, not easier.
  #
  # The numeric offset rather than the zone's abbreviation, deliberately:
  # abbreviations are ambiguous across regions -- IST is three different zones
  # -- while an offset is unambiguous to anyone comparing two times, which is
  # the only thing this label is for.
  def l_with_zone(time, format:)
    return nil if time.nil?

    "#{l(time, :format => format)} (#{time.in_time_zone(Time.zone).formatted_offset})"
  end
```

- [ ] **Step 5: Apply it to the two game times**

In `app/views/games/show.html.erb`, line 19:

```erb
      <em><%= t("games.show.starts_at_label") %></em>: <%= l_with_zone(@game.starts_at, format: :short) %>
```

and line 26:

```erb
      <em><%= t("games.show.registration_deadline_label") %></em>: <%= l_with_zone(@game.registration_deadline, format: :short) %>
```

The label **appends**, so the frozen assertions still hold: `create-game.feature:87` and `registration-deadline.feature:21` use `должен увидеть`, a substring match, and `2050-03-21 18:01` remains a substring of `2050-03-21 18:01 (+00:00)`. Verify that by running cucumber in Step 8, not by trusting this paragraph.

- [ ] **Step 6: Fix the countdown**

In `app/views/games/show.html.erb`, line 89, replace:

```erb
    var date = new Date(<%= (@game.starts_at + 1).strftime("%Y,%m-1,%d,%H,%M,%S") %>);
```

with:

```erb
    <%# Milliseconds since the epoch, not a local-time tuple. The old form
        emitted bare numbers that new Date(y,m,d,...) reads in the BROWSER's
        zone while the server wrote them in its own -- so the countdown was
        already wrong for every user whose browser zone differed from the
        instance's, and per-user timezones would have put that error directly
        under a correctly-labelled start time on the same page. %>
    var date = new Date(<%= (@game.starts_at + 1).to_i * 1000 %>);
```

- [ ] **Step 7: State the zone once on the results screen**

`show_results.html.erb` renders many finish times through raw `strftime('%H:%M:%S')` (lines 29, 31, 39). Appending an offset to each would repeat the same eight characters down the whole table for no gain.

Instead, state it once. Immediately after the results heading, before the table:

```erb
<%# One statement for the whole table rather than an offset on every row: the
    times here are all in the same zone, and repeating it per row would bury
    the information it is meant to convey. %>
<p><em><%= t("game_passings.show_results.times_in_zone", :zone => Time.zone.formatted_offset) %></em></p>
```

This is a deliberate refinement of the design doc, which described `l_with_zone` for all three sites. The intent — *times that matter carry a zone* — is better served here by one legible sentence than by N repetitions.

- [ ] **Step 8: Run everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/timezone_rendering_spec.rb
bundle exec rspec spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (5 examples); the full suite is **741 + 5 = 746 examples, 0 failures, 6 pending**; cucumber is **234 scenarios (2 undefined) / 2362 steps**.

**If `create-game.feature` or `registration-deadline.feature` fails**, the substring assumption in Step 5 was wrong. Report it — do not edit the feature and do not remove the label without saying so.

- [ ] **Step 9: Commit**

```bash
git add app/helpers/application_helper.rb app/views/games/show.html.erb \
        app/views/game_passings/show_results.html.erb config/locales \
        spec/requests/timezone_rendering_spec.rb
git commit -m "Label the times a user acts on with their zone

Game start and registration deadline carry the offset; the results table
states its zone once rather than repeating it per row. Logs, the header clock
and the audit trail stay bare -- a marker on every line buries the few that
matter.

Also fixes the countdown, which was already wrong before any of this: it
emitted a local-time tuple that new Date(y,m,d,...) reads in the BROWSER's
zone while the server wrote it in the instance's. Milliseconds since the epoch
is zone-free, so it now agrees with the labelled start time above it."
```

---

## Carried-forward fixes

Tasks 4 and 5 are unrelated to the timezone work and to each other. Both are pre-existing bugs on `master`, both were found and deferred earlier, and the repository owner asked for them here. Neither touches a file Tasks 1–3 touch.

### Task 4: Enforce the team cap on the server

**Files:**
- Modify: `app/models/game.rb:218-221`
- Modify: `app/views/shared/_game_entry_controls.html.erb:9,16`
- Test: `spec/requests/game_capacity_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Game#can_request?` returning a real boolean.

**The bug.** `Game#can_request?` computes the capacity check and then throws it away:

```ruby
def can_request?
  self.requested_teams_number < self.max_team_number   # result discarded
  Game.all.select {|game| !game.started?}               # an Array -- always truthy
end
```

`GameEntriesController#new` and `#reopen` gate on it, so the cap is never enforced server-side. `_game_entry_controls.html.erb` checks capacity correctly and hides the link, which is why `features/games/max-team-number.feature`'s "Блокирование регистрации" scenario passes — it exercises the display, never the endpoint. A direct `GET /game_entries/new/:game_id/:team_id` registers past the cap.

Same shape as the authorization holes fixed in the level/question/answer/option/hint controllers and in `GameEntriesController` itself: the UI enforces the rule, the endpoint does not.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/game_capacity_spec.rb`:

```ruby
require "rails_helper"

describe "the team cap", type: :request do
  let(:author)  { create_user }
  let(:game)    { create_game(:author => author, :max_team_number => 1, :is_draft => false) }
  let(:captain) { u = create_user; create_team(:captain => u); u.reload }

  before do
    game.update_column(:requested_teams_number, 1)  # the cap is already reached
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  # The view hides the link, so this is only reachable by requesting the URL
  # directly -- which is exactly the case a server-side check exists for.
  it "refuses a registration once the cap is reached" do
    expect {
      get "/game_entries/new/#{game.id}/#{captain.team_id}"
    }.not_to change { GameEntry.count }
  end

  it "still allows a registration below the cap" do
    game.update_column(:requested_teams_number, 0)

    expect {
      get "/game_entries/new/#{game.id}/#{captain.team_id}"
    }.to change { GameEntry.count }.by(1)
  end

  describe "#can_request?" do
    it "is false at the cap" do
      expect(game.can_request?).to be false
    end

    it "is true below the cap" do
      game.update_column(:requested_teams_number, 0)

      expect(game.reload.can_request?).to be true
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/game_capacity_spec.rb
```

Expected: the refusal example fails (a `GameEntry` is created), and `can_request?` returns an Array rather than `false`.

- [ ] **Step 3: Fix the method**

In `app/models/game.rb`, replace `can_request?`:

```ruby
  # Returned an Array -- always truthy -- because the capacity comparison's
  # result was computed and discarded, and a stray `Game.all.select` was the
  # method's real last expression. So the cap was enforced only by the view
  # that hides the registration link; requesting the URL directly registered
  # past it.
  def can_request?
    self.requested_teams_number < self.max_team_number
  end
```

- [ ] **Step 4: Have the view use it**

`_game_entry_controls.html.erb` open-codes the same rule twice. Now that the method is honest, point both at it so they cannot drift.

Line 9:

```erb
    <% if game.can_request? %>
```

Line 16:

```erb
  <% unless game.can_request? %>
```

The rendered output is identical — `can_request?` is now exactly the expression those lines contained — and `max-team-number.feature` asserts that output, so the suite proves the equivalence.

- [ ] **Step 5: Run everything**

```bash
bundle exec rspec spec/requests/game_capacity_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (4 examples); the full suite is **746 + 4 = 750 examples, 0 failures, 6 pending**; cucumber is **234 / 2362** — in particular `features/games/max-team-number.feature` must still pass, which is what proves Step 4 changed no rendered output.

- [ ] **Step 6: Commit**

```bash
git add app/models/game.rb app/views/shared/_game_entry_controls.html.erb \
        spec/requests/game_capacity_spec.rb
git commit -m "Enforce the team cap on the server, not just in the view

Game#can_request? computed the capacity comparison, discarded it, and returned
a stray Game.all.select -- an Array, always truthy. The cap was enforced only
by the view that hides the registration link, so requesting the URL directly
registered past it.

Same shape as the authorization holes fixed recently: the UI enforces the
rule, the endpoint does not. The view now calls the method instead of
open-coding the same comparison twice, so the two cannot drift."
```

### Task 5: Stop re-charging for an already-answered quiz question

**Files:**
- Modify: `app/views/game_passings/show_current_level.html.erb:116`
- Test: `spec/requests/quiz_play_spec.rb` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**The bug.** The quiz form iterates `current_level.questions.select(&:quiz?)` — **every** quiz question on the level, including ones the team has already answered. On a multi-question quiz level a team that answered question 1 correctly still sees its options; submitting the form again with a wrong pick for question 1 charges `wrong_answer_penalty` a second time for a question they already got right.

`GamePassing#unanswered_questions` already exists and is exactly the right collection.

- [ ] **Step 1: Write the failing spec**

Append to `spec/requests/quiz_play_spec.rb`:

```ruby
describe "a quiz level whose questions are answered one at a time", type: :request do
  let(:author)  { create_user }
  let(:game)    { g = create_game(:author => author, :is_draft => false); g.update_column(:starts_at, 1.hour.ago); g }
  let(:level)   { create_quiz_level(:game => game) }
  let(:first)   { create_question(:level => level) }
  let(:second)  { create_question(:level => level) }
  let(:passing) { create_game_passing(:level => level) }
  let(:player) do
    u = create_user
    u.update!(:team => passing.team)
    passing.team.update!(:captain => u)
    u
  end

  let!(:first_right)  { create_option(:question => first,  :text => "Париж", :is_correct => true) }
  let!(:first_wrong)  { create_option(:question => first,  :text => "Лион") }
  let!(:second_right) { create_option(:question => second, :text => "Да", :is_correct => true) }
  let!(:second_wrong) { create_option(:question => second, :text => "Нет") }

  before do
    level.update_column(:wrong_answer_penalty, 300)
    passing
    put login_path, :params => { :email => player.email, :password => "1234" }
  end

  it "stops offering a question once it has been answered" do
    passing.answer_options!(first, [ first_right.id ])

    get show_current_level_path(:game_id => game.id)

    expect(response.body).to include("Да")
    expect(response.body).not_to include("Париж")
  end

  # The reason it matters: an answered question that is still on the form can
  # be submitted again, and a wrong pick charges the penalty a second time for
  # a question the team already got right.
  it "does not charge again for a question already answered" do
    passing.answer_options!(first, [ first_right.id ])
    charged = passing.reload.penalty_seconds

    post post_answer_path(:game_id => game.id),
         :params => { :option_ids => { first.id.to_s => [ first_wrong.id.to_s ] } }

    expect(passing.reload.penalty_seconds).to eq(charged)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/quiz_play_spec.rb
```

Expected: the first fails because "Париж" is still rendered; the second fails because the penalty grows by 300.

- [ ] **Step 3: Render only unanswered questions**

In `app/views/game_passings/show_current_level.html.erb`, line 116:

```erb
        <%# unanswered_questions, not questions: an answered question that is
            still on the form can be submitted again, and a wrong pick charges
            the penalty a second time for a question the team already got
            right. %>
        <% @game_passing.unanswered_questions.select(&:quiz?).each do |quiz_question| %>
```

**This changes only what is rendered.** `GamePassingsController#post_options` still accepts a submitted `option_ids` for any question — so if the second example still fails after this, the guard belongs in the controller too. Report that rather than widening the view change.

- [ ] **Step 4: Run everything**

```bash
bundle exec rspec spec/requests/quiz_play_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the full suite is **750 + 2 = 752 examples, 0 failures, 6 pending**; cucumber is **234 / 2362**.

- [ ] **Step 5: Commit**

```bash
git add app/views/game_passings/show_current_level.html.erb spec/requests/quiz_play_spec.rb
git commit -m "Stop offering a quiz question the team has already answered

The form iterated every quiz question on the level, so on a multi-question
quiz level an answered question kept its options on screen -- and submitting a
wrong pick for it charged the penalty again for a question the team had
already got right.

unanswered_questions already existed and is exactly the right collection."
```

---

## Definition of done

- `bundle exec rspec` — 752 examples, 0 failures, 6 pending.
- `bundle exec cucumber` — 234 scenarios (2 undefined), 2362 steps.
- `git diff --stat master -- 'features/**/*.feature'` is **empty**.
- `bin/rails zeitwerk:check` — `All is good!`.
- A user who sets a timezone sees every timestamp in it; a user who has not sees exactly what they saw before.
- The game countdown agrees with the start time printed above it, in any browser zone.
- Registering past a game's team cap is refused by the server, not only hidden by the view.

## Deliberately not in this plan

- **PR #19's three deferred minors** (the audit row naming the level but not the game; `spec/requests/admin_audit_spec.rb` not updated; the N+1 on the superadmin stats page). All three live in code that is **on the unmerged `design/redundant-codes` branch**, not on `master`. Fixing them here would conflict with that branch; they belong to it.
- **Giving `Question` its own renderable text**, so a multi-question quiz level can tell its questions apart. A real gap, but it needs a schema column, authoring UI, and a decision about whether that text is translatable — a design pass, not a fix.
- **`GameEntriesController`'s cross-team hole.** Already fixed in PR #20.
