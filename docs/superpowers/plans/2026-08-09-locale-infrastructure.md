# Locale Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the platform able to carry seven interface languages, so Turkish, Belarusian and
Polish translations can each ship on their own schedule without any further plumbing.

**Architecture:** Register the three new locales, add `rails-i18n` so their dates, formats and
validation defaults do not have to be hand-authored, and rework the header switcher — which renders
one link per locale and already wraps a phone header onto three rows at four — so seven fit.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12 (rbenv), `config/locales/*.yml`, Cucumber (Russian
Gherkin, frozen), RSpec.

## Global Constraints

- Ruby is **not on `PATH` in non-login shells**:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **NEVER edit any file under `features/` ending in `.feature`.** One frozen scenario constrains
  Task 3 directly — see the constraint block there. Step definitions
  (`features/i18n/steps/i18n_steps.rb`) are fair game.
- `spec/i18n_spec.rb` reads the YAML **files** directly, not the `I18n` backend, so gem-provided
  locales never appear in its parity checks. It enforces three things: exact `ru`↔`en` leaf parity;
  every other listed locale must be a **subset** of `ru`; and a key must use the **same interpolation
  variables in every locale that defines it**.
- `config.i18n.fallbacks = [:ru]`, so a partial locale file renders Russian rather than
  `translation missing:`. This is what makes incremental delivery safe.
- Hash rockets (`:key => value`). Russian for user-facing strings, English for code and comments.
- **Mutation-test every guard-style assertion.** A green suite has repeatedly been weak evidence here.
- **Implementers cannot run Cucumber** (120s tool timeout vs ~5 minutes). Run RSpec, stop before
  committing, report. The controller runs Cucumber.
- Baselines: confirm by running them, do not trust a quoted number — the RSpec count has moved five
  times in a week. At the time of writing, `master` is **RSpec 1164 / 0 / 6** and Cucumber
  **232 scenarios (2 undefined, 230 passed) / 2342 steps**. Cucumber is the stable figure.
- **Neither suite evaluates `config/environments/production.rb`** — both run in the test environment.
  If a task touches it, boot production directly:
  `RAILS_ENV=production SECRET_KEY_BASE=x APP_HOST=example.com SMTP_USERNAME=u SMTP_PASSWORD=p SMTP_ADDRESS=s MAIL_FROM=m@e.com DATABASE_URL="sqlite3:/tmp/probe.sqlite3" bin/rails runner 'puts "ok"'`

---

## Context an implementer will not otherwise have

**Current state:** four locales (`ru`, `en`, `uk`, `ka`), **587 leaf keys each**, all four complete.
`CLAUDE.md` says 489 — that number is stale and Task 4 fixes it.

**587 is `master` as of 2026-08-09, with PR #59 merged** (commit c0f8239) — verified by counting, not
carried over. For the record, because an earlier draft of this note got it backwards: master before
#59 was **573**, and #59's fourteen new keys (`errors.too_many_requests`, `admin.settings.*`,
`users.create.check_your_mail`, `activerecord.errors.models.setting.*`) took it to 587. Every task
below still tells you to count rather than trust the figure — do that, and use what you get.

**There is no `rails-i18n` gem.** Everything Rails would normally supply per-locale is hand-written
in this repository: `activerecord.errors.messages`, the per-model/per-attribute error messages, and
the `date:`/`time:` blocks that 16 `l()` calls in views depend on. That is why the key count is 587
rather than a couple of hundred, and it is why adding three languages by hand would mean writing
Polish month names.

**No key is pluralised today.** The three `t()` calls that pass `count:` are plain `%{count}`
interpolation (`"Коды (%{count}):"`), and no `one:`/`few:`/`many:`/`other:` keys exist anywhere. This
is the *only* reason Russian works: Rails' built-in pluralizer understands `one`/`other` only, and
would raise `I18n::InvalidPluralizationData` for any Slavic locale. Adding `rails-i18n` in Task 1
supplies the CLDR rules and removes that landmine before Polish and Belarusian triple the surface
where someone reaches for a plural.

**Game content is not affected.** `Game#available_locales_are_known` validates an author's declared
locales against `I18n.available_locales`, so registering three more merely *permits* authors to offer
content in them. No existing game changes and no author is obliged to translate anything.

