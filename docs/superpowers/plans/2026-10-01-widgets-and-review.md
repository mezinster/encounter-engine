# Widgets and Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Dynarch calendar and the jQuery autocomplete with native inputs, make translation review readable, and let full-sentence validation messages render without a field name.

**Architecture:** View-level swaps (`datetime_local_field`, `<datalist>`) with the server untouched; a restyle of one table using the existing `.table--cards` and `.tag--danger`; one Rails switch (`i18n_customize_full_message`) plus per-field `format` keys, guarded by a spec that refuses a field dropping its name unless every message it can produce is a sentence.

**Tech Stack:** Rails 8, ERB, vanilla CSS, RSpec (request, plain), the `spec/support/layout_measurement.rb` headless-Chrome harness.

**Spec:** `docs/superpowers/specs/2026-10-01-widgets-and-review-design.md` — read it alongside this plan.

## Global Constraints

- Work only in the worktree `.claude/worktrees/widgets-and-review`, branch `design/widgets-and-review`.
- Prefix every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" &&`.
- Every RSpec run uses an isolated DB: `export RAILS_ENV=test DATABASE_URL="sqlite3:/tmp/claude-1000/-home-mezinster-encounter-engine/aebf2b26-bc2a-403f-b757-11277eb435e8/scratchpad/wr_taskN.sqlite3"` (N = your task) and `bin/rails db:schema:load` once first.
- **Never edit any `features/**/*.feature` file.**
- Hash rockets in Ruby; code and comments in English; user-facing strings through `t()`.
- Every new i18n key goes into **all seven** `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`, with the exact values given in the task. `en` must differ from `ru`. Never create a second copy of an existing mapping key (e.g. a second `games:`); add inside the existing one. After any locale edit run: `ruby -ryaml -e 'Dir["config/locales/*.yml"].each { |f| YAML.unsafe_load_file(f) }; puts "ok"'`.
- Never capitalise or case-change user-facing text in Ruby (`.upcase`, `.capitalize`); Turkish i/İ.
- CSS: font sizes only `var(--text-*)`, z-index only `var(--z-*)`, `@media` widths only 48rem / 47.99rem / 52rem / 60rem (`spec/stylesheets/token_discipline_spec.rb`).
- Run only the spec files your task names. Do **not** run the full RSpec or Cucumber suites; do not background processes. Layout specs: `LAYOUT_SPECS=1`, foreground.
- Undo edits with precise edits, never `head -n -N` / `sed '$d'`. Write reports with your file-writing tool, never a shell heredoc.
- Commit messages: plain imperative subject, short body, **no attribution lines**.

## Review Focus

1. **A browser-shaped datetime value** (`2050-03-21T18:01`, which no frozen scenario sends) must save in the author's own timezone and display back as `2050-03-21 18:01` — Task 2 pins it with a non-UTC author.
2. **The edit form's prefilled value** must be `YYYY-MM-DDTHH:MM` with no seconds, or browsers show an empty or seconds-bearing control on edit — Task 2 pins it.
3. **A nickname containing `"` or `</datalist>`** must render as inert text in the datalist — Task 3 pins it.
4. **A future validator with no sentence message** on one of the 19 fields must fail CI rather than render a nounless predicate — Task 1's spec, mutation-tested.
5. **A long, flagged proposal on a phone** must stay inside its card with the danger edge visible — Task 4's layout spec.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `config/application.rb` | `i18n_customize_full_message` | 1 |
| `config/locales/*.yml` (7) | 19 `format` keys; one rewritten message; 2 hint keys; 4 column keys | 1, 2, 4 |
| `spec/i18n_spec.rb` | structural `.format` exemption | 1 |
| `spec/i18n_sentence_messages_spec.rb` (new) | the sentence-format safety rule | 1 |
| `spec/requests/sentence_errors_spec.rb` (new) | summary renders sentences bare | 1 |
| `app/views/games/{new,edit}.html.erb` | datetime-local fields, hint; calendar removed | 2 |
| `app/views/games/_timezone_hint.html.erb` (new) | the hint, once | 2 |
| `public/javascripts/calendar*.js`, `public/stylesheets/calendar.css`, 9 gifs | deleted | 2 |
| `spec/requests/game_dates_form_spec.rb` (new) | inputs, hint, browser-shaped value | 2 |
| `spec/assets_retired_spec.rb` (new, extended in 3) | no references to deleted assets | 2, 3 |
| `app/views/admin/styleguide/show.html.erb` | datetime specimen gets a value | 2 |
| `app/views/invitations/new.html.erb` | datalist; scripts removed | 3 |
| `public/javascripts/jquery.autocomplete.js`, `public/stylesheets/jquery.autocomplete.css` | deleted | 3 |
| `spec/requests/invitation_datalist_spec.rb` (new) | datalist, privacy, escaping | 3 |
| `app/views/translation_proposals/index.html.erb` | header, data-labels, tag classes | 4 |
| `public/stylesheets/screens.css` | `.proposals` block | 4 |
| `spec/requests/translation_review_markup_spec.rb` (new) | markup hooks | 4 |
| `spec/layout/translation_review_layout_spec.rb` (new) | measured in both themes | 4 |
| `CLAUDE.md` | docs | 5 |

---

### Task 1: Full-sentence errors without a field name

**Files:**
- Modify: `config/application.rb` (after `config.i18n.available_locales = …`)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` (`activerecord.errors.models.*.attributes.*`)
- Modify: `spec/i18n_spec.rb` (the "untranslated copy" example)
- Create: `spec/i18n_sentence_messages_spec.rb`
- Create: `spec/requests/sentence_errors_spec.rb`

**Interfaces:**
- Produces: `config.active_model.i18n_customize_full_message = true`; key shape `activerecord.errors.models.<model>.attributes.<attr>.format: "%{message}"`.

- [ ] **Step 1: Write the failing request spec**

`spec/requests/sentence_errors_spec.rb`:

```ruby
require "rails_helper"

