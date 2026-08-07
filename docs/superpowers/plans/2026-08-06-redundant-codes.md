# Redundant Codes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an author say "any one of this level's codes passes it", and make that the default for newly created levels, without deleting the existing "find all the codes" mechanic.

**Architecture:** Three tasks, each green on its own. Task 1 changes the rule — the column, the pass condition, the play screen, and the two step definitions that keep the frozen suite honest, all together, because flipping the column default breaks those features the instant it lands. Task 2 adds authoring. Task 3 adds the audited superadmin path for changing the mode mid-game.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, sqlite (dev/test), RSpec, Cucumber (Russian Gherkin). No asset pipeline.

## Global Constraints

- Ruby is not on `PATH` in non-login shells. Prefix every command: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- Branch `design/redundant-codes`, which already carries the spec **and PR #18's fixes**. Baseline: **730 rspec examples / 0 failures / 6 pending**, **234 cucumber scenarios (2 pre-existing "undefined") / 2362 steps**. If PR #18 has merged and this branch was rebuilt from master, re-measure before starting rather than trusting these numbers.
- **No `.feature` file may be edited, for any reason, in any task.** Step definitions are editable and carry the whole compatibility story.
- Every user-facing string is a `t()` key in **all four** of `config/locales/{ru,en,uk,ka}.yml`. Use the exact translations in this plan.
- **A running game fails its own validations** — `game_starts_in_the_future` fires once `starts_at` is past and `author_finished_at` is nil — so every write to a level or game belonging to a live game uses `update_column`, never `update!`.
- Hash rockets (`:key => value`) for symbol keys; match the surrounding file.
- Run `bin/rails db:test:prepare` after the migration.

---

### Task 1: The column, the rule, and frozen-suite compatibility

**Files:**
- Create: `db/migrate/<timestamp>_add_any_code_passes_to_levels.rb`
- Modify: `app/models/game_passing.rb` (`all_questions_answered?` at ~line 202; call sites at ~89 and ~108)
- Modify: `app/views/game_passings/show_current_level.html.erb:47`
- Modify: `features/levels/steps/levels_steps.rb:46`, `features/answers/steps/answers_steps.rb:30`
- Test: `spec/models/game_passing/level_answered_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Level#any_code_passes` / `#any_code_passes?` (boolean, `null: false`); `GamePassing#level_answered?` replacing `#all_questions_answered?`.

**Why the step definitions change in this task and not a later one.** The migration flips the column's default to `true`, so every level a Cucumber step builds from that moment on is "any code passes". `playing-with-additional-codes.feature` would immediately fail eight scenarios. Pinning the two constructing steps has to land in the same commit as the migration.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/game_passing/level_answered_spec.rb`:

```ruby
require "rails_helper"

describe GamePassing, "#level_answered?" do
  let(:level)   { create_level }
  let(:passing) { create_game_passing(:level => level) }

  # create_level builds one question; these are the second and third.
  def add_question(code)
    question = Question.new(:correct_answer => code)
    question.level = level
    question.save!
    question
  end

  describe "when all codes are required" do
    before { level.update_column(:any_code_passes, false) }

    it "is false with one of three answered" do
      add_question("два"); add_question("три")
      passing.pass_question!(level.questions.first)

      expect(passing.level_answered?).to be false
    end

    it "is true once every question is answered" do
      second = add_question("два")
      passing.pass_question!(level.reload.questions.first)
      passing.pass_question!(second)

      expect(passing.level_answered?).to be true
    end
  end

  describe "when any code passes" do
    before { level.update_column(:any_code_passes, true) }

    it "is true with one of three answered" do
      add_question("два"); add_question("три")
      passing.pass_question!(level.questions.first)

      expect(passing.level_answered?).to be true
    end

    it "is false with nothing answered" do
      add_question("два")

      expect(passing.level_answered?).to be false
    end
  end

  # A newly created level is redundant by default -- the expectation an author
  # brings to a button labelled "Добавить ещё один код".
  it "defaults a newly created level to any_code_passes" do
    expect(create_level.any_code_passes).to be true
  end
end

describe GamePassing, "passing a level whose codes are redundant" do
  let(:game) { create_game }
  # Both eager and in this order. acts_as_list assigns position on create, so a
  # lazy `let(:level)` would be built AFTER next_level and `level.next` would
  # point the wrong way -- the advancement assertions would then fail for a
  # reason that has nothing to do with the rule under test.
  let!(:level)      { create_level(:game => game) }
  let!(:next_level) { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  before do
    second = Question.new(:correct_answer => "второй"); second.level = level; second.save!
    level.reload
  end

  it "advances on the first correct code when any code passes" do
    level.update_column(:any_code_passes, true)

    expect { passing.check_answer!(level.questions.first.correct_answer) }
      .to change { passing.reload.current_level }.from(level).to(next_level)
  end

  it "still requires both codes otherwise" do
    level.update_column(:any_code_passes, false)

    expect { passing.check_answer!(level.questions.first.correct_answer) }
      .not_to change { passing.reload.current_level }
  end

  # The quiz path asks the same question and must answer it the same way.
  it "applies the same rule to the quiz path" do
    level.update_column(:any_code_passes, true)
    question = level.questions.first
    right = create_option(:question => question, :text => "Париж", :is_correct => true)

    expect { passing.answer_options!(question, [ right.id ]) }
      .to change { passing.reload.current_level }.from(level).to(next_level)
  end

  # Flipping the mode must not teleport anyone. The check runs only when a team
  # submits; re-evaluating every passing on flip would complete levels for teams
  # who did nothing, and pass_level! stamps current_level_entered_at, which is
  # the sole input to every hint countdown.
  it "does not move a team that has already answered one code" do
    level.update_column(:any_code_passes, false)
    passing.pass_question!(level.questions.first)

    expect { level.update_column(:any_code_passes, true) }
      .not_to change { passing.reload.current_level }
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game_passing/level_answered_spec.rb
```

Expected: failures on `undefined method 'any_code_passes'` and `undefined method 'level_answered?'`.

- [ ] **Step 3: Write the migration**

```bash
bin/rails generate migration AddAnyCodePassesToLevels
```

```ruby
class AddAnyCodePassesToLevels < ActiveRecord::Migration[8.0]
  def change
    # Two steps, deliberately. add_column with a default BACKFILLS every
    # existing row, so the default has to start false to leave live games
    # exactly as they are; only then is it flipped for rows created afterwards.
    # A single statement cannot express "existing rows false, new rows true".
    add_column :levels, :any_code_passes, :boolean, :default => false, :null => false
    change_column_default :levels, :any_code_passes, :from => false, :to => true
  end
end
```

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

Confirm `db/schema.rb` shows `default: true, null: false` on `levels.any_code_passes`.

- [ ] **Step 4: Make the pass condition mode-aware**

In `app/models/game_passing.rb`, replace `all_questions_answered?` (~line 202):

```ruby
  # Whether the team has done enough to pass this level.
  #
  # Renamed from all_questions_answered?: under any_code_passes that name would
  # state something false, and this is the only question either caller asks.
  #
  # Deliberately evaluated only when a team SUBMITS. Flipping a level's mode
  # does not re-evaluate existing passings -- see
  # docs/superpowers/specs/2026-08-06-redundant-codes-design.md §2. A team
  # holding one of three codes when an operator flips to "any" passes on their
  # next correct code, rather than being teleported forward by somebody else's
  # click (which would also restamp current_level_entered_at and rewrite every
  # hint countdown mid-level).
  def level_answered?
    return answered_questions.any? if current_level.any_code_passes?

    (current_level.questions - answered_questions).empty?
  end
```

Update both call sites, which are the only two:

- `check_answer!` (~line 89): `pass_level! if all_questions_answered?` → `pass_level! if level_answered?`
- `answer_options!` (~line 108): the same substitution

Confirm nothing else calls the old name:

```bash
grep -rn "all_questions_answered?" app/ spec/ features/ lib/
```

Expected: no matches.

- [ ] **Step 5: Hide the progress line when any code passes**

In `app/views/game_passings/show_current_level.html.erb:47`, change the condition:

```erb
<%# Counting toward a total is meaningless when any single code suffices --
    showing "0 из 3" to a team that needs only one is actively misleading. %>
<% if @game_passing.current_level.multi_question? && !@game_passing.current_level.any_code_passes? %>
```

