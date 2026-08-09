# Locale Translation Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill `config/locales/{be,pl,tr}.yml` with the platform's 587 interface strings, one language
at a time, each shippable on its own.

**The 587 figure was measured on `master` at 437a786, before PR #59 (signup abuse hardening) merged.**
That PR adds `errors.too_many_requests`, `admin.settings.*`, `users.create.check_your_mail` and the
`activerecord.errors.models.setting.*` messages — so once it lands the real number is higher. Every
task below tells you to count rather than trust this figure; do that, and use what you get.

**Architecture:** Each language is one self-contained task producing one PR. The order is deliberate —
Belarusian and Polish are close to the Russian source and mostly mechanical; Turkish is not, and goes
last so the process is proven before the hard one.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12 (rbenv), `config/locales/*.yml`, RSpec, Cucumber.

## Prerequisite

**`docs/superpowers/plans/2026-08-09-locale-infrastructure.md` must be merged first.** It registers
the three locales, adds `rails-i18n` (which supplies each language's dates, formats, validation
messages and CLDR plural rules, so none of that is hand-written here), turns the switcher into a
dropdown, and creates each file as a stub carrying only the seven `locales.*` display names.

Until then these locales fall back to Russian, which renders correctly and is why they can ship in
any order, or never.

## Global Constraints

- Ruby is **not on `PATH` in non-login shells**:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **NEVER edit any file under `features/` ending in `.feature`.**
- **Never touch `ru.yml` or `en.yml` in this plan.** They are held to exact leaf parity by
  `spec/i18n_spec.rb`; changing one without the other reddens the build, and neither needs changing
  to add a third language. If a task appears to need a new key in `ru`, that is a finding — stop and
  report it, because it means the source text is missing something rather than the translation being
  hard.