---

## File Structure

**Modified:**
- `Gemfile`, `Gemfile.lock` — add `rails-i18n`.
- `config/application.rb:27` — register `:tr, :be, :pl`.
- `config/locales/{ru,en,uk,ka}.yml` — three new `locales.*` display names each.
- `config/locales/{tr,be,pl}.yml` — created as stubs carrying only `locales.*` (Task 2).
- `spec/i18n_spec.rb:39` — the subset list.
- `app/views/layouts/_header.html.erb`, `public/stylesheets/*.css` — the switcher (Task 3).
- `CLAUDE.md` — key count, locale list, the plural note (Task 4).

---

## Task 1: Add `rails-i18n`, without changing a single rendered string

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`
- Test: `spec/i18n_rails_defaults_spec.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: CLDR plural rules and Rails' own date/format/validation defaults for every locale the gem
  ships, available underneath this app's own files.

**Why this is safe, and the one thing to prove:** `I18n.load_path` gets the gem's files first and the
app's `config/locales/*.yml` after, so **the app's values win** wherever both define a key. The risk
is the reverse of the usual one: not that something breaks, but that a hand-written Russian message
is silently replaced by the gem's generic wording. Task 1 exists to prove that does not happen.

- [ ] **Step 1: Write the failing test**

Create `spec/i18n_rails_defaults_spec.rb`:

```ruby
require "rails_helper"

describe "rails-i18n defaults" do
  # The gem must fill GAPS, never override this app's own wording. These are
  # app-authored strings that the gem also defines a key for; if any of them
  # starts returning the gem's generic text, load order has inverted.
  it "does not override this app's own Russian validation wording" do
    I18n.with_locale(:ru) do
      expect(I18n.t("activerecord.errors.messages.blank")).to eq("не может быть пустым")
      expect(I18n.t("activerecord.errors.models.game.attributes.name.blank"))
        .to eq("Вы не ввели название")
    end
  end

  # The point of the gem: locales this app has never written a line for still
  # get real dates and real validation messages.
  it "supplies dates and validation messages for the new locales" do
    %i[tr be pl].each do |locale|
      I18n.with_locale(locale) do
        expect(I18n.l(Date.new(2026, 3, 1), :format => :long)).to be_present
        expect(I18n.l(Date.new(2026, 3, 1), :format => :long)).not_to include("translation missing")
        expect(I18n.t("errors.messages.blank")).not_to include("translation missing")
      end
    end
  end

  # The landmine this removes. Rails' built-in pluralizer knows one/other only;
  # Slavic locales need CLDR rules or I18n::InvalidPluralizationData is raised
  # the first time anyone writes a pluralised key.
  it "can pluralise in the Slavic locales" do
    %i[ru uk be pl].each do |locale|
      I18n.with_locale(locale) do
        expect {
          I18n.t("datetime.distance_in_words.x_days", :count => 3)
        }.not_to raise_error
      end
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_rails_defaults_spec.rb
```

Expected: FAIL. `tr`, `be`, `pl` are not registered yet (that is Task 2) and the gem is absent, so
`I18n.l` raises or returns a missing-translation string.

**If the first example (Russian wording) fails at this point, stop** — it means the expectations were
transcribed wrongly, not that anything is broken. Read the real values out of `config/locales/ru.yml`
and correct the spec before continuing.

- [ ] **Step 3: Add the gem**

In `Gemfile`, next to the other framework gems:

```ruby
# Rails' own per-locale defaults: date and time formats, ActiveRecord
# validation messages, and -- the reason this became urgent -- CLDR
# pluralisation rules. Without it Rails' built-in pluralizer knows one/other
# only, so the first pluralised key written in this app would raise
# I18n::InvalidPluralizationData in every Slavic locale.
#
# Load order matters and is in this app's favour: the gem's files enter
# I18n.load_path before config/locales/*.yml, so anything this repository
# defines still wins. The gem fills gaps; it never overrides.
gem "rails-i18n", "~> 8.0"
```