Leave the body of the block exactly as it is.

- [ ] **Step 6: Pin the two constructing step definitions**

`features/levels/steps/levels_steps.rb`, at the end of the `со следующими кодами` step (~line 58, inside the `Given` block, after the `codes.each` loop):

```ruby
  # This step exists to build the #88 mechanic -- several markers at one
  # location, ALL of which must be found -- which is what every scenario using
  # it asserts. New levels now default to any_code_passes, so the old rule is
  # stated here rather than relied upon. See
  # docs/superpowers/specs/2026-08-06-redundant-codes-design.md §6.
  #
  # update_column because the surrounding scenario may already have moved the
  # clock past the game's start time, which makes the game fail its own
  # validations and any ordinary save raise.
  Level.where(:name => level_name).first.update_column(:any_code_passes, false)
```

`features/answers/steps/answers_steps.rb`, at the end of the `для уровня "..." есть следующие коды:` step (~line 41, after the `codes.hashes.each` loop):

```ruby
  # Same reason as the multi-code step in levels_steps.rb: this builds a level
  # whose scenarios assert "Правильных кодов введено: X из 2", which is the
  # all-codes-required rule. See
  # docs/superpowers/specs/2026-08-06-redundant-codes-design.md §6.
  Level.where(:name => level_name).first.update_column(:any_code_passes, false)
```

- [ ] **Step 7: Run everything**

```bash
bundle exec rspec spec/models/game_passing/level_answered_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (9 examples); the full suite is **730 + 9 = 739 examples, 0 failures, 6 pending**; cucumber is **234 scenarios (2 undefined) / 2362 steps**.

**If cucumber fails**, do not edit the feature. The failure will name a scenario in one of the three files listed in §6 of the spec; the cause is a level built by some path other than the two steps pinned above. Find that path and pin it the same way.

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb app/models/game_passing.rb \
        app/views/game_passings/show_current_level.html.erb \
        features/levels/steps features/answers/steps \
        spec/models/game_passing/level_answered_spec.rb
git commit -m "Let a level pass on any one of its codes

New levels default to redundancy -- the expectation an author brings to a
button labelled \"Добавить ещё один код\". Existing rows keep today's rule, so
no live game changes behaviour: add_column backfills, so the default starts
false and is flipped only for rows created afterwards.

all_questions_answered? becomes level_answered?; under the new mode the old
name states something false.

Flipping a level's mode never re-evaluates existing passings. A team holding
one of three codes passes on their next correct code rather than being moved
by somebody else's click -- pass_level! restamps current_level_entered_at,
which drives every hint countdown.

No .feature file touched. The two step definitions that construct multi-code
levels state the all-required rule explicitly; both exist for the sole purpose
of building that mechanic, so this says what those features already mean."
```

---

### Task 2: Authoring

**Files:**
- Modify: `app/views/levels/new.html.erb:36-39`, `app/views/levels/edit.html.erb:35-38`
- Modify: `app/controllers/levels_controller.rb:73` (`level_params`)
- Modify: `app/views/levels/show.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/level_codes_rule_spec.rb`

**Interfaces:**
- Consumes: `Level#any_code_passes` from Task 1.
- Produces: locale keys `levels.codes_rule_any`, `levels.codes_rule_all`, `levels.form.codes_rule`.

**There is no shared form partial.** `levels/new.html.erb` and `levels/edit.html.erb` each carry their own copy of the form. The field goes in **both**. Adding it to one only would leave the setting choosable at creation but not editable afterwards (or the reverse), with nothing failing loudly. Do not extract a partial — that is two working screens changed for no gain this feature needs.

- [ ] **Step 1: Add the locale keys, all four files**

Under `levels:` (alongside `form:` and `show:`, not inside either — both use these):

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `codes_rule_any` | `Достаточно любого из кодов` | `Any one code passes` | `Достатньо будь-якого з кодів` | `საკმარისია ნებისმიერი კოდი` |
| `codes_rule_all` | `Нужно найти все коды` | `All codes must be found` | `Потрібно знайти всі коди` | `საჭიროა ყველა კოდის პოვნა` |