# Merb-era messages are whole sentences ("Вы не ввели имя"). Rails' summary
# composes "%{attribute} %{message}", so they rendered as "Nickname Вы не ввели
# имя". With per-field formats the sentence stands alone. Literals pinned, not
# I18n.t(...), which would pass even if the key went missing.
describe "full-sentence error messages", type: :request do
  let(:summary_items) { Nokogiri::HTML(response.body).css("div.error li").map { |li| li.text.strip } }

  it "renders the signup nickname message without a field name" do
    post users_path, :params => { :user => { :nickname => "", :email => "sentence@example.com" } }

    expect(summary_items).to include("Вы не ввели имя")
    expect(summary_items.join).not_to include("Nickname")
  end

  it "renders the game name message without a field name" do
    author = create_user
    put login_path, :params => { :email => author.email, :password => "1234" }
    post games_path, :params => { :game => { :name => "", :description => "x", :max_team_number => "2" } }

    expect(summary_items).to include("Вы не ввели название")
    expect(summary_items).not_to include(a_string_starting_with("Название "))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/sentence_errors_spec.rb`
Expected: 2 failures — items are `"Nickname Вы не ввели имя"` and `"Название Вы не ввели название"` (or the English column name).

- [ ] **Step 3: Write the failing safety spec**

`spec/i18n_sentence_messages_spec.rb`:

```ruby
require "rails_helper"

# A field whose `format` is "%{message}" renders its messages with no field
# name. That is only safe if EVERY message the field can produce is a whole
# sentence -- otherwise a stock rails-i18n predicate ("слишком длинный") from a
# future validator would render with no noun at all. See the 2026-10-01
# widgets-and-review spec, §4.4.
describe "full-sentence validation messages" do
  SENTENCE_FIELDS = {
    "answer"     => %w[value],
    "game"       => %w[name description max_team_number starts_at registration_deadline],
    "game_entry" => %w[game team_id],
    "invitation" => %w[for_user recepient_nickname for_user_id],
    "level"      => %w[name text],
    "team"       => %w[name],
    "user"       => %w[email nickname password password_confirmation]
  }.freeze

  SENTENCE_NUMERIC_KEYS = %w[greater_than greater_than_or_equal_to less_than
                    less_than_or_equal_to equal_to other_than odd even].freeze

  def locale_tree(locale)
    YAML.unsafe_load_file(Rails.root.join("config/locales/#{locale}.yml"))[locale]
      .dig("activerecord", "errors", "models")
  end

  # The message keys a validator can raise, and the field they land on.
  def expected_keys(validator, attr)
    custom = validator.options[:message]
    return [[attr, custom.to_s]] if custom.is_a?(Symbol)
    return [] if custom.is_a?(String) # literal: checked separately below

    case validator.kind
    when :presence     then [[attr, "blank"]]
    when :uniqueness   then [[attr, "taken"]]
    when :format       then [[attr, "invalid"]]
    when :inclusion    then [[attr, "inclusion"]]
    when :confirmation then [["#{attr}_confirmation", "confirmation"]]
    when :length
      o = validator.options
      keys = []
      keys << "too_short"    if o[:minimum] || o[:in] || o[:within]
      keys << "too_long"     if o[:maximum] || o[:in] || o[:within]
      keys << "wrong_length" if o[:is]
      keys.map { |k| [attr, k] }
    when :numericality
      keys = ["not_a_number"] + (validator.options.keys.map(&:to_s) & SENTENCE_NUMERIC_KEYS)
      keys << "not_an_integer" if validator.options[:only_integer]
      keys.map { |k| [attr, k] }
    else
      [[attr, "(unmapped validator kind: #{validator.kind})"]]
    end
  end

  %w[ru en].each do |locale|
    context "in #{locale}.yml" do
      let(:models) { locale_tree(locale) }

      it "gives exactly the audited fields a bare-message format" do
        bare = models.flat_map do |model, h|
          (h["attributes"] || {}).select { |_, msgs| msgs.is_a?(Hash) && msgs["format"] == "%{message}" }
                                 .keys.map { |attr| "#{model}.#{attr}" }
        end
        expected = SENTENCE_FIELDS.flat_map { |m, attrs| attrs.map { |a| "#{m}.#{a}" } }
        expect(bare).to match_array(expected)
      end

      it "writes every message of those fields as a sentence" do
        lowercase = SENTENCE_FIELDS.flat_map do |model, attrs|
          attrs.flat_map do |attr|
            (models.dig(model, "attributes", attr) || {}).except("format")
              .reject { |_, text| text.to_s.match?(/\A\p{Lu}/) }
              .map { |key, text| "#{model}.#{attr}.#{key}: #{text}" }
          end
        end
        expect(lowercase).to eq([]), "not a sentence:\n#{lowercase.join("\n")}"
      end

      it "has a sentence for every message a validator on those fields can raise" do
        missing = SENTENCE_FIELDS.flat_map do |model, attrs|
          klass = model.camelize.constantize
          attrs.flat_map do |attr|
            klass.validators_on(attr.to_sym).flat_map do |validator|
              literal = validator.options[:message]
              if literal.is_a?(String)
                literal.match?(/\A\p{Lu}/) ? [] : ["#{model}.#{attr}: literal message #{literal.inspect}"]
              else
                expected_keys(validator, attr).reject { |field, key| models.dig(model, "attributes", field, key) }
                                              .map { |field, key| "#{model}.#{field}.#{key} (#{validator.kind})" }
              end
            end
          end
        end
        expect(missing).to eq([]), "missing sentence message:\n#{missing.join("\n")}"
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bundle exec rspec spec/i18n_sentence_messages_spec.rb`
Expected: "gives exactly the audited fields" fails in both locales (no `format` keys yet, `bare` is `[]`); "writes every message … as a sentence" fails naming `game.starts_at.needed_to_unpublish_access`; the validator example passes.

- [ ] **Step 5: Turn on per-field formats**

`config/application.rb`, directly after `config.i18n.available_locales = [:ru, :en, :uk, :ka, :tr, :be, :pl]`:

```ruby
    # Lets a field's full message drop the "%{attribute} " prefix via an
    # activerecord.errors.models.<model>.attributes.<attr>.format key. The
    # Merb-era messages are whole sentences ("Вы не ввели имя"), and without
    # this every one of them rendered as "Nickname Вы не ввели имя". Fields
    # without a `format` keep the default. spec/i18n_sentence_messages_spec.rb
    # refuses a bare format on any field that can produce a non-sentence.
    config.active_model.i18n_customize_full_message = true