Then:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle install
```

- [ ] **Step 4: Register the three locales temporarily so the spec can run**

This task's spec needs `tr`/`be`/`pl` registered, which is Task 2's job. Do the one-line edit here so
Task 1 is verifiable on its own — Task 2 then only has to add the display names and the stub files.

`config/application.rb:27`:

```ruby
    config.i18n.available_locales = [:ru, :en, :uk, :ka, :tr, :be, :pl]
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_rails_defaults_spec.rb
```

Expected: PASS, 3 examples.

- [ ] **Step 6: Mutation-test the load-order claim**

The first example is the one that matters and the one most likely to be vacuous. Prove it
discriminates: temporarily comment out the `activerecord.errors.messages.blank` line in
`config/locales/ru.yml` and re-run. The example must go RED with the gem's generic Russian wording
rather than the app's. Restore the line and confirm green.

Record the gem's wording you saw in your report — it is the evidence that the gem really is
underneath, rather than absent.

- [ ] **Step 7: Full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: baseline **+3**, 0 failures. **Any other example that changes is a real finding** — it
would mean a rendered string moved because of the gem, which is exactly what Step 6 says must not
happen. Report it rather than adapting the test.

- [ ] **Step 8: Commit**

```bash
git add Gemfile Gemfile.lock config/application.rb spec/i18n_rails_defaults_spec.rb
git commit -m "Add rails-i18n, so new locales get dates and plural rules free"
```

---

## Task 2: Register the locales and name them

**Files:**
- Create: `config/locales/tr.yml`, `config/locales/be.yml`, `config/locales/pl.yml`
- Modify: `config/locales/{ru,en,uk,ka}.yml` — the `locales:` block
- Modify: `spec/i18n_spec.rb:39`

**Interfaces:**
- Consumes: the `available_locales` line already edited in Task 1 Step 4.
- Produces: three locale files that exist, validate, and render the switcher — carrying **only** the
  seven display names. Every other key falls back to `ru` until the translation plan fills it.

- [ ] **Step 1: Write the failing test**

Append to `spec/i18n_spec.rb`, inside the existing `RSpec.describe "internationalization"` block:

```ruby
  # Every registered locale must at least be able to name itself and its
  # siblings, because app/views/layouts/_header.html.erb renders
  # t("locales.#{l}") for every available locale on every page. A locale
  # missing from this block would print the Russian name via fallback, which
  # is worse than useless in a language switcher -- the whole point of the
  # control is to be readable by someone who cannot read the current language.
  it "names every available locale in every locale file" do
    I18n.available_locales.each do |file_locale|
      data = locale_data(file_locale)

      I18n.available_locales.each do |named|
        expect(data).to have_key("locales.#{named}"),
          "#{file_locale}.yml is missing locales.#{named}"
      end
    end
  end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Expected: FAIL — `Errno::ENOENT` for `config/locales/tr.yml`, because the file does not exist yet.

- [ ] **Step 3: Create the three stub files**

`config/locales/tr.yml`:

```yaml
tr:
  locales:
    ru: "Rusça"
    en: "İngilizce"
    uk: "Ukraynaca"
    ka: "Gürcüce"
    tr: "Türkçe"
    be: "Belarusça"
    pl: "Lehçe"
```

`config/locales/be.yml`:

```yaml
be:
  locales:
    ru: "Руская"
    en: "Англійская"
    uk: "Украінская"
    ka: "Грузінская"
    tr: "Турэцкая"
    be: "Беларуская"
    pl: "Польская"
```

`config/locales/pl.yml`:

```yaml
pl:
  locales:
    ru: "Rosyjski"
    en: "Angielski"
    uk: "Ukraiński"
    ka: "Gruziński"
    tr: "Turecki"
    be: "Białoruski"
    pl: "Polski"
```

- [ ] **Step 4: Add the three names to the four existing files**

In each of `config/locales/{ru,en,uk,ka}.yml`, inside the **existing** `locales:` block (do not create
a second one — `spec/i18n_spec.rb` fails the build on duplicate YAML keys):

`ru.yml`:
```yaml
    tr: "Türkçe"
    be: "Беларуская"
    pl: "Polski"
```

`en.yml`:
```yaml
    tr: "Türkçe"
    be: "Belarusian"
    pl: "Polish"
```