Under `levels.form:`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `codes_rule` | `Как засчитывать коды` | `How codes count` | `Як зараховувати коди` | `როგორ ითვლება კოდები` |

**Check for a duplicate key before inserting.** These locale files already contain more than one `questions:` section at different nesting levels, and YAML silently lets the last duplicate win — an inserted block under a duplicated key is discarded with no error, and `i18n_spec` cannot catch it because it compares the already-parsed hashes. Verify with:

```bash
for L in ru en uk ka; do echo -n "$L: "; grep -c "^  levels:" config/locales/$L.yml; done
```

Expected: `1` for each. If any file prints more, merge into the existing section rather than adding another.

- [ ] **Step 2: Write the failing spec**

Create `spec/requests/level_codes_rule_spec.rb`:

```ruby
require "rails_helper"

describe "choosing how a level's codes count", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }
  let(:level)  { create_level(:game => game) }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  it "offers the choice on the new-level form" do
    get new_game_level_path(game)

    expect(response.body).to include(I18n.t("levels.form.codes_rule"))
    expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    expect(response.body).to include(I18n.t("levels.codes_rule_all"))
  end

  it "offers the choice on the edit form" do
    get edit_game_level_path(game, level)

    expect(response.body).to include(I18n.t("levels.form.codes_rule"))
  end

  it "saves the choice" do
    expect(level.any_code_passes).to be true

    patch game_level_path(game, level),
          :params => { :level => { :name => level.name, :text => level.text, :any_code_passes => "0" } }

    expect(level.reload.any_code_passes).to be false
  end

  # The change that actually closes the trap: a list of three codes says
  # nothing about how they combine, and the author only discovers the rule
  # during play.
  describe "the level page states the rule" do
    it "says so when any code passes" do
      get game_level_path(game, level)

      expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    end

    it "says so when all codes are required" do
      level.update_column(:any_code_passes, false)

      get game_level_path(game, level)

      expect(response.body).to include(I18n.t("levels.codes_rule_all"))
    end

    # Rendered on a one-code level too, where both modes behave identically.
    # Suppressing it there would mean the line first appears only after a
    # second code is added -- the moment the author has already decided blind.
    it "states the rule even on a single-code level" do
      get game_level_path(game, level)

      expect(level).not_to be_multi_question
      expect(response.body).to include(I18n.t("levels.codes_rule_any"))
    end
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/level_codes_rule_spec.rb
```

Expected: all six fail on the missing markup.

- [ ] **Step 4: Permit the attribute**

In `app/controllers/levels_controller.rb`, `level_params` (~line 73):

```ruby
          .permit(:name, :text, :correct_answer, :wrong_answer_penalty_in_minutes,
                  :any_code_passes,
                  :translations => translation_params_shape(Level::TRANSLATABLE_FIELDS))
```

- [ ] **Step 5: Add the field to BOTH forms**

Identical block in `app/views/levels/new.html.erb` (after the `wrong_answer_penalty_in_minutes` field, before `f.submit`) **and** in `app/views/levels/edit.html.erb` (same position):

```erb
  <%# A radio pair rather than a checkbox: both rules are affirmative
      statements about the level, and a checkbox would force one of them to be
      phrased as the absence of the other. %>
  <fieldset class="field">
    <legend><%= t("levels.form.codes_rule") %></legend>
    <label><%= f.radio_button :any_code_passes, true %> <%= t("levels.codes_rule_any") %></label>
    <label><%= f.radio_button :any_code_passes, false %> <%= t("levels.codes_rule_all") %></label>
  </fieldset>
```

- [ ] **Step 6: State the rule on the level page**

In `app/views/levels/show.html.erb`, immediately after the `unless @level.multi_question? … else … end` block that renders the codes and before the "Добавить ещё один код" paragraph:

```erb
  <%# Stated for one-code levels too. Both rules behave identically there, and
      "Достаточно любого из кодов" stays true -- whereas showing the line only
      once a second code exists would mean it first appears after the author
      has already made the decision blind. That silence is the trap this
      closes. %>
  <p>
    <em><%= @level.any_code_passes? ? t("levels.codes_rule_any") : t("levels.codes_rule_all") %></em>
  </p>
```