```

- [ ] **Step 6: Add the 19 `format` keys to all seven locale files**

For each of these fields, under `activerecord.errors.models.<model>.attributes.<attr>:` add the line `format: "%{message}"` (as the first key under the attribute). In `ru.yml` and `en.yml` every one of these attribute mappings already exists; in the other five, if an attribute mapping is missing, create it under the existing `models.<model>.attributes:` (or the model mapping) — never a second copy of a mapping.

```
answer:      value
game:        name, description, max_team_number, starts_at, registration_deadline
game_entry:  game, team_id
invitation:  for_user, recepient_nickname, for_user_id
level:       name, text
team:        name
user:        email, nickname, password, password_confirmation
```

- [ ] **Step 7: Rewrite the one predicate as a sentence**

In each file, `activerecord.errors.models.game.attributes.starts_at.needed_to_unpublish_access` — capitalise the first letter **by hand**, nothing else changes:

| Locale | New value begins with |
|---|---|
| ru | `"У обычной игры дата старта должна быть в будущем — …"` |
| en | `"A scheduled game needs a start date in the future — …"` |
| uk | `"У звичайної гри дата старту має бути в майбутньому — …"` |
| be | `"У звычайнай гульні дата старту павінна быць у будучыні — …"` |
| pl | `"Zwykła gra musi mieć datę startu w przyszłości — …"` |
| tr | `"Programlı bir oyunun başlangıç tarihi gelecekte olmalı — …"` |
| ka | unchanged (Georgian has no letter case) |

Then run the YAML parse check from Global Constraints.

- [ ] **Step 8: Exempt structural `.format` keys from the duplicate check**

In `spec/i18n_spec.rb`, in `it "does not have en values that are an untranslated copy of their ru value"`, replace:

```ruby
    suspicious_keys = shared_keys.select do |key|
      value = en[key].to_s
      !value.strip.empty? && value == ru[key].to_s
    end
```

with:

```ruby
    suspicious_keys = shared_keys.select do |key|
      value = en[key].to_s
      # A per-field "%{message}" format is structure, not text: it is the same
      # in every language by definition. See spec/i18n_sentence_messages_spec.rb.
      next false if key.end_with?(".format") && value == "%{message}"

      !value.strip.empty? && value == ru[key].to_s
    end
```

- [ ] **Step 9: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/sentence_errors_spec.rb spec/i18n_sentence_messages_spec.rb spec/i18n_spec.rb spec/requests/signup_inline_errors_spec.rb spec/models/concerns/child_error_promotion_spec.rb`
Expected: 0 failures. If `child_error_promotion_spec` or any other example fails because it expected the *prefixed* message, update that expectation to the bare sentence and say so in your report.

- [ ] **Step 10: Mutation-test the safety spec**

Each must fail the named example; revert each with a precise edit:
1. Add `validates :nickname, :length => { :maximum => 40 }` to `app/models/user.rb` → "has a sentence for every message a validator … can raise" fails naming `user.nickname.too_long (length)`.
2. Lower-case the first letter of `ru.yml`'s `user.attributes.nickname.blank` → "writes every message … as a sentence" fails in ru.
3. Delete `ru.yml`'s `level.attributes.text.format` line → "gives exactly the audited fields" fails in ru.

Re-run Step 9's command after reverting; it must be green. `git diff --stat` must not list `app/models/user.rb`.

- [ ] **Step 11: Commit**

```bash
git add config/application.rb config/locales spec/i18n_spec.rb spec/i18n_sentence_messages_spec.rb spec/requests/sentence_errors_spec.rb
git commit -m "Show full-sentence validation messages without a field name

Turns on i18n_customize_full_message and gives the 19 Merb-era fields
whose messages are whole sentences a bare \"%{message}\" format, so
signup reads \"Вы не ввели имя\" rather than \"Nickname Вы не ввели имя\".
A new spec refuses a bare format on any field that could produce a
non-sentence, including from a validator added later."
```

---

### Task 2: Native date fields, the timezone hint, and the calendar's retirement

**Files:**
- Create: `app/views/games/_timezone_hint.html.erb`
- Modify: `app/views/games/new.html.erb` (lines 1–6 head block; 55–60 the two date fields; 110–127 the script)
- Modify: `app/views/games/edit.html.erb` (lines 1–6; 64–69; 136–153)
- Modify: `app/views/admin/styleguide/show.html.erb` (the `sg_datetime` specimen)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` (`games.form`)
- Delete: `public/javascripts/calendar.js`, `public/javascripts/calendar-setup.js`, `public/javascripts/calendar-ru-UTF.js`, `public/stylesheets/calendar.css`, `public/stylesheets/{active-bg,dark-bg,hover-bg,menuarrow,normal-bg,rowhover-bg,status-bg,title-bg,today-bg}.gif`
- Create: `spec/requests/game_dates_form_spec.rb`
- Create: `spec/assets_retired_spec.rb`

**Interfaces:**
- Produces: partial `games/timezone_hint` (no locals); keys `games.form.timezone_hint` (`%{zone}`), `games.form.timezone_change`; `spec/assets_retired_spec.rb` with a `RETIRED_ASSETS` list that Task 3 extends.

- [ ] **Step 1: Write the failing specs**

`spec/requests/game_dates_form_spec.rb`:

```ruby
require "rails_helper"