`uk.yml`:
```yaml
    tr: "Türkçe"
    be: "Беларуська"
    pl: "Польська"
```

`ka.yml`:
```yaml
    tr: "თურქული"
    be: "ბელარუსული"
    pl: "პოლონური"
```

**A language's own name stays in its own language** (`Türkçe`, `Polski`) in every file, which is the
convention the existing four already follow — `en.yml` says `"Українська"`, not `"Ukrainian"`. The
exception is `ka.yml`, which transliterates. Match what each file already does rather than
normalising them.

- [ ] **Step 5: Widen the subset rule**

`spec/i18n_spec.rb:39` — the strict `ru`↔`en` parity check stays exactly as it is; the three new
locales join the deliberately-partial group:

```ruby
  %i[uk ka tr be pl].each do |locale|
```

Update that block's comment to say the new three are partial **by design and by plan** — they carry
display names only until
`docs/superpowers/plans/2026-08-09-locale-translation-delivery.md` fills them, and
`config.i18n.fallbacks = [:ru]` is what makes that safe.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Expected: PASS.

- [ ] **Step 7: Mutation-test the new guard**

Delete `pl: "Polski"` from `config/locales/en.yml` and re-run. The new example must go RED naming
`en.yml` and `locales.pl` specifically. Restore, confirm green. A guard whose failure message does
not say which file and which key is worth much less — check the message, not just the colour.

- [ ] **Step 8: Verify the fallback actually works end to end**

The claim that a stub locale is safe deserves evidence, not assertion:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner 'I18n.with_locale(:pl) { puts I18n.t("layout.title"); puts I18n.t("locales.pl") }'
```

Expected: the **Russian** `layout.title` (fallback working) and `Polski` (the one key `pl` defines).
If the first line prints `translation missing`, fallbacks are not configured the way this plan
assumes — stop and report.

- [ ] **Step 9: Full suite, then commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
git add config/locales spec/i18n_spec.rb
git commit -m "Register Turkish, Belarusian and Polish"
```

Expected: baseline **+4**.

---

## Task 3: Turn the switcher into a dropdown

**Files:**
- Modify: `app/views/layouts/_header.html.erb`
- Modify: `public/stylesheets/layout.css`

**Interfaces:**
- Consumes: the seven registered locales from Task 2.
- Produces: a header whose height no longer depends on how many locales exist.

### CONSTRAINT — read this before designing anything

`features/i18n/switch-language.feature:37` is **frozen** and reads:

```
And I click the "English" language switcher link
```

Its step definition (`features/i18n/steps/i18n_steps.rb:57-59`, which **is** editable) does:

```ruby
within("#locale-switcher") { click_link(label) }
```

So an element with `id="locale-switcher"` must exist and must contain a real `<a>` whose text is the
locale name. That sounds like it rules a dropdown out. It does not, for a reason worth knowing:

**Capybara's rack-test driver never parses stylesheets.** `Capybara::Node::Simple#visible?`
(capybara 3.40.0, `lib/capybara/node/simple.rb`) considers exactly five things: `input[type=hidden]`,
`<template>`, the `hidden` **attribute**, an **inline** `style` containing `display: none`, and
`script`/`head`/`style` tags. An element hidden by a rule in an external CSS file is fully visible as
far as the acceptance suite is concerned. So a CSS-driven dropdown keeps every link real and
clickable for rack-test while collapsing to a single control in a browser, and the frozen scenario
passes **untouched**.

**Do NOT build it with `<details>`/`<summary>`.** That element *is* special-cased — the same file's
`VISIBILITY_XPATH` contains `(~x.self(:summary) & XPath.parent(:details)[!XPath.attr(:open)])`, so
non-summary children of a **closed** `<details>` are invisible and `click_link` would not find them.
(It happens that the rule tests the *direct* parent, so links nested one level deeper would slip
through — do not rely on that. Depending on nesting depth to dodge a visibility rule is precisely the
kind of accidental coupling that breaks silently later.)

**No JavaScript is available.** This app has no Turbo and no rails-ujs — see the `GET /logout` wart in
`CLAUDE.md`. The dropdown must work with CSS alone, which also rules out a `<select>` (it would need
JS to navigate, or a second click on a submit button).