- [ ] **Step 7: Run everything**

```bash
bundle exec rspec spec/requests/level_codes_rule_spec.rb
bundle exec rspec spec/i18n_spec.rb
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (6 examples); the full suite is **739 + 6 = 745 examples, 0 failures, 6 pending**; cucumber unchanged at **234 / 2362**.

- [ ] **Step 8: Commit**

```bash
git add app/views/levels app/controllers/levels_controller.rb config/locales \
        spec/requests/level_codes_rule_spec.rb
git commit -m "Let an author choose how a level's codes count, and say so on the page

A radio pair on both level forms -- new.html.erb and edit.html.erb each carry
their own copy of the form, so the field goes in both.

The level page now states the rule, including on single-code levels. That is
the part that closes the trap: a list of three codes previously said nothing
about whether the team needed all of them, and the answer was discoverable
only by playing."
```

---

### Task 3: Changing the mode mid-game

**Files:**
- Modify: `app/models/level.rb`
- Modify: `app/controllers/interventions_controller.rb`
- Modify: `config/routes.rb` (after line 128, with the other intervention routes)
- Modify: `app/views/game_passings/index.html.erb`
- Modify: `config/locales/{ru,en,uk,ka}.yml`
- Test: `spec/requests/level_code_mode_intervention_spec.rb`

**Interfaces:**
- Consumes: `Level#any_code_passes` (Task 1), the locale keys from Task 2.
- Produces: `Level#allow_any_code!`, `Level#require_all_codes!`; routes `allow_any_code_level_path`, `require_all_codes_level_path`.

- [ ] **Step 1: Write the failing spec**

Create `spec/requests/level_code_mode_intervention_spec.rb`:

```ruby
require "rails_helper"

describe "an operator changing how a level's codes count mid-game", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author) }
  let(:level)      { create_level(:game => game) }

  before do
    level
    game.update_column(:starts_at, 1.hour.ago)
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "lets a superadmin require all codes on a live game" do
    level.update_column(:any_code_passes, true)
    sign_in(superadmin)

    post require_all_codes_level_path(:game_id => game.id, :id => level.id)

    expect(level.reload.any_code_passes).to be false
  end

  it "lets a superadmin allow any code on a live game" do
    level.update_column(:any_code_passes, false)
    sign_in(superadmin)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(level.reload.any_code_passes).to be true
  end

  # Deliberately narrower than every other action in this controller, which use
  # ensure_author (meaning "the author, or any superadmin"). This one changes
  # the difficulty of a race already in progress, for every team at once, after
  # some have committed effort to the harder rule.
  it "refuses the game's own author" do
    level.update_column(:any_code_passes, false)
    sign_in(author)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(response).to have_http_status(:unauthorized)
    expect(level.reload.any_code_passes).to be false
  end

  it "refuses an unrelated user" do
    sign_in(create_user)

    post allow_any_code_level_path(:game_id => game.id, :id => level.id)

    expect(response).to have_http_status(:unauthorized)
  end

  describe "the audit trail" do
    it "records the action against the level" do
      sign_in(superadmin)

      expect { post allow_any_code_level_path(:game_id => game.id, :id => level.id) }
        .to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("allow_any_code")
      expect(entry.target_type).to eq("Level")
      expect(entry.target_label).to eq(level.name)
    end

    # The case the controller's own audit() helper would silently skip: it is
    # gated by acting_as_operator?, which is false when the superadmin owns the
    # game. This action is superadmin-only, so that is exactly the case an
    # audit trail exists for -- actor and beneficiary being the same person.
    it "records a superadmin acting on their own game" do
      own = create_game(:author => superadmin)
      own_level = create_level(:game => own)
      own.update_column(:starts_at, 1.hour.ago)
      sign_in(superadmin)

      expect { post allow_any_code_level_path(:game_id => own.id, :id => own_level.id) }
        .to change { AdminAction.count }.by(1)
    end
  end

  it "refuses to require all codes on a level with no codes" do
    level.questions.destroy_all
    sign_in(superadmin)

    post require_all_codes_level_path(:game_id => game.id, :id => level.reload.id)

    # InterventionsController#refused redirects with :alert, not :notice.
    expect(response).to redirect_to(game_stats_path(game))
    expect(flash[:alert]).to eq(I18n.t("interventions.refused"))
    expect(level.reload.any_code_passes).to be true
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bundle exec rspec spec/requests/level_code_mode_intervention_spec.rb
```