# The game form's dates are native datetime-local inputs. The server is
# unchanged; what these pin is the form and the one browser behaviour the
# frozen scenarios cannot send -- a T-separated value.
describe "the game form's date fields", type: :request do
  let(:author) { u = create_user; u.update!(:timezone => "Asia/Bishkek"); u }
  let(:doc) { Nokogiri::HTML(response.body) }

  before { put login_path, :params => { :email => author.email, :password => "1234" } }

  shared_examples "a form with native date fields" do
    it "renders both dates as datetime-local inputs" do
      expect(doc.at_css("input#game_starts_at")["type"]).to eq("datetime-local")
      expect(doc.at_css("input#game_registration_deadline")["type"]).to eq("datetime-local")
    end

    it "names the author's timezone and links to where it is set" do
      hints = doc.css("p.notice.timezone-hint")
      expect(hints.size).to eq(2)
      expect(hints.first.text).to include("Asia/Bishkek (UTC+06:00)")
      expect(hints.first.at_css("a")["href"]).to eq(edit_user_path(author))
    end

    it "loads no calendar script or stylesheet" do
      expect(response.body).not_to match(/calendar(-setup|-ru-UTF)?\.js|calendar\.css|Calendar\.setup/)
    end
  end

  context "on the new-game form" do
    before { get new_game_path }
    include_examples "a form with native date fields"
  end

  context "on the edit form" do
    let(:game) { create_game(:author => author) }
    before do
      Time.use_zone("Asia/Bishkek") { game.update!(:starts_at => Time.zone.parse("2050-03-21 18:01")) }
      get edit_game_path(game)
    end
    include_examples "a form with native date fields"

    it "prefills the start in the author's zone, to the minute" do
      expect(doc.at_css("input#game_starts_at")["value"]).to eq("2050-03-21T18:01")
    end
  end

  it "accepts the T-separated value a browser sends, in the author's zone" do
    post games_path, :params => { :game => { :name => "Ночной город", :description => "Старт у ЦУМа",
                                             :starts_at => "2050-03-21T18:01", :max_team_number => "2" } }
    follow_redirect!

    expect(response.body).to include("2050-03-21 18:01")
    game = Game.find_by!(:name => "Ночной город")
    expect(game.starts_at.in_time_zone("Asia/Bishkek").strftime("%Y-%m-%d %H:%M")).to eq("2050-03-21 18:01")
  end
end
```

`spec/assets_retired_spec.rb`:

```ruby
require "rails_helper"