**The measured problem.** At 390px the four current links wrap the header onto three rows — 181px,
27% of a phone's visible viewport, more than the play screen's task card. That is why the play screen
already hides the switcher (`.page--focused #locale-switcher` in `layout.css`). Seven links makes
every *other* page worse.

- [ ] **Step 1: Measure before changing anything**

Layout cannot be tested from RSpec. Use the browser harness — the procedure is recorded in the
`.playbar` comment in `public/stylesheets/screens.css`; the short version is: render the page from a
throwaway request spec, serve `public/` with `python3 -m http.server`, and drive
`~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell`
with `--window-size` and `--dump-dom`.

Render a page using the application layout (the dashboard, or `/games`) and record at **390x660**:

```javascript
var h = document.querySelector('.topbar'), sw = document.querySelector('#locale-switcher');
JSON.stringify({
  headerHeight: Math.round(h.getBoundingClientRect().height),
  switcherHeight: Math.round(sw.getBoundingClientRect().height),
  horizontalOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  linkCount: sw.querySelectorAll('a').length
});
```

Task 2 has already registered seven locales, so this run *is* the seven-locale "before". Record it;
it is the number you have to beat.

- [ ] **Step 2: Rewrite the switcher markup**

In `app/views/layouts/_header.html.erb`, replace the `#locale-switcher` block. Keep the existing
comment above it about `?locale=` beating the stored preference — it is still true and still worth
reading — and add the constraint note:

```erb
<%# A dropdown, not a row: one link per locale wrapped the header onto three
    rows at phone width with only four of them, and there are seven.

    CSS-only, because this app has no Turbo and no rails-ujs -- and NOT a
    <details> or a <select>, both of which would break
    features/i18n/switch-language.feature:37, whose step does
    within("#locale-switcher") { click_link(label) }. Capybara's rack-test
    driver ignores stylesheets entirely, so links hidden by the CSS below are
    still visible to the acceptance suite; a closed <details>, by contrast, is
    special-cased as invisible. See the .locale-menu rules in layout.css. %>
<div id="locale-switcher">
  <button type="button" class="btn locale-trigger" aria-haspopup="true">
    <%= t("locales.#{I18n.locale}") %>
  </button>

  <div class="locale-menu">
    <% I18n.available_locales.each do |available_locale| %>
      <% if available_locale == I18n.locale %>
        <span class="locale-switcher-current"><%= t("locales.#{available_locale}") %></span>
      <% else %>
        <%= link_to t("locales.#{available_locale}"),
              "#{request.path}?#{request.query_parameters.merge("locale" => available_locale).to_query}",
              class: "locale-switcher-link" %>
      <% end %>
    <% end %>
  </div>
</div>
```

Note the trigger shows the **current** locale's name, so the control says what it is without being
opened.

- [ ] **Step 3: Add the CSS**

In `public/stylesheets/layout.css`, replacing the existing `#locale-switcher` rules and **keeping**
the `.page--focused #locale-switcher { display: none; }` rule that hides it during play:

```css
/* The locale dropdown. Opened by hover on a pointer and by focus everywhere
   else -- :focus-within covers keyboard tabbing and a tap on the trigger,
   which is what makes this work on a phone with no JavaScript.

   The menu is hidden by a rule in THIS FILE rather than an inline style or a
   hidden attribute, and that is load-bearing: Capybara's rack-test driver
   parses neither stylesheets nor computed style, so every link inside stays
   clickable for features/i18n/switch-language.feature while being invisible
   to a person until the menu opens. Do not move this to an inline
   display:none, and do not reach for <details>. */
#locale-switcher { position: relative; }

.locale-menu {
  position: absolute;
  top: 100%;
  right: 0;
  z-index: 25;            /* above .topbar's own 20 */
  display: none;
  min-width: 10rem;
  padding: var(--space-2);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
}

#locale-switcher:hover .locale-menu,
#locale-switcher:focus-within .locale-menu { display: block; }

.locale-menu a,
.locale-menu .locale-switcher-current {
  display: block;
  /* The project's tap-target floor, same as .language-choice. */
  min-height: var(--tap);
  padding: var(--space-2) var(--space-3);
}

.locale-menu .locale-switcher-current { font-weight: 600; }
```