Expected: failures on undefined route helpers.

- [ ] **Step 3: Add the model methods**

In `app/models/level.rb`, after `wrong_answer_penalty_in_minutes=`:

```ruby
  # Operator entry points, called by InterventionsController. That controller
  # keeps a standing rule -- "every action calls a named model method ...
  # nothing here writes a column directly" -- and these exist to honour it.
  #
  # update_column, not update!: a level belonging to a running game cannot pass
  # its game's validations (game_starts_in_the_future fires once starts_at is
  # past and author_finished_at is nil), so an ordinary write would 422.
  def allow_any_code!
    update_column(:any_code_passes, true)
  end

  def require_all_codes!
    # "All of nothing" is not a rule a team could satisfy. ArgumentError is the
    # refusal channel InterventionsController already rescues.
    raise ArgumentError, "level has no codes" if questions.empty?

    update_column(:any_code_passes, false)
  end
```

- [ ] **Step 4: Add the routes**

In `config/routes.rb`, immediately after line 128 (`reset_team_clock`):

```ruby
  # Level-scoped, unlike the team-scoped interventions above: how a level's
  # codes count is a property of the level, not of one team's passing.
  post "/games/:game_id/levels/:id/allow_any_code",    to: "interventions#allow_any_code",    as: :allow_any_code_level
  post "/games/:game_id/levels/:id/require_all_codes", to: "interventions#require_all_codes", as: :require_all_codes_level
```

- [ ] **Step 5: Add the controller actions**

In `app/controllers/interventions_controller.rb`, add to the filters:

```ruby
  # Deliberately narrower than ensure_author, which every other action here
  # uses and which means "the author, or any superadmin". Changing how codes
  # count alters the difficulty of a race already in progress, for every team
  # at once, after some have committed effort to the harder rule. An operator
  # doing that leaves an audited entry and is answerable for it; an author
  # doing it to their own live game is the same act with none of that.
  before_action :require_superadmin!, only: [ :allow_any_code, :require_all_codes ]
  before_action :find_level,          only: [ :allow_any_code, :require_all_codes ]
```

The actions:

```ruby
  def allow_any_code
    @level.allow_any_code!
    audit_level("allow_any_code")
    back_to_stats(t("interventions.any_code_notice", :name => @level.name))
  end

  def require_all_codes
    @level.require_all_codes!
    audit_level("require_all_codes")
    back_to_stats(t("interventions.all_codes_notice", :name => @level.name))
  end
```

And, in the private section:

```ruby
  # Scoped through the game, so a level id belonging to another game 404s.
  def find_level
    @level = @game.levels.find(params[:id])
  end

  # record_admin_action directly, NOT through audit() above. That helper is
  # gated by acting_as_operator?, which is false when the superadmin owns the
  # game -- correct for pause and move, which an author may also perform, but
  # wrong here. These two actions are reachable only by a superadmin, so going
  # through audit() would record nothing in precisely the case an audit trail
  # exists for: actor and beneficiary being the same person.
  #
  # The target is the LEVEL, not the game, so the entry names which level
  # changed.
  def audit_level(action)
    record_admin_action(action, @level)
  end
```

- [ ] **Step 6: Add the operator controls**

In `app/views/game_passings/index.html.erb`, after the existing pause/resume `.game-control` paragraph:

```erb
<%# Superadmins only, matching InterventionsController's filter. Only
    multi-code levels appear: on a one-code level both rules behave
    identically, so a control there would be a button that changes nothing. %>
<% if logged_in? && current_user.superadmin? %>
  <% adjustable = @game.levels.select(&:multi_question?) %>
  <% if adjustable.any? %>
    <fieldset class="card">
      <legend><%= t("game_passings.index.level_codes_legend") %></legend>
      <% adjustable.each do |level| %>
        <p class="game-control">
          <strong><%= level.name %></strong>
          <em><%= level.any_code_passes? ? t("levels.codes_rule_any") : t("levels.codes_rule_all") %></em>
          <% if level.any_code_passes? %>
            <%= button_to t("game_passings.index.require_all_codes"),
                          require_all_codes_level_path(:game_id => @game.id, :id => level.id),
                          :method => :post, :class => "btn" %>
          <% else %>
            <%= button_to t("game_passings.index.allow_any_code"),
                          allow_any_code_level_path(:game_id => @game.id, :id => level.id),
                          :method => :post, :class => "btn" %>
          <% end %>
        </p>
      <% end %>
    </fieldset>
  <% end %>
<% end %>
```