# Vendored widgets this repository has retired. A later revert of one view
# must not quietly reintroduce a <script src> or <link> to a deleted file.
describe "retired assets" do
  RETIRED_ASSETS = %w[
    calendar.js calendar-setup.js calendar-ru-UTF.js calendar.css
    active-bg.gif dark-bg.gif hover-bg.gif menuarrow.gif normal-bg.gif
    rowhover-bg.gif status-bg.gif title-bg.gif today-bg.gif
  ].freeze

  it "are gone from disk" do
    present = RETIRED_ASSETS.select { |name| Dir[Rails.root.join("public/**/#{name}")].any? }
    expect(present).to eq([])
  end

  it "are referenced nowhere in app/ or public/" do
    files = Dir[Rails.root.join("{app,public}/**/*.{erb,rb,js,css,html}")]
    hits = files.flat_map do |path|
      text = File.read(path)
      RETIRED_ASSETS.select { |name| text.include?(name) }.map { |name| "#{path.sub("#{Rails.root}/", "")}: #{name}" }
    end
    expect(hits).to eq([])
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/requests/game_dates_form_spec.rb spec/assets_retired_spec.rb`
Expected: the type, hint and calendar examples fail (inputs are `text`, no hint, calendar loaded); the prefill example fails (text value); the T-separated example **passes** already — it documents unchanged server behaviour; both retired-asset examples fail.

- [ ] **Step 3: Add the hint keys**

Under the existing `games.form:` mapping in each file:

| Locale | `timezone_hint` | `timezone_change` |
|---|---|---|
| ru | `"Время указывается в вашем часовом поясе: %{zone}."` | `"Изменить в профиле"` |
| en | `"Times are in your time zone: %{zone}."` | `"Change it in your profile"` |
| uk | `"Час вказується у вашому часовому поясі: %{zone}."` | `"Змінити в профілі"` |
| be | `"Час указваецца ў вашым часавым поясе: %{zone}."` | `"Змяніць у профілі"` |
| pl | `"Godziny podawane są w Twojej strefie czasowej: %{zone}."` | `"Zmień w profilu"` |
| tr | `"Saatler sizin saat diliminizdedir: %{zone}."` | `"Profilden değiştirin"` |
| ka | `"დრო მითითებულია თქვენს სასაათო სარტყელში: %{zone}."` | `"პროფილში შეცვლა"` |

- [ ] **Step 4: The hint partial**

`app/views/games/_timezone_hint.html.erb`:

```erb
<%# datetime-local carries no zone. TimeZoneSelection runs every request in
    the signed-in user's zone, so a typed 18:00 means 18:00 THERE -- this says
    which zone that is. The offset is for now, so it is right across DST. Both
    game forms are author-only, so there is always a profile to link to. %>
<p class="notice timezone-hint">
  <%= t("games.form.timezone_hint", :zone => "#{Time.zone.tzinfo.name} (UTC#{Time.zone.now.formatted_offset})") %>
  <%= link_to t("games.form.timezone_change"), edit_user_path(current_user) %>
</p>
```

- [ ] **Step 5: The fields, in both views**

In `app/views/games/new.html.erb` **and** `app/views/games/edit.html.erb`:

1. Delete the whole `<% content_for :head do %> … <% end %>` block at the top (the three calendar scripts and `calendar.css`).
2. Replace

```erb
    <%= f.text_field :starts_at %> <input id="calendar-switch" type="button" value="..." class="btn" />
```

with

```erb
    <%= f.datetime_local_field :starts_at, :include_seconds => false %>
    <%= render "games/timezone_hint" %>
```

3. Replace

```erb
    <%= f.text_field :registration_deadline %> <input id="calendar-switch2" type="button" value="..." class="btn" />
```

with

```erb
    <%= f.datetime_local_field :registration_deadline, :include_seconds => false %>
    <%= render "games/timezone_hint" %>
```

4. Delete the trailing `<script type="text/javascript"> Calendar.setup(…); Calendar.setup(…); </script>` block (new: lines 110–127; edit: lines 136–153) — and nothing else around it.

- [ ] **Step 6: Delete the calendar assets**

```bash
git rm public/javascripts/calendar.js public/javascripts/calendar-setup.js public/javascripts/calendar-ru-UTF.js \
       public/stylesheets/calendar.css \
       public/stylesheets/active-bg.gif public/stylesheets/dark-bg.gif public/stylesheets/hover-bg.gif \
       public/stylesheets/menuarrow.gif public/stylesheets/normal-bg.gif public/stylesheets/rowhover-bg.gif \
       public/stylesheets/status-bg.gif public/stylesheets/title-bg.gif public/stylesheets/today-bg.gif
```

- [ ] **Step 7: Give the styleguide's date specimen a value**

In `app/views/admin/styleguide/show.html.erb`, change `<input type="datetime-local" id="sg_datetime">` to `<input type="datetime-local" id="sg_datetime" value="2050-03-21T18:01">`.

- [ ] **Step 8: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/game_dates_form_spec.rb spec/assets_retired_spec.rb spec/i18n_spec.rb spec/requests/admin_styleguide_spec.rb` (YAML parse check first).
Expected: 0 failures. Then `LAYOUT_SPECS=1 bundle exec rspec spec/layout/styleguide_layout_spec.rb` — 0 failures (the date specimen now has a value and must pass contrast and type scale).

- [ ] **Step 9: Commit**

```bash
git add -A app/views/games app/views/admin/styleguide config/locales public spec/requests/game_dates_form_spec.rb spec/assets_retired_spec.rb
git commit -m "Use native date-time inputs on the game form, and say which timezone

Replaces the Dynarch calendar -- light-only gif chrome, Russian in every
locale -- with datetime-local fields, adds a hint naming the author's
timezone with a link to change it, and deletes the calendar's three
scripts, stylesheet and nine gifs. The server's parsing is unchanged."
```

(`git status` first: only the files listed above, including the deletions.)

---

### Task 3: The invitation datalist, and the autocomplete's retirement

**Files:**
- Modify: `app/views/invitations/new.html.erb` (whole top half: head block, JSON block, script)
- Delete: `public/javascripts/jquery.autocomplete.js`, `public/stylesheets/jquery.autocomplete.css`
- Modify: `spec/assets_retired_spec.rb` (extend `RETIRED_ASSETS`)
- Create: `spec/requests/invitation_datalist_spec.rb`

**Interfaces:**
- Consumes: `spec/assets_retired_spec.rb`'s `RETIRED_ASSETS` (Task 2).
- Produces: `<datalist id="invitation-nicknames">`; the field's `list="invitation-nicknames"`.

- [ ] **Step 1: Write the failing spec**

`spec/requests/invitation_datalist_spec.rb`:

```ruby
require "rails_helper"

# The invitation page offers every other user's nickname through a native
# <datalist>. Nicknames only -- emails were removed from this page as a
# security fix (any captain can open it, and captaincy is self-service).
describe "the invitation nickname list", type: :request do
  let(:captain) { create_user }
  let!(:other)  { create_user }
  let(:doc)     { Nokogiri::HTML(response.body) }

  before do
    create_team(:captain => captain)
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  it "links the nickname field to a datalist of the other users" do
    get new_invitation_path

    field = doc.at_css("input#invitation_recepient_nickname")
    expect(field["list"]).to eq("invitation-nicknames")
    values = doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }
    expect(values).to include(other.nickname)
    expect(values).not_to include(captain.nickname)
  end

  it "exposes no user's e-mail address" do
    get new_invitation_path

    User.find_each { |u| expect(response.body).not_to include(u.email) }
  end

  it "renders a hostile nickname as inert text" do
    other.update!(:nickname => %q{x" onmouseover="alert(1)</datalist><b>})
    get new_invitation_path

    expect(doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }).to include(other.nickname)
    expect(doc.at_css("b")).to be_nil
    expect(doc.css("[onmouseover]")).to be_empty
  end

  # Carried over from the retired invitations_autocomplete_spec.rb: a nickname
  # ending in a backslash once escaped the closing quote of a JS string literal
  # and put the next value in executable position. In an attribute there is no
  # string literal to escape, and the value must survive byte for byte.
  it "keeps a backslash nickname literal" do
    other.update!(:nickname => "evil\\")
    get new_invitation_path

    expect(doc.css("datalist#invitation-nicknames option").map { |o| o["value"] }).to include("evil\\")
  end

  it "loads no jQuery or autocomplete plugin" do
    get new_invitation_path

    expect(response.body).not_to match(/jquery(\.autocomplete)?\.(js|css)/)
    expect(doc.css("script[type='application/json']")).to be_empty
  end
end
```

**Retire `spec/requests/invitations_autocomplete_spec.rb` in Step 4** (it pins the JSON island and the plugin's `formatItem`, both deleted). Every protection it holds is carried into the new file:

| Old example | Carried by |
|---|---|
| backslash nickname cannot break out of the payload | "keeps a backslash nickname literal" |
| script-closing nickname cannot break out of the JSON island | "renders a hostile nickname as inert text" (`</datalist><b>`) |
| does not emit any user's email address | "exposes no user's e-mail address" |
| still offers the other users' nicknames | "links the nickname field to a datalist of the other users" |
| escapes suggestion markup before the plugin renders it | obsolete — the browser renders `<option>` values as text; no plugin, no `formatItem` |

Extend `spec/assets_retired_spec.rb`'s list (keep the existing entries, add these two at the end of the `%w[ … ]`):

```
    jquery.autocomplete.js jquery.autocomplete.css
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/requests/invitation_datalist_spec.rb spec/assets_retired_spec.rb`
Expected: the datalist, hostile-nickname, backslash and no-jQuery examples fail; the e-mail example passes already (it documents the existing fix); both retired-asset examples fail on the two new names.

- [ ] **Step 3: Rewrite the top of the view**

In `app/views/invitations/new.html.erb`, replace everything from the first line down to (not including) `<%= error_messages_for @invitation %>` — the `content_for :head` block, the comment, the JSON `<script>` and the `$(document).ready` script — with nothing, and replace the form with:

```erb
<%= error_messages_for @invitation %>

<%= form_with model: @invitation, url: invitations_path do |f| %>
  <div class="field">
    <%= f.label :recepient_nickname, t("invitations.new.recipient_label") %>
    <%# Suggestions come from a native <datalist>: the browser matches and
        renders them, on phones as the system suggestion strip, with scripts
        blocked too. Each nickname is an attribute value written by the tag
        helper, escaped by default, so there is no JavaScript context to break
        out of (the old JSON block existed because there was one).

        Emails are deliberately absent: this page is reachable by any team
        captain, and captaincy is self-service, so shipping the whole user
        table's email addresses here handed out the instance's complete
        login-identifier list. %>
    <%= f.text_field :recepient_nickname, :list => "invitation-nicknames", :autocomplete => "off" %>
    <datalist id="invitation-nicknames">
      <% @all_users.reject { |user| user == @current_user }.each do |user| %>
        <%= tag.option(:value => user.nickname) %>
      <% end %>
    </datalist>
  </div>
  <%= f.submit t("invitations.new.submit"), class: "btn btn--go" %>
<% end %>
```

- [ ] **Step 4: Delete the plugin**

```bash
git rm public/javascripts/jquery.autocomplete.js public/stylesheets/jquery.autocomplete.css \
       spec/requests/invitations_autocomplete_spec.rb
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/invitation_datalist_spec.rb spec/assets_retired_spec.rb` and then `bundle exec cucumber features/invitations` (the frozen invitation scenarios type into the field by label; they must stay green — this is the one Cucumber directory this task may run).
Expected: 0 failures; Cucumber's invitation scenarios all pass.

- [ ] **Step 6: Commit**

```bash
git add -A app/views/invitations public spec/requests/invitation_datalist_spec.rb spec/assets_retired_spec.rb spec/requests/invitations_autocomplete_spec.rb
git commit -m "Suggest invitation nicknames with a native datalist

Replaces the jQuery autocomplete plugin with a <datalist> of the same
nickname list -- still no emails -- escaped by the tag helper instead of
a hand-built JavaScript context. The page now loads no script at all."
```

---

### Task 4: Translation review, restyled in place

**Files:**
- Modify: `app/views/translation_proposals/index.html.erb` (`<table class="proposals">` … `</table>`)
- Modify: `public/stylesheets/screens.css` (append a block at the end)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` (`translations.review`)
- Create: `spec/requests/translation_review_markup_spec.rb`
- Create: `spec/layout/translation_review_layout_spec.rb`

**Interfaces:**
- Consumes: `.table--cards` (components.css: stacks rows into cards below 48rem using each cell's `data-label`), `.tag`, `.tag--danger`.
- Produces: keys `translations.review.columns.{locale,field,source,proposal}`.

- [ ] **Step 1: Add the column keys**

Under the existing `translations.review:` mapping in each file, add a `columns:` mapping:

| Locale | `locale` | `field` | `source` | `proposal` |
|---|---|---|---|---|
| ru | `"Язык"` | `"Поле"` | `"Оригинал"` | `"Перевод"` |
| en | `"Language"` | `"Field"` | `"Source"` | `"Proposal"` |
| uk | `"Мова"` | `"Поле"` | `"Оригінал"` | `"Переклад"` |
| be | `"Мова"` | `"Поле"` | `"Арыгінал"` | `"Пераклад"` |
| pl | `"Język"` | `"Pole"` | `"Oryginał"` | `"Tłumaczenie"` |
| tr | `"Dil"` | `"Alan"` | `"Kaynak"` | `"Öneri"` |
| ka | `"ენა"` | `"ველი"` | `"ორიგინალი"` | `"თარგმანი"` |

- [ ] **Step 2: Write the failing request spec**

`spec/requests/translation_review_markup_spec.rb`:

```ruby
require "rails_helper"

describe "the translation review table", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)  { create_game(:author => create_user, :is_draft => true, :primary_locale => "ru",
                            :available_locale_list => %w[ru en]) }
  let(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }
  let(:run)   { TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                                       :state => TranslationRun::SUCCEEDED) }
  let(:doc)   { Nokogiri::HTML(response.body) }

  before do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "text",
                                :locale => "en", :source_text => "Найдите табличку",
                                :proposed_text => "Найдите табличку", :flags => "identical",
                                :state => "pending")
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "name",
                                :locale => "en", :source_text => "Первый",
                                :proposed_text => "First", :state => "pending")
    put login_path, :params => { :email => superadmin.email, :password => "1234" }
    get game_translation_run_proposals_path(game, run)
  end

  it "has a header and stacks into cards on phones" do
    expect(doc.at_css("table.proposals.table--cards thead")).to be_present
    expect(doc.css("table.proposals thead th").map(&:text).map(&:strip))
      .to eq(%w[Язык Поле Оригинал Перевод])
  end

  it "labels every cell for the stacked layout" do
    cells = doc.css("table.proposals tbody td")
    expect(cells).not_to be_empty
    expect(cells.reject { |td| td["data-label"].present? }).to be_empty
  end

  it "marks a flagged proposal's row and draws its flags as danger tags" do
    flagged = doc.css("table.proposals tbody tr.flagged")
    expect(flagged.size).to eq(1)
    expect(flagged.first.css("ul.flags li.tag.tag--danger").size).to eq(1)
    expect(doc.css("table.proposals tbody tr:not(.flagged)").size).to eq(1)
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/translation_review_markup_spec.rb spec/requests/translation_views_spec.rb`
Expected: the three new examples fail (no `table--cards`, no `thead`, no `data-label`, no tag classes); `translation_views_spec.rb` passes.

- [ ] **Step 4: The markup**

In `app/views/translation_proposals/index.html.erb`:

1. `<table class="proposals">` → `<table class="proposals table--cards">`, and directly after it add:

```erb
  <thead>
    <tr>
      <th><%= t("translations.review.columns.locale") %></th>
      <th><%= t("translations.review.columns.field") %></th>
      <th><%= t("translations.review.columns.source") %></th>
      <th><%= t("translations.review.columns.proposal") %></th>
    </tr>
  </thead>
  <tbody>