- [ ] **Step 4: Re-measure**

**Pass conditions at 390x660 and 1280x800:**
- `headerHeight` is **strictly less** than the Step 1 figure — this is the whole point,
- `horizontalOverflow` is **0**,
- `linkCount` is still **6** (seven locales minus the current one, which renders as a span),
- the menu's own box does not appear in `headerHeight` — it is absolutely positioned, so it must not
  contribute to layout.

Record all the numbers. Take a screenshot at 390x660 with the menu forced open (add
`.locale-menu { display: block }` to the probe page only) so the dropdown can actually be looked at.

- [ ] **Step 5: Prove the frozen scenario still passes**

This is the binding check and only the controller can run it:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber features/i18n
```

Expected: every scenario passes, including "The switcher link preserves other query parameters when
it replaces locale". **If `click_link` fails, stop and report** — do not rewrite the step definition
to work around it. A failure here means the rack-test visibility reasoning above is wrong, which is a
finding worth more than the workaround.

- [ ] **Step 6: Full suites, then commit**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec baseline **+4** (this task adds no examples), Cucumber **exactly 232 scenarios /
2342 steps**.

```bash
git add app/views/layouts/_header.html.erb public/stylesheets/layout.css
git commit -m "Make the locale switcher a dropdown"
```

## Task 4: Record the new shape

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Correct the i18n section**

Three things there are now wrong or missing:

- The leaf-key count says **489**. It is **587**. Verify by counting rather than copying this number:
  ```bash
  export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
  ruby -ryaml -e 'def leaves(h,p=""); h.flat_map{|k,v| v.is_a?(Hash) ? leaves(v,"#{p}#{k}.") : ["#{p}#{k}"]}; end
                  d=YAML.unsafe_load_file("config/locales/ru.yml"); puts leaves(d["ru"]).size'
  ```
- The locale list says four. It is now seven — `ru`, `en` complete; `uk`, `ka` complete but
  unreviewed; `tr`, `be`, `pl` **display names only**, pending
  `docs/superpowers/plans/2026-08-09-locale-translation-delivery.md`.
- Add the pluralisation note: no key in this app is pluralised today, `rails-i18n` now supplies CLDR
  rules, and before the gem a single pluralised key would have raised
  `I18n::InvalidPluralizationData` in every Slavic locale.

- [ ] **Step 2: Add the switcher constraint where someone will find it**

`CLAUDE.md` already has a "Known, deliberate wart" section for `GET /logout`, which exists for
exactly this kind of trap. Add a sibling note covering the switcher:

- `#locale-switcher` must keep real `<a>` links inside an element with that id, because
  `features/i18n/switch-language.feature:37` is frozen and its step does
  `within("#locale-switcher") { click_link(label) }`.
- The dropdown hides those links with a rule in `layout.css` **on purpose**. Capybara's rack-test
  driver parses neither stylesheets nor computed style — it checks only `input[type=hidden]`,
  `<template>`, the `hidden` attribute, an inline `style` containing `display: none`, and
  `script`/`head`/`style` tags — so CSS-hidden links stay clickable for the suite.
- Therefore: do **not** convert it to a `<select>` (needs JS this app does not have), do **not** move
  the hiding into an inline style or a `hidden` attribute, and do **not** use `<details>`, whose
  closed state Capybara *does* treat as invisible.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Record the seven-locale shape and the switcher constraint"
```

---

## Self-review notes for whoever executes this

- Task 1 Step 4 edits `config/application.rb`, which Task 2 would otherwise own. That is deliberate:
  Task 1's spec cannot pass without registered locales, and a task that cannot be verified on its own
  is not a task. Task 2 adds only files and display names.
- The example counts given are **deltas**, not absolutes. The absolute has moved five times in a week
  and been quoted stale twice. **0 failures is the binding check.**
- Nothing in this plan writes a single translated string beyond seven display names per file. That is
  the point: this plan makes the platform *able* to carry the languages, and the translation plan
  delivers them one at a time.