- [ ] **Step 7: Add the locale keys, all four files**

Under `interventions:`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `any_code_notice` | `На уровне «%{name}» теперь достаточно любого кода` | `Any one code now passes the level “%{name}”` | `На рівні «%{name}» тепер достатньо будь-якого коду` | `დონეზე „%{name}“ ახლა საკმარისია ნებისმიერი კოდი` |
| `all_codes_notice` | `На уровне «%{name}» теперь нужны все коды` | `All codes are now required on the level “%{name}”` | `На рівні «%{name}» тепер потрібні всі коди` | `დონეზე „%{name}“ ახლა ყველა კოდია საჭირო` |

Under `game_passings.index:`:

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `level_codes_legend` | `Коды на уровнях` | `Codes on levels` | `Коди на рівнях` | `კოდები დონეებზე` |
| `allow_any_code` | `Достаточно любого` | `Any one passes` | `Достатньо будь-якого` | `საკმარისია ნებისმიერი` |
| `require_all_codes` | `Нужны все` | `Require all` | `Потрібні всі` | `საჭიროა ყველა` |

Under `admin.audit.index.action:` (the audit log renders `t("admin.audit.index.action.#{entry.action}", :default => entry.action)`, so a missing key degrades to the raw name rather than raising — but the log should read properly):

| key | ru | en | uk | ka |
|---|---|---|---|---|
| `allow_any_code` | `Разрешил любой код на уровне` | `Allowed any one code on a level` | `Дозволив будь-який код на рівні` | `დაუშვა ნებისმიერი კოდი დონეზე` |
| `require_all_codes` | `Потребовал все коды на уровне` | `Required all codes on a level` | `Зажадав усі коди на рівні` | `მოითხოვა ყველა კოდი დონეზე` |

- [ ] **Step 8: Run everything**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/level_code_mode_intervention_spec.rb
bundle exec rspec spec/i18n_spec.rb
bin/rails zeitwerk:check
bundle exec rspec
bundle exec cucumber
```

Expected: the new file passes (8 examples); `zeitwerk:check` prints `All is good!`; the full suite is **745 + 8 = 753 examples, 0 failures, 6 pending**; cucumber unchanged at **234 / 2362**.

- [ ] **Step 9: Commit**

```bash
git add app/models/level.rb app/controllers/interventions_controller.rb \
        config/routes.rb app/views/game_passings/index.html.erb config/locales \
        spec/requests/level_code_mode_intervention_spec.rb
git commit -m "Let a superadmin change how a level's codes count mid-game

Through InterventionsController, which already is \"operator actions on a game
being played\" and already carries the audit trail and the live-game guard. Its
standing rule that nothing there writes a column directly is honoured: both
actions call named Level methods.

require_superadmin! rather than the ensure_author every other action there
uses. Changing how codes count alters the difficulty of a race in progress for
every team at once; an operator doing that is answerable for an audited entry,
an author doing it to their own live game is the same act with none of that.

The audit call bypasses the controller's audit() helper, which is gated by
acting_as_operator? and so records nothing when the superadmin owns the game --
precisely the case an audit trail exists for."
```

---

## Definition of done

- `bundle exec rspec` — 753 examples, 0 failures, 6 pending.
- `bundle exec cucumber` — 234 scenarios (2 undefined), 2362 steps.
- `git diff --stat master -- 'features/**/*.feature'` is **empty**.
- `bin/rails zeitwerk:check` — `All is good!`.
- A newly created level passes on any one of its codes; a level created before this change still requires all of them.
- The level page states which rule applies, on every level.
- A superadmin can change the rule on a live game and the change is in the audit log; the game's own author cannot.