```

and add `</tbody>` directly before `</table>`.

2. Give each of the four `<td>` in the row its label (the opening tags only change; contents and comments stay):

```erb
      <td class="locale" data-label="<%= t("translations.review.columns.locale") %>">
      <td class="field" data-label="<%= t("translations.review.columns.field") %>">
      <td class="source" data-label="<%= t("translations.review.columns.source") %>">
      <td class="proposal" data-label="<%= t("translations.review.columns.proposal") %>">
```

(The first two `<td>`s are currently one-liners `<td><%= … %></td>` — keep their content on the same line.)

3. `<li><%= t("translations.flags.#{flag}") %></li>` → `<li class="tag tag--danger"><%= t("translations.flags.#{flag}") %></li>`.

- [ ] **Step 5: The CSS**

Append to `public/stylesheets/screens.css`:

```css
/* --- Translation review (translation_proposals/index) --------------------
 * A superadmin reviewing a language they may not read: the flags are the
 * safety story (Translation::Flags), so a flagged proposal must be visible
 * before any text is read -- by shape as well as colour, per the palette's
 * standing rule. The table stacks into cards below 48rem (.table--cards). */
table.proposals td { vertical-align: top; }
table.proposals td.locale,
table.proposals td.field { color: var(--text-dim); font-size: var(--text-sm); white-space: nowrap; }
table.proposals td.source {
  width: 40%;
  background: var(--surface-2);
  border-radius: var(--radius-sm);
  /* The source's line breaks are content the translation must keep. */
  white-space: pre-wrap;
}
table.proposals tr.flagged > td:first-child { box-shadow: inset 3px 0 0 var(--danger); }
table.proposals ul.flags {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-1);
  margin: var(--space-2) 0;
  list-style: none;
}
table.proposals .accepted strong { color: var(--text-dim); font-size: var(--text-sm); }