- Each new locale must be a **subset** of `ru` — never a superset (an orphan key nobody reads) and
  never a sideways set (a typo'd path that silently resolves to nothing). `spec/i18n_spec.rb`
  enforces this.
- `spec/i18n_spec.rb` also enforces that a key uses the **same interpolation variables in every
  locale that defines it**. This is the single most valuable check for machine-produced text: a
  translator who drops `%{nickname}` or invents `%{user}` fails the build rather than shipping a
  `translation missing` or a raised `I18n::MissingInterpolationArgument` into a live game.
- Hash rockets in Ruby (`:key => value`). Code and comments in English.
- **Implementers cannot run Cucumber** (120s tool timeout vs ~5 minutes). Run RSpec, stop before
  committing, report. The controller runs Cucumber.
- Baselines: confirm by running them rather than trusting a quoted number. After the infrastructure
  plan lands, RSpec is its baseline **+7** and Cucumber is **232 scenarios (2 undefined, 230 passed)
  / 2342 steps**.

---

## What "done" means for a language, and what it does not

**Done means:** all 587 leaf keys present, structurally verified, and the app demonstrably rendering
that locale end to end.

**Done does not mean reviewed.** `uk` and `ka` shipped machine-produced without a native reviewer,
and `CLAUDE.md` records that as a known gap. Adding three more the same way makes **five of seven**
unreviewed. That is a real decision, not an oversight, and each task ends by stating plainly in the
PR body whether a native speaker read the file. Do not describe an unreviewed locale as complete.

**A note on where the risk actually is.** Getting a menu label slightly wrong is cosmetic and
correctable. Two categories are not:

1. **Anything a player reads mid-game under time pressure** — the play screen, answer feedback, hint
   labels, the exit button. A confusing string there costs a team the game.
2. **Anything carrying an interpolated user value** — see the Turkish task, where this is a grammar
   problem rather than a wording one.

Task 4 pins category 1 in every language with a rendering check.

---

## The shared procedure

Every language task follows the same five moves. They are written out in full in Task 1 and
**repeated in full** in Tasks 2 and 3 — deliberately, because an implementer may read tasks out of
order and "same as Task 1" is not an instruction.

1. Extract the source strings with their key paths.
2. Produce the translation.
3. Write the YAML with the identical key structure.
4. Verify structurally (`spec/i18n_spec.rb`) and by rendering.
5. State the review status honestly in the PR.

**The extraction command** (used by every task):

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
ruby -ryaml -e '
def leaves(h, pre = "")
  h.flat_map { |k, v| v.is_a?(Hash) ? leaves(v, "#{pre}#{k}.") : [[ "#{pre}#{k}", v ]] }
end
d = YAML.unsafe_load_file("config/locales/ru.yml")
leaves(d["ru"]).each { |path, value| puts "#{path}\t#{value.to_s.gsub("\n", "\\n")}" }
' > /tmp/ru-source.tsv
wc -l /tmp/ru-source.tsv    # expect 587
```

---

## Task 1: Belarusian (`be`)

**Files:**
- Modify: `config/locales/be.yml`
- Test: `spec/i18n_spec.rb` (no change — it already covers `be` after the infrastructure plan)

**Interfaces:**
- Consumes: `config/locales/be.yml` as created by the infrastructure plan, carrying only `locales.*`.
- Produces: the same file with all 587 keys.

**Why Belarusian first:** it is the closest of the three to the Russian source — same script, same
case system, same word order — so it is the cheapest way to prove the procedure before spending
effort on Turkish.

- [ ] **Step 1: Extract the source**

Run the extraction command above. Confirm 587 lines. If the count differs, `ru.yml` has moved since
this plan was written — use the real number and note it in your report; do not "fix" it.

- [ ] **Step 2: Produce the Belarusian text**

Translate every value, keeping the key path identical. Rules that matter more than fluency:

- **Every `%{placeholder}` must survive, spelled identically.** `spec/i18n_spec.rb` fails the build
  otherwise, which is the safety net — but a dropped placeholder also means a sentence with a hole in
  it, so treat a build failure here as a translation defect, not a spec problem.
- **Do not translate anything inside a placeholder**, and do not reorder a placeholder into a
  position that changes what the sentence claims.
- **Keep Belarusian in Belarusian, not Russian-with-accent.** The two are close enough that machine
  translation drifts into Russian. The most likely tell is vocabulary that is identical to the `ru`
  line — spot-check a sample against the source and flag any line that came back unchanged.
- **`locales.*` already exists** in the stub from the infrastructure plan. Do not duplicate that block
  — `spec/i18n_spec.rb` fails on duplicate YAML keys.

- [ ] **Step 3: Write the file**

`config/locales/be.yml`, `be:` at the root, the same nesting as `ru.yml`. Preserve block scalars
(`|`) for multi-line mailer bodies — collapsing one to a single line changes the e-mail's shape.

- [ ] **Step 4: Verify structurally**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Expected: PASS. This proves three things at once: `be` is a subset of `ru` (no orphans, no typo'd
paths), no duplicate keys, and every interpolation variable matches.

Then confirm completeness, which the subset rule alone does **not**:

```bash
ruby -ryaml -e '
def leaves(h, pre = "")
  h.flat_map { |k, v| v.is_a?(Hash) ? leaves(v, "#{pre}#{k}.") : ["#{pre}#{k}"] }
end
ru = leaves(YAML.unsafe_load_file("config/locales/ru.yml")["ru"]).sort
be = leaves(YAML.unsafe_load_file("config/locales/be.yml")["be"]).sort
puts "ru=#{ru.size} be=#{be.size}"
missing = ru - be
puts missing.empty? ? "COMPLETE" : "MISSING #{missing.size}:\n#{missing.first(20).join("\n")}"
'
```

Expected: `ru=587 be=587` and `COMPLETE`.

- [ ] **Step 5: Verify by rendering, not just by counting**

A file can be structurally perfect and still not reach a page. Prove it does:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner '
I18n.with_locale(:be) do
  %w[layout.title shared.error_header users.new.submit
     game_passings.show_current_level.submit
     game_passings.show_current_level.exit_game
     game_passings.show_current_level.answer_missing_choice].each do |key|
    value = I18n.t(key)
    puts "#{key}: #{value}"
  end
end'
```

Every line must be Belarusian. **A Russian line means the fallback fired** — that key is missing, and
the count check above should have caught it, so investigate the discrepancy rather than patching the
one key.

Those keys are not arbitrary: they are the play screen — the strings a team reads mid-game under
time pressure, where a bad translation costs someone the game.

- [ ] **Step 6: Full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: 0 failures, count unchanged from baseline — this task adds no examples. **A changed count
means something other than a locale file was touched.**

- [ ] **Step 7: Commit**

```bash
git add config/locales/be.yml
git commit -m "Translate the interface into Belarusian"
```

The PR body must state, in as many words, whether a Belarusian speaker read this file. If not, say
"machine-produced, not reviewed by a native speaker" — the same status `uk` and `ka` carry.

---

## Task 2: Polish (`pl`)

**Files:**
- Modify: `config/locales/pl.yml`

**Interfaces:**
- Consumes: `config/locales/pl.yml` as created by the infrastructure plan, carrying only `locales.*`.
- Produces: the same file with all 587 keys.

**What differs from Belarusian:** Latin script with diacritics (`ą ć ę ł ń ó ś ź ż`) — check the file
is UTF-8 and that no diacritic has been stripped, which is the classic failure when text passes
through a tool that normalises. Polish also has a rich case system, so the interpolated-name caveat
in Task 3 applies here in a milder form: `%{nickname}` in a sentence wanting the genitive or locative
will read slightly wrong. It is not a blocker — Russian has the same issue and ships — but if a
phrasing can avoid inflecting around a name, prefer it.

- [ ] **Step 1: Extract the source**

Run the extraction command from "The shared procedure" above. Confirm 587 lines.

- [ ] **Step 2: Produce the Polish text**

Translate every value, keeping the key path identical.

- **Every `%{placeholder}` must survive, spelled identically.** `spec/i18n_spec.rb` fails the build
  otherwise; treat that failure as a translation defect, not a spec problem.
- **Do not translate anything inside a placeholder.**
- **Check the diacritics survived.** After writing the file:
  `grep -c '[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]' config/locales/pl.yml` — a suspiciously low count means
  something normalised the text.
- **`locales.*` already exists** in the stub. Do not duplicate it — the build fails on duplicate YAML
  keys.

- [ ] **Step 3: Write the file**

`config/locales/pl.yml`, `pl:` at the root, the same nesting as `ru.yml`. Preserve block scalars
(`|`) for multi-line mailer bodies.

- [ ] **Step 4: Verify structurally**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Then the completeness check (the subset rule does not prove completeness):

```bash
ruby -ryaml -e '
def leaves(h, pre = "")
  h.flat_map { |k, v| v.is_a?(Hash) ? leaves(v, "#{pre}#{k}.") : ["#{pre}#{k}"] }
end
ru = leaves(YAML.unsafe_load_file("config/locales/ru.yml")["ru"]).sort
pl = leaves(YAML.unsafe_load_file("config/locales/pl.yml")["pl"]).sort
puts "ru=#{ru.size} pl=#{pl.size}"
missing = ru - pl
puts missing.empty? ? "COMPLETE" : "MISSING #{missing.size}:\n#{missing.first(20).join("\n")}"
'
```

Expected: `ru=587 pl=587` and `COMPLETE`.

- [ ] **Step 5: Verify by rendering**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner '
I18n.with_locale(:pl) do
  %w[layout.title shared.error_header users.new.submit
     game_passings.show_current_level.submit
     game_passings.show_current_level.exit_game
     game_passings.show_current_level.answer_missing_choice].each do |key|
    puts "#{key}: #{I18n.t(key)}"
  end
end'
```

Every line must be Polish. A Russian line means the fallback fired and that key is missing.

- [ ] **Step 6: Full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: 0 failures, count unchanged from baseline.

- [ ] **Step 7: Commit**

```bash
git add config/locales/pl.yml
git commit -m "Translate the interface into Polish"
```

State in the PR body whether a Polish speaker read the file.

---

## Task 3: Turkish (`tr`)

**Files:**
- Modify: `config/locales/tr.yml`

**Interfaces:**
- Consumes: `config/locales/tr.yml` as created by the infrastructure plan, carrying only `locales.*`.
- Produces: the same file with all 587 keys.

### Read this before translating anything

Turkish is not Polish-with-different-words, and this repository has already solved the same class of
problem once. From `CLAUDE.md`, on Georgian:

> Georgian needed restructuring rather than word-for-word translation in a few places where the
> template's fixed word order fights the language ... and anywhere a user-supplied name is
> interpolated, where the case suffix was moved onto a preceding common noun so it never lands on
> the name.

Turkish has exactly that problem and adds one of its own:

**1. Case suffixes on interpolated values.** Turkish is agglutinative: "to the team X" attaches a
suffix to X, and *which* suffix depends on X's final vowel (vowel harmony) and whether it ends in a
consonant. A team called `Черепашки` or `Rada` takes different endings, and no template can pick
correctly. Use the Georgian solution: reword so the suffix lands on a **common noun** that is part of
the template, never on the placeholder — "the team named %{team}" rather than "%{team}'s".

Find every affected key first:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
ruby -ryaml -e '
def leaves(h, pre = "")
  h.flat_map { |k, v| v.is_a?(Hash) ? leaves(v, "#{pre}#{k}.") : [[ "#{pre}#{k}", v ]] }
end
leaves(YAML.unsafe_load_file("config/locales/ru.yml")["ru"]).each do |path, value|
  vars = value.to_s.scan(/%\{(\w+)\}/).flatten
  interesting = vars & %w[nickname team game name level answer author]
  puts "#{path}\t#{vars.join(",")}\t#{value}" unless interesting.empty?
end'
```

Every line that prints is a key where the placeholder holds a **user-authored name**. Those are the
ones to reword. Keys whose placeholders are numbers (`%{count}`, `%{answered}`, `%{total}`,
`%{hours}`) need no special handling.

**2. The dotless `ı` / dotted `İ`.** Turkish casing is not the Latin default: uppercase `i` is `İ`,
lowercase `I` is `ı`. The app has five `text-transform: uppercase` CSS rules, and this is **already
handled** — both layouts set `<html lang="<%= I18n.locale %>">`, so browsers apply Turkish casing.
The rule to keep: **never add a Ruby-side `.upcase`/`.downcase` on user-facing text**, which is
locale-blind and would mangle `i`/`I`.

- [ ] **Step 1: Extract the source and the interpolation inventory**

Run the extraction command from "The shared procedure", then the interpolation inventory above.
Record how many keys carry a user-authored name — that number is the size of the rewording problem
and belongs in your report.

- [ ] **Step 2: Produce the Turkish text**

Translate every value, keeping the key path identical.

- **Every `%{placeholder}` must survive, spelled identically.** `spec/i18n_spec.rb` fails otherwise.
- **Reword around every user-authored placeholder** as described above. This is the substance of this
  task; a word-for-word translation will read as broken Turkish to a player.
- **`locales.*` already exists** in the stub. Do not duplicate it.

- [ ] **Step 3: Write the file**

`config/locales/tr.yml`, `tr:` at the root, the same nesting as `ru.yml`. Preserve block scalars (`|`)
for multi-line mailer bodies.

- [ ] **Step 4: Verify structurally**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_spec.rb
```

Then completeness:

```bash
ruby -ryaml -e '
def leaves(h, pre = "")
  h.flat_map { |k, v| v.is_a?(Hash) ? leaves(v, "#{pre}#{k}.") : ["#{pre}#{k}"] }
end
ru = leaves(YAML.unsafe_load_file("config/locales/ru.yml")["ru"]).sort
tr = leaves(YAML.unsafe_load_file("config/locales/tr.yml")["tr"]).sort
puts "ru=#{ru.size} tr=#{tr.size}"
missing = ru - tr
puts missing.empty? ? "COMPLETE" : "MISSING #{missing.size}:\n#{missing.first(20).join("\n")}"
'
```

Expected: `ru=587 tr=587` and `COMPLETE`.

- [ ] **Step 5: Verify by rendering, including an interpolated name**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/rails runner '
I18n.with_locale(:tr) do
  %w[layout.title shared.error_header users.new.submit
     game_passings.show_current_level.submit
     game_passings.show_current_level.exit_game
     game_passings.show_current_level.answer_missing_choice].each do |key|
    puts "#{key}: #{I18n.t(key)}"
  end
  # A name ending in a consonant and one ending in a vowel: if the template
  # attaches a suffix to the placeholder, one of these will read wrong.
  puts I18n.t("game_passings.show_current_level.answer_incorrect", :answer => "Kadıköy")
  puts I18n.t("game_passings.show_current_level.answer_incorrect", :answer => "Ada")
end'
```

Every line must be Turkish, and the last two must both read naturally. If one does and the other does
not, the template is inflecting around the placeholder — go back to Step 2 for that key.

- [ ] **Step 6: Full suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
```

Expected: 0 failures, count unchanged from baseline.

- [ ] **Step 7: Commit**

```bash
git add config/locales/tr.yml
git commit -m "Translate the interface into Turkish"
```

The PR body must state whether a Turkish speaker read the file **and** must list the keys reworded to
avoid suffixing a placeholder, so a later reviewer can check those specifically rather than reading
587 strings.

---

## Task 4: Pin the play screen in every locale

**Files:**
- Create: `spec/i18n_play_screen_spec.rb`

**Interfaces:**
- Consumes: all seven locale files.
- Produces: a guard that a future locale cannot ship half-done in the place where it matters most.

**Why this exists.** `spec/i18n_spec.rb` proves a locale is a structurally valid *subset* of `ru`. It
does not prove any particular key is present — a locale carrying only its seven display names passes
every existing check. That is correct while a language is in progress and wrong once it has shipped,
because the failure is invisible: fallbacks mean an incomplete Turkish play screen renders in
**Russian**, mid-game, to a player who chose Turkish precisely because they do not read Russian.

- [ ] **Step 1: Write the failing test**

Create `spec/i18n_play_screen_spec.rb`:

```ruby
require "rails_helper"

describe "the play screen in every shipped locale" do
  # Locales that have been declared complete. A language in progress is
  # deliberately absent: fallbacks make a partial file safe, and this list is
  # what says "this one is finished" -- adding to it is the last step of
  # shipping a language, not the first.
  SHIPPED = %i[ru en uk ka].freeze

  # The strings a team reads mid-game, under time pressure. A fallback here is
  # not cosmetic: it shows Russian to someone who chose another language.
  PLAY_SCREEN_KEYS = %w[
    game_passings.show_current_level.title_prefix
    game_passings.show_current_level.level_label
    game_passings.show_current_level.answer_label
    game_passings.show_current_level.submit
    game_passings.show_current_level.exit_game
    game_passings.show_current_level.answer_correct
    game_passings.show_current_level.answer_incorrect
    game_passings.show_current_level.answer_missing_choice
    game_passings.show_current_level.answer_missing_code
    game_passings.show_current_level.hint_label
    game_passings.show_current_level.choose
  ].freeze

  SHIPPED.each do |locale|
    it "defines every play-screen string in #{locale}, without falling back" do
      data = YAML.load_file(Rails.root.join("config/locales/#{locale}.yml")).fetch(locale.to_s)

      PLAY_SCREEN_KEYS.each do |key|
        value = key.split(".").reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
        expect(value).to be_present, "#{locale}.yml does not define #{key} -- it would fall back to Russian mid-game"
      end
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it passes for the four complete locales**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/i18n_play_screen_spec.rb
```

Expected: PASS, 4 examples. If one fails, an *existing* locale has a play-screen gap — that is a real
find, and worth reporting before anything else in this plan.

- [ ] **Step 3: Mutation-test the guard**

Remove `game_passings.show_current_level.exit_game` from `config/locales/ka.yml` and re-run. The `ka`
example must go RED and its message must name both the file and the key. Restore and confirm green.
Check the message, not just the colour — a guard that fails without saying which file costs more
than it saves.

- [ ] **Step 4: Wire each language in as it ships**

This is the step the other tasks hand off to. When a language's PR is ready — Task 1, 2 or 3 above —
add its symbol to `SHIPPED` **in that same PR**, so the guard and the translation land together.

Order the list to match reality at the time: `%i[ru en uk ka be]`, then `pl`, then `tr`.

- [ ] **Step 5: Commit**

```bash
git add spec/i18n_play_screen_spec.rb
git commit -m "Pin the play screen against a locale shipping half-done"
```

---

## Self-review notes

- Tasks 1–3 are independent. Any one can ship without the others; any one can be abandoned without
  affecting the rest. That is the point of doing them as three PRs.
- Task 4 can land before, between or after them — but its `SHIPPED` list must only ever name a
  language that is actually complete, or it becomes a red build for work in progress.
- No task in this plan writes Ruby beyond one spec file. If a task finds itself editing a controller
  or a view, something has been misunderstood — stop and report.
- **The bottleneck is native review, not engineering.** Every task can be completed by machine
  translation in an afternoon and none of them should be described as done in the sense that matters
  until somebody who speaks the language has read it.