@media (max-width: 47.99rem) {
  table.proposals td.source { width: auto; }
  table.proposals td.locale,
  table.proposals td.field { white-space: normal; }
  /* In the stacked layout the card itself carries the edge. */
  table.proposals tr.flagged { border-left: 3px solid var(--danger); }
  table.proposals tr.flagged > td:first-child { box-shadow: none; }
}
```

- [ ] **Step 6: Run the request specs to verify they pass**

Run: `bundle exec rspec spec/requests/translation_review_markup_spec.rb spec/requests/translation_views_spec.rb spec/requests/translation_proposal_review_spec.rb spec/stylesheets/token_discipline_spec.rb spec/i18n_spec.rb`
Expected: 0 failures.

- [ ] **Step 7: Write the layout spec**

`spec/layout/translation_review_layout_spec.rb`:

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# Translation review, measured. A flagged proposal must be identifiable by its
# edge in both layouts, the page must not scroll sideways, and on a phone each
# proposal must be a card. Excluded from the default run; LAYOUT_SPECS=1.
describe "the translation review table, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    admin = create_user
    admin.update!(:is_superadmin => true)
    game  = create_game(:author => create_user, :is_draft => true, :primary_locale => "ru",
                        :available_locale_list => %w[ru en])
    level = create_level(:game => game, :name => "Первый",
                         :text => "Найдите табличку на здании с часами. " * 12)
    run   = TranslationRun.create!(:game => game, :actor => admin, :model => "claude-opus-5",
                                   :state => TranslationRun::SUCCEEDED)
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "text",
                                :locale => "en", :source_text => level.text,
                                :proposed_text => level.text, :flags => "identical,length",
                                :state => "pending")
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "name",
                                :locale => "en", :source_text => "Первый", :proposed_text => "First",
                                :state => "pending")
    put login_path, :params => { :email => admin.email, :password => "1234" }
    get game_translation_run_proposals_path(game, run)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var probe = document.createElement("span");
      probe.style.color = "var(--danger)";
      document.body.appendChild(probe);
      var danger = getComputedStyle(probe).color;
      probe.remove();

      function edge(tr) {
        var s = getComputedStyle(tr);
        if (s.borderLeftWidth !== "0px" && s.borderLeftStyle !== "none") return s.borderLeftColor;
        var shadow = getComputedStyle(tr.cells[0]).boxShadow;
        return shadow === "none" ? "none" : shadow;
      }
      var flagged = Array.prototype.slice.call(document.querySelectorAll("table.proposals tbody tr.flagged"));
      var clean = Array.prototype.slice.call(document.querySelectorAll("table.proposals tbody tr:not(.flagged)"));
      var area = document.querySelector("table.proposals tbody tr.flagged textarea");
      var cell = area && area.closest("td");
      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        flaggedCount: flagged.length,
        flaggedEdgesDanger: flagged.every(function (tr) { return edge(tr).indexOf(danger) !== -1; }),
        cleanEdgesDanger: clean.some(function (tr) { return edge(tr).indexOf(danger) !== -1; }),
        rowDisplays: flagged.concat(clean).map(function (tr) { return getComputedStyle(tr).display; }),
        textareaFills: !!cell && Math.abs(area.getBoundingClientRect().width -
          (cell.clientWidth - parseFloat(getComputedStyle(cell).paddingLeft) - parseFloat(getComputedStyle(cell).paddingRight))) < 2,
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "translation-review-measure.html") }

        it "measured the theme it was asked for, with a flagged row present" do
          expect(m["theme"]).to eq(theme)
          expect(m["flaggedCount"]).to eq(1)
        end

        it "edges a flagged proposal in --danger and a clean one not" do
          expect(m["flaggedEdgesDanger"]).to be(true)
          expect(m["cleanEdgesDanger"]).to be(false)
        end

        it "fills the proposal cell with its textarea" do
          expect(m["textareaFills"]).to be(true)
        end

        it "does not scroll sideways" do
          expect(m["hOverflow"]).to eq(0)
        end

        if name == "phone"
          it "stacks every proposal into a card" do
            expect(m["rowDisplays"].uniq).to eq(["block"])
          end
        end
      end
    end
  end
end
```

- [ ] **Step 8: Run it, then mutation-test it**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/translation_review_layout_spec.rb`
Expected: 18 examples, 0 failures. If `textareaFills` or `hOverflow` fails, fix the CSS (never the probe).

Mutations (each fails the named example; revert with a precise edit):
1. Delete `table.proposals tr.flagged > td:first-child { box-shadow: … }` → "edges a flagged proposal" fails at desktop.
2. Delete the `tr.flagged { border-left … }` line inside the media block → it fails at phone.
3. Remove `table--cards` from the view's `<table>` → "stacks every proposal into a card" fails.

- [ ] **Step 9: Commit**

```bash
git add app/views/translation_proposals/index.html.erb public/stylesheets/screens.css config/locales \
        spec/requests/translation_review_markup_spec.rb spec/layout/translation_review_layout_spec.rb
git commit -m "Make translation review readable, and flagged proposals visible

Gives the review table a header, data-labels so it stacks into cards on
phones, a danger edge on flagged rows, danger tags for the flags, and a
source panel that keeps the original's line breaks. A fifth layout spec
measures it in both themes."
```

---

### Task 5: Documentation (CLAUDE.md)

**Files:** Modify `CLAUDE.md`.

**Interfaces:** Consumes the orchestrator's measured RSpec count for the branch head (given in the dispatch).

- [ ] **Step 1: Edit these spots, in the file's own voice**
  - **Testing → the validation-message entry** ("A validation message is a predicate…"): add that a field whose messages are whole sentences may instead set `activerecord.errors.models.<model>.attributes.<attr>.format: "%{message}"` (enabled by `config.active_model.i18n_customize_full_message`), that 19 Merb-era fields do, and that `spec/i18n_sentence_messages_spec.rb` refuses it unless every message the field can produce — including from any validator on it — is a sentence.
  - **Layout section**: `spec/layout/` holds **five** specs; add `translation_review_layout_spec.rb` (flagged-row edge in both layouts, cards on phones, no sideways scroll).
  - **i18n**: re-measure the leaf-key count with the command the file gives and update the figure and date (this branch adds 2 + 4 keys, plus the `format` keys, which are leaves too — measure, do not add).
  - **RSpec count line**: replace with the count the orchestrator gives you, "measured 2026-10-01 at the commit that carries this line", keeping the surrounding history paragraph and adding one sentence: the figure moved by this branch's new specs.
  - Add one sentence where the deployment/test seams are discussed, or under Testing: the Dynarch calendar and jQuery autocomplete are retired, and `spec/assets_retired_spec.rb` fails if any view references their files again.

- [ ] **Step 2: Verify and commit**

Run: `bundle exec rspec spec/i18n_spec.rb` (sanity) and the leaf-count command; then

```bash
git add CLAUDE.md
git commit -m "Document full-sentence error formats, the fifth layout spec, and retired widgets"
```

---

### Task 6: Verification and PR (orchestrator)

- [ ] Each alone, fresh isolated DB: full RSpec (record the count, give it to Task 5 before its dispatch, re-run after Task 5 only if Task 5 touched anything but CLAUDE.md); `LAYOUT_SPECS=1 bundle exec rspec spec/layout` (five files); `bundle exec cucumber`; the inherited-contract run from CLAUDE.md — 228 scenarios (226 passed, 2 undefined) / 2325 steps; `git diff origin/master -- features/` empty.
- [ ] Before/after screenshots, both themes, 390 and 1280: new-game form, invitation page, translation review with one flagged and one clean proposal.
- [ ] Push and open the PR "Native date and nickname inputs, readable translation review, and full-sentence errors" (spec + plan paths, before → after table of the three error messages, gate results, the deletions, out-of-scope list).
