# UX Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app one type scale, enforced breakpoint and layer sets, a complete form system with inline field errors, and a superadmin-visible styleguide that a layout spec measures.

**Architecture:** Plain CSS custom properties in `public/stylesheets/tokens.css`, consumed by the four existing stylesheets; a pure-Ruby spec reads the stylesheets and refuses raw values. Field errors are produced by one small class, `FieldErrorMarkup`, wired in as Rails' `field_error_proc`. The styleguide is one read-only admin page that renders real controls from a real invalid `Game`, and is the page the new layout spec measures in both themes.

**Tech Stack:** Rails 8, ERB, vanilla CSS, RSpec (request, helper, plain), the `spec/support/layout_measurement.rb` headless-Chrome harness.

**Spec:** `docs/superpowers/specs/2026-09-30-ux-foundations-design.md` — read it alongside this plan; this plan argues from it.

## Global Constraints

- Work only in the worktree `.claude/worktrees/design-foundations`, branch `design/foundations`.
- Ruby is not on PATH in non-login shells: prefix every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" &&`.
- **Never edit any `features/**/*.feature` file.** Step definitions are fair game but nothing here needs them.
- Hash rockets (`:key => value`) in Ruby, matching surrounding files. Code and comments in English.
- Type tokens, exactly: `--text-xs: 0.8rem; --text-sm: 0.875rem; --text-md: 1rem; --text-lg: 1.125rem; --text-xl: 1.25rem; --text-2xl: 1.5rem; --text-body: clamp(16px, 0.95rem + 0.2vw, 18px); --text-h1: clamp(1.6rem, 1.3rem + 1.4vw, 2.4rem); --text-h2: clamp(1.2rem, 1.05rem + 0.7vw, 1.6rem);`
- Layer tokens, exactly: `--z-sticky: 15; --z-scrim: 25; --z-drawer: 30; --z-topbar: 40; --z-dropdown: 25;`
- Input border: dark `--border-input: #7a7066;` light `--border-input: #857b71;`. `--border` is unchanged.
- Allowed `@media` widths: `min-width: 48rem`, `max-width: 47.99rem`, `min-width: 52rem`, `min-width: 60rem`. No value changes.
- No input may render below `--text-body` (iOS zooms a focused input under 16px).
- No `opacity` for disabled state; no Ruby-side `.upcase`/`.downcase` on user-facing text.
- Every new i18n key goes into **all seven** `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`, and the `en` value must differ from the `ru` value (`spec/i18n_spec.rb` checks that).
- **Subagents do not run the full RSpec or Cucumber suites.** Run only the files named in your task. The orchestrator runs the full gates in Task 5.
- Commit messages: plain imperative subject, a short body; no attribution lines.

## Review Focus

1. **A `<textarea>` with an error must keep its content byte-for-byte**, including a leading newline — Rails emits `<textarea>\n` deliberately, and any HTML re-serialisation of the tag would drop it. `FieldErrorMarkup` edits the opening tag as a string for exactly this reason; Task 2 pins it.
2. **An error message that is already `html_safe`** (from an `_html` i18n key) must still be escaped in the inline span, the way `error_messages_for` already does with `CGI.escapeHTML`. Task 2 pins it.
3. **A self-closing `<input ... />`** must stay valid after attributes are added — appending after the `/` produces `<input ... / aria-invalid="true">`. Task 2 pins it.
4. **The generic file thumbnail label** (`.file-table .file-thumb-generic`, 0.68 → 0.8rem in a fixed 48px box) must still fit. Task 5's screenshot list includes it.
5. **A disabled control in the styleguide** must not fail the 3:1 border check — WCAG 1.4.11 exempts inactive components, and the probe excludes `:disabled`. Task 4 pins that the exclusion is by `:disabled`, not by class.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `public/stylesheets/tokens.css` | type, layer, input-border tokens; breakpoint comment | 1, 4 |
| `public/stylesheets/{base,components,layout,screens}.css` | consume the tokens | 1, 2, 4 |
| `spec/stylesheets/token_discipline_spec.rb` (new) | refuse raw font-size / off-set @media / raw z-index | 1 |
| `app/services/field_error_markup.rb` (new) | the field-error transformation, one class | 2 |
| `config/application.rb` | wire `field_error_proc` to `FieldErrorMarkup` | 2 |
| `spec/helpers/field_error_markup_spec.rb` (new) | unit behaviour through the real form helpers | 2 |
| `app/helpers/application_helper.rb` | `role="alert"` on the error summary | 2 |
| `app/views/layouts/{application,in_game}.html.erb` | `role` on flashes | 2 |
| `spec/requests/signup_inline_errors_spec.rb` (new) | inline error on a real form | 2 |
| `app/controllers/admin/styleguide_controller.rb` (new) | read-only page, superadmin | 3 |
| `app/views/admin/styleguide/show.html.erb` (new) | the specimens | 3 |
| `config/routes.rb` | `admin/styleguide` route | 3 |
| `app/views/admin/dashboard/show.html.erb` | link to it | 3 |
| `config/locales/*.yml` (7) | three keys | 3 |
| `spec/requests/admin_styleguide_spec.rb` (new) | access | 3 |
| `spec/layout/styleguide_layout_spec.rb` (new) | contrast, tap size, overflow, type scale, both themes | 4 |

---

### Task 1: Type scale and layer tokens, enforced

**Files:**
- Create: `spec/stylesheets/token_discipline_spec.rb`
- Modify: `public/stylesheets/tokens.css` (the final `:root { ... }` block, lines 50–71)
- Modify: `public/stylesheets/base.css:31,40,41,42`
- Modify: `public/stylesheets/components.css:57,71,113,136,166,222`
- Modify: `public/stylesheets/layout.css:46,82,147,212,239,255`
- Modify: `public/stylesheets/screens.css:115,133,137,185,257,329,421,426`

**Interfaces:**
- Produces: CSS custom properties `--text-xs`, `--text-sm`, `--text-md`, `--text-lg`, `--text-xl`, `--text-2xl`, `--text-body`, `--text-h1`, `--text-h2`, `--z-sticky`, `--z-scrim`, `--z-drawer`, `--z-topbar`, `--z-dropdown`. Tasks 2–4 use the `--text-*` names.

- [ ] **Step 1: Write the failing discipline spec**

`spec/stylesheets/token_discipline_spec.rb`:

```ruby
require "rails_helper"

# The 2026-09-30 foundations work snapped 19 font-size declarations onto one
# scale and named the stacking layers. This keeps it that way: a raw value in
# any of these four files is a step back to fourteen ad-hoc sizes.
#
# tokens.css is where the raw values live, so it is not checked. calendar.css
# and jquery.autocomplete.css are legacy widgets the next wave item deletes.
describe "stylesheet token discipline" do
  # Constants in a describe body land on Object, so the names are specific.
  TOKEN_DISCIPLINE_FILES = %w[base.css components.css layout.css screens.css].freeze

  # CSS variables do not work inside @media, so the breakpoints cannot be
  # tokens; this list is the token. See the header comment in tokens.css.
  TOKEN_DISCIPLINE_MEDIA_WIDTHS = [
    "min-width: 48rem", "max-width: 47.99rem", "min-width: 52rem", "min-width: 60rem"
  ].freeze

  # Comments are blanked rather than deleted so reported line numbers still
  # match the file. Several comments mention "z-index 40" in prose.
  def declarations(file)
    css = Rails.root.join("public/stylesheets", file).read
    css = css.gsub(%r{/\*.*?\*/}m) { |c| c.gsub(/[^\n]/, " ") }
    css.lines.each_with_index.map { |line, i| [i + 1, line] }
  end

  def offenders(pattern, &allowed)
    TOKEN_DISCIPLINE_FILES.flat_map do |file|
      declarations(file).filter_map do |number, line|
        line.scan(pattern).flatten.reject(&allowed).map { |value| "#{file}:#{number}: #{value.strip}" }
      end.flatten
    end
  end

  it "takes every font-size from the type scale" do
    bad = offenders(/font-size:\s*([^;]+);/) { |v| v.strip.match?(/\Avar\(--text-[a-z0-9]+\)\z/) || v.strip == "inherit" }
    expect(bad).to be_empty, "raw font-size, use a --text-* token:\n#{bad.join("\n")}"
  end

  it "uses only the documented breakpoints" do
    bad = offenders(/@media[^{]*\(((?:min|max)-width:[^)]+)\)/) { |v| TOKEN_DISCIPLINE_MEDIA_WIDTHS.include?(v.strip) }
    expect(bad).to be_empty, "undocumented breakpoint:\n#{bad.join("\n")}"
  end

  it "takes every z-index from a layer token" do
    bad = offenders(/z-index:\s*([^;]+);/) { |v| v.strip.match?(/\Avar\(--z-[a-z]+\)\z/) }
    expect(bad).to be_empty, "raw z-index, use a --z-* token:\n#{bad.join("\n")}"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/stylesheets/token_discipline_spec.rb`
Expected: 2 failures. "takes every font-size" lists 19 offenders; "takes every z-index" lists 5 (`layout.css:46`, `:147`, `:239`, `:255`, `screens.css:329`). "uses only the documented breakpoints" **passes** already — every current width is in the set.

- [ ] **Step 3: Add the tokens**

In `public/stylesheets/tokens.css`, replace the last `:root { ... }` block (from `:root {` before `--space-1` to its closing `}`) with:

```css
/* Breakpoints. CSS custom properties do not work inside @media, so these
 * cannot be tokens; this list is the contract instead, and
 * spec/stylesheets/token_discipline_spec.rb refuses any other width.
 *   max-width: 47.99rem / min-width: 48rem
 *       the drawer becomes a static column; .table--cards stops stacking
 *   min-width: 52rem
 *       the play bar becomes a side panel. Not noise: the owner's laptop is
 *       ~845 CSS px, just above 832, so folding this into 60rem would give
 *       that laptop the phone layout
 *   min-width: 60rem
 *       wide layouts
 */
:root {
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 24px;
  --space-6: 40px;

  --radius:    8px;
  --radius-sm: 6px;

  --font-ui:   system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;

  /* Type scale. Every font-size in base/components/layout/screens.css reads
     one of these. --text-body keeps its 16px floor: iOS zooms a focused
     input below 16px, and inputs inherit it. */
  --text-xs:   0.8rem;
  --text-sm:   0.875rem;
  --text-md:   1rem;
  --text-lg:   1.125rem;
  --text-xl:   1.25rem;
  --text-2xl:  1.5rem;
  --text-body: clamp(16px, 0.95rem + 0.2vw, 18px);
  --text-h1:   clamp(1.6rem, 1.3rem + 1.4vw, 2.4rem);
  --text-h2:   clamp(1.2rem, 1.05rem + 0.7vw, 1.6rem);

  /* Stacking layers. --z-dropdown and --z-scrim share a value, not a
     meaning: .locale-menu sits inside .topbar's stacking context, so its 25
     orders it only among the topbar's children. */
  --z-sticky:   15;  /* .playbar */
  --z-scrim:    25;  /* .drawer-scrim */
  --z-drawer:   30;  /* #drawer */
  --z-topbar:   40;  /* .topbar */
  --z-dropdown: 25;  /* .locale-menu */

  --tap: 44px;
}
```

- [ ] **Step 4: Map every font-size and z-index**

Make exactly these replacements (the value on each line changes; nothing else on the line does):

| File:line | Selector | From | To |
|---|---|---|---|
| `base.css:31` | `body` | `font-size: clamp(16px, 0.95rem + 0.2vw, 18px);` | `font-size: var(--text-body);` |
| `base.css:40` | `h1` | `font-size: clamp(1.6rem, 1.3rem + 1.4vw, 2.4rem);` | `font-size: var(--text-h1);` |
| `base.css:41` | `h2` | `font-size: clamp(1.2rem, 1.05rem + 0.7vw, 1.6rem);` | `font-size: var(--text-h2);` |
| `base.css:42` | `h3` | `font-size: 1.05rem;` | `font-size: var(--text-lg);` |
| `components.css:57` | `.field > label` | `font-size: 0.9rem;` | `font-size: var(--text-sm);` |
| `components.css:71` | `.generated-password` | `font-size: 1.15rem;` | `font-size: var(--text-lg);` |
| `components.css:113` | `th` | `font-size: 0.78rem;` | `font-size: var(--text-xs);` |
| `components.css:136` | `.table--cards td::before` | `font-size: 0.72rem;` | `font-size: var(--text-xs);` |
| `components.css:166` | `.file-table .file-thumb-generic` | `font-size: 0.68rem;` | `font-size: var(--text-xs);` |
| `components.css:222` | `.tag` | `font-size: 0.75rem;` | `font-size: var(--text-xs);` |
| `layout.css:46` | `.topbar` | `z-index: 40;` | `z-index: var(--z-topbar);` |
| `layout.css:82` | `.topbar-time` | `font-size: 0.875rem;` | `font-size: var(--text-sm);` |
| `layout.css:147` | `.locale-menu` | `z-index: 25;` | `z-index: var(--z-dropdown);` |
| `layout.css:212` | `#drawer-toggle` | `font-size: 1.2rem;` | `font-size: var(--text-xl);` |
| `layout.css:239` | `#drawer` | `z-index: 30;` | `z-index: var(--z-drawer);` |
| `layout.css:255` | `.drawer-scrim` | `z-index: 25;` | `z-index: var(--z-scrim);` |
| `screens.css:115` | `.participation` | `font-size: 0.9rem;` | `font-size: var(--text-sm);` |
| `screens.css:133` | `.stat-value` | `font-size: 1.8rem;` | `font-size: var(--text-h1);` |
| `screens.css:137` | `.stat-label` | `font-size: 0.78rem;` | `font-size: var(--text-xs);` |
| `screens.css:185` | `ul.language-tabs .missing-count` | `font-size: 0.78rem;` | `font-size: var(--text-xs);` |
| `screens.css:257` | `.notice, .hint-text` | `font-size: 0.9rem;` | `font-size: var(--text-sm);` |
| `screens.css:329` | `.playbar` | `z-index: 15;` | `z-index: var(--z-sticky);` |
| `screens.css:421` | `.attachment-item--generic` | `font-size: 0.78rem;` | `font-size: var(--text-xs);` |
| `screens.css:426` | `.attachment-generic-icon` | `font-size: 1.1rem;` | `font-size: var(--text-lg);` |

Keep the comment at `base.css:28-30` ("Scales with the viewport… The floor is 16px…"): it still sits above the body size, and the reasoning is worth having in both places.

- [ ] **Step 5: Run the spec to verify it passes**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/stylesheets/token_discipline_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 6: Mutation-test the spec**

Each mutation must turn the named example red and print the file and line; revert each before the next.

1. Add `.tag { font-size: 0.7rem; }` at the end of `components.css` → "takes every font-size" fails naming `components.css:<last line>: 0.7rem`.
2. Add `@media (min-width: 50rem) { .tag { color: red; } }` at the end of `screens.css` → "uses only the documented breakpoints" fails naming `min-width: 50rem`.
3. Change `layout.css:46` back to `z-index: 40;` → "takes every z-index" fails naming `layout.css:46: 40`.
4. Put `/* z-index: 99; */` on its own line in `layout.css` → **still passes** (comments are blanked).

Run after each: `bundle exec rspec spec/stylesheets/token_discipline_spec.rb`. Then `git diff --stat public/stylesheets` must show only the Step 3–4 changes.

- [ ] **Step 7: Commit**

```bash
git add public/stylesheets spec/stylesheets/token_discipline_spec.rb
git commit -m "Put every font size on one scale, and name the stacking layers

Snaps the 19 font-size declarations to six steps plus the three existing
fluid clamps, replaces the five raw z-index values with layer tokens, and
records the 48/52/60rem breakpoints as a contract. A new spec refuses raw
values in any of the four stylesheets."
```

---

### Task 2: Inline field errors and live regions

**Files:**
- Create: `app/services/field_error_markup.rb`
- Create: `spec/helpers/field_error_markup_spec.rb`
- Create: `spec/requests/signup_inline_errors_spec.rb`
- Modify: `config/application.rb` (inside `class Application`, after `config.i18n.available_locales = ...` at line 54)
- Modify: `app/helpers/application_helper.rb` (`error_messages_for`, the `markup = +"<div class=..."` line)
- Modify: `app/views/layouts/application.html.erb:42`, `app/views/layouts/in_game.html.erb:21`
- Modify: `public/stylesheets/components.css` (Forms section, after `.field > label`)

**Interfaces:**
- Produces: `FieldErrorMarkup.call(html_tag, instance) -> ActiveSupport::SafeBuffer`. CSS classes `is-invalid` (on controls and labels) and `field-error` (the message span, `id="<control-id>-error"`). Task 3's styleguide relies on these names.

- [ ] **Step 1: Write the failing unit spec**

`spec/helpers/field_error_markup_spec.rb`:

```ruby
require "rails_helper"

# Goes through the real form helpers, so it exercises the field_error_proc
# wiring in config/application.rb as well as FieldErrorMarkup itself.
# Errors are added by hand: no database, no validations, one known message.
describe FieldErrorMarkup, type: :helper do
  let(:game) { Game.new }

  def html(markup) = Nokogiri::HTML::DocumentFragment.parse(markup)

  context "an invalid text field" do
    before { game.errors.add(:name, "не может быть пустым") }
    let(:out) { helper.text_field(:game, :name, :object => game) }

    it "marks the control invalid" do
      input = html(out).at_css("input#game_name")
      expect(input["aria-invalid"]).to eq("true")
      expect(input["class"].split).to include("is-invalid")
    end

    it "links the control to its message" do
      doc = html(out)
      expect(doc.at_css("input#game_name")["aria-describedby"]).to eq("game_name-error")
      expect(doc.at_css("span.field-error#game_name-error").text).to eq("не может быть пустым")
    end

    it "does not wrap anything in Rails' field_with_errors div" do
      expect(out).not_to include("field_with_errors")
    end
  end

  it "joins several messages for one field" do
    game.errors.add(:name, "первое")
    game.errors.add(:name, "второе")
    out = helper.text_field(:game, :name, :object => game)
    expect(html(out).at_css("#game_name-error").text).to eq("первое; второе")
  end

  it "escapes a message, even one already marked html_safe" do
    game.errors.add(:name, "<b>жирный</b>".html_safe)
    out = helper.text_field(:game, :name, :object => game)
    expect(out).to include("&lt;b&gt;жирный&lt;/b&gt;")
    expect(html(out).at_css("#game_name-error b")).to be_nil
  end

  it "keeps a self-closing input valid" do
    game.errors.add(:name, "x")
    out = helper.text_field(:game, :name, :object => game)
    expect(out).not_to match(%r{/\s+aria-})
    expect(html(out).css("input").size).to eq(1)
  end

  it "keeps a textarea's content byte for byte, leading newline included" do
    game.description = "\nвторая строка"
    game.errors.add(:description, "x")
    out = helper.text_area(:game, :description, :object => game)
    expect(out).to include(">\n\nвторая строка</textarea>")
  end

  it "marks a radio button but gives it no message span" do
    game.errors.add(:visibility, "x")
    out = helper.radio_button(:game, :visibility, "draft", :object => game)
    expect(html(out).at_css("input[type=radio]")["aria-invalid"]).to eq("true")
    expect(out).not_to include("field-error")
  end

  it "gives a checkbox its message and leaves the companion hidden input alone" do
    game.errors.add(:points_enabled, "x")
    out = helper.check_box(:game, :points_enabled, :object => game)
    doc = html(out)
    expect(doc.at_css("input[type=hidden]")["aria-invalid"]).to be_nil
    expect(doc.at_css("input[type=checkbox]")["aria-invalid"]).to eq("true")
    expect(doc.at_css("#game_points_enabled-error").text).to eq("x")
  end

  it "gives a label the class and nothing else" do
    game.errors.add(:name, "x")
    out = helper.label(:game, :name, "Название", :object => game)
    label = html(out).at_css("label")
    expect(label["class"].split).to include("is-invalid")
    expect(label["aria-invalid"]).to be_nil
    expect(out).not_to include("field-error")
  end

  it "leaves a valid field exactly as Rails renders it" do
    expect(helper.text_field(:game, :name, :object => game)).not_to include("is-invalid")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/helpers/field_error_markup_spec.rb`
Expected: errors with `uninitialized constant FieldErrorMarkup`.

- [ ] **Step 3: Implement `FieldErrorMarkup`**

`app/services/field_error_markup.rb`:

```ruby
# app/services/field_error_markup.rb
#
# Rails' field_error_proc, set in config/application.rb. Called once per
# form control or label whose attribute has errors, with the tag Rails just
# rendered.
#
# Rails' default wraps the tag in <div class="field_with_errors">. That div
# lands between .field and its <label>, breaking `.field > label`, so every
# invalid field silently lost its label style. This marks the tag itself
# instead and, for a control with an id, puts the field's own messages
# directly after it -- on a phone the summary box at the top of the form is
# usually scrolled out of view.
#
# The opening tag is edited as a string, never parsed and re-serialised: a
# <textarea> opens with a newline Rails adds on purpose (the HTML parser eats
# the first one), and re-serialising would silently drop a leading newline
# from the user's own text.
class FieldErrorMarkup
  OPEN_TAG = %r{\A<(input|select|textarea|label)\b([^>]*?)(\s*/)?>}m

  def self.call(html_tag, instance)
    new(html_tag, instance).to_html
  end

  def initialize(html_tag, instance)
    @html_tag = html_tag.to_s
    @instance = instance
  end

  def to_html
    match = OPEN_TAG.match(@html_tag) or return @html_tag.html_safe
    name, attrs, slash = match[1], match[2], match[3]
    type = attribute(attrs, "type")
    return @html_tag.html_safe if type == "hidden"

    attrs = with_class(attrs)
    return rebuild(name, attrs, slash, match.post_match, "") if name == "label"

    attrs += ' aria-invalid="true"'
    id = attribute(attrs, "id")
    messages = messages_for_attribute
    span = ""
    if id && type != "radio" && messages.any?
      error_id = "#{id}-error"
      attrs += %( aria-describedby="#{CGI.escapeHTML(error_id)}")
      span = %(<span class="field-error" id="#{CGI.escapeHTML(error_id)}">) +
             CGI.escapeHTML(messages.join("; ")) + "</span>"
    end
    rebuild(name, attrs, slash, match.post_match, span)
  end

  private

  def rebuild(name, attrs, slash, rest, span)
    "<#{name}#{attrs}#{slash}>#{rest}#{span}".html_safe
  end

  # Rails always double-quotes attribute values and escapes them, so a value
  # cannot contain a bare double quote or ">".
  def attribute(attrs, name)
    attrs[/\s#{name}="([^"]*)"/, 1]
  end

  def with_class(attrs)
    if attrs.match?(/\sclass="/)
      attrs.sub(/\sclass="([^"]*)"/) { %( class="#{[$1, "is-invalid"].reject(&:empty?).join(" ")}") }
    else
      attrs + ' class="is-invalid"'
    end
  end

  def messages_for_attribute
    object = @instance.object
    method = @instance.instance_variable_get(:@method_name)
    return [] unless object.respond_to?(:errors) && method

    object.errors[method.to_sym].map(&:to_s)
  end
end
```

In `config/application.rb`, directly after `config.i18n.available_locales = [:ru, :en, :uk, :ka, :tr, :be, :pl]`, add:

```ruby
    # Mark invalid fields in place instead of wrapping them in Rails' default
    # <div class="field_with_errors">, which broke `.field > label`. A lambda
    # so FieldErrorMarkup (app/services, autoloaded) is resolved per call,
    # not at boot. See app/services/field_error_markup.rb.
    config.action_view.field_error_proc = ->(html_tag, instance) { FieldErrorMarkup.call(html_tag, instance) }
```

- [ ] **Step 4: Run the unit spec to verify it passes**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/helpers/field_error_markup_spec.rb`
Expected: 11 examples, 0 failures.

- [ ] **Step 5: Write the failing signup request spec**

`spec/requests/signup_inline_errors_spec.rb`:

```ruby
require "rails_helper"

# The real signup form, submitted with a blank nickname. User's messages are
# full sentences from the Merb era ("Вы не ввели имя"), not predicates; they
# read correctly under the field either way. The literal is pinned rather than
# I18n.t(...), which would also pass if the key went missing.
describe "inline errors on the signup form", type: :request do
  before do
    post users_path, :params => { :user => { :nickname => "", :email => "inline@example.com" } }
  end

  let(:doc) { Nokogiri::HTML(response.body) }

  it "re-renders the form as unprocessable" do
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "puts the nickname message directly under the nickname field" do
    input = doc.at_css("input#user_nickname")
    expect(input["aria-invalid"]).to eq("true")
    expect(input.next_element["id"]).to eq("user_nickname-error")
    expect(input.next_element.text).to eq("Вы не ввели имя")
  end

  it "still renders the summary, announced as an alert" do
    summary = doc.at_css("div.error")
    expect(summary["role"]).to eq("alert")
    expect(summary.text).to include("Вы не ввели имя")
  end
end
```

- [ ] **Step 6: Run it to verify the summary example fails**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/requests/signup_inline_errors_spec.rb`
Expected: the first two examples pass (the proc is wired); "still renders the summary, announced as an alert" fails — `role` is `nil`.

- [ ] **Step 7: Add the live-region roles**

In `app/helpers/application_helper.rb`, in `error_messages_for`, change:

```ruby
    markup = +"<div class='#{ERB::Util.html_escape(error_class)}'>#{header_message}<ul>"
```

to:

```ruby
    # role="alert": the summary appears on the response to a failed submit,
    # and a screen reader should announce it rather than leave it to be found.
    markup = +"<div class='#{ERB::Util.html_escape(error_class)}' role='alert'>#{header_message}<ul>"
```

In both `app/views/layouts/application.html.erb:42` and `app/views/layouts/in_game.html.erb:21`, change:

```erb
          <p class="flash flash--<%= type %>"><%= message %></p>
```

to:

```erb
          <p class="flash flash--<%= type %>" role="<%= type.to_s == "notice" ? "status" : "alert" %>"><%= message %></p>
```

(Check `in_game.html.erb:21`'s exact indentation before replacing; only the attribute is added.)

- [ ] **Step 8: Add the invalid-state CSS**

In `public/stylesheets/components.css`, directly after the `.field > label { ... }` line (57), add:

```css
/* Set by FieldErrorMarkup (app/services/field_error_markup.rb), Rails'
   field_error_proc here. A control and its label are marked in place; the
   control's own messages follow it in .field-error. */
label.is-invalid { color: var(--danger); }
.is-invalid:is(input, select, textarea) { border-color: var(--danger); }
.field-error {
  display: block;
  margin-top: var(--space-1);
  color: var(--danger);
  font-size: var(--text-sm);
}
```

- [ ] **Step 9: Run both new specs and the existing helper and token specs**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/helpers/field_error_markup_spec.rb spec/requests/signup_inline_errors_spec.rb spec/stylesheets/token_discipline_spec.rb spec/helpers`
Expected: 0 failures.

- [ ] **Step 10: Commit**

```bash
git add app/services/field_error_markup.rb config/application.rb app/helpers/application_helper.rb \
        app/views/layouts/application.html.erb app/views/layouts/in_game.html.erb \
        public/stylesheets/components.css spec/helpers/field_error_markup_spec.rb \
        spec/requests/signup_inline_errors_spec.rb
git commit -m "Show each field's error under the field, and announce failed submits

Replaces Rails' field_with_errors wrapper, which broke the label style on
every invalid field, with aria-invalid on the control and its messages in a
linked span directly after it. The error summary becomes an alert and
flashes get status or alert roles."
```

---

### Task 3: The styleguide page

**Files:**
- Create: `app/controllers/admin/styleguide_controller.rb`
- Create: `app/views/admin/styleguide/show.html.erb`
- Create: `spec/requests/admin_styleguide_spec.rb`
- Modify: `config/routes.rb` (inside `namespace :admin do`, after the `get "/", to: "dashboard#show", as: :dashboard` line)
- Modify: `app/views/admin/dashboard/show.html.erb` (append at the end)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`

**Interfaces:**
- Consumes: `is-invalid`, `field-error` (Task 2); `--text-*` tokens (Task 1).
- Produces: route helper `admin_styleguide_path`; the page markup Task 4 measures — every specimen inside `<div class="styleguide">`, checkbox and radio rows as `<label class="check">`, the secondary button as `.btn.btn--quiet`.

- [ ] **Step 1: Write the failing access spec**

`spec/requests/admin_styleguide_spec.rb`:

```ruby
require "rails_helper"

describe "the styleguide", type: :request do
  let(:superadmin) do
    u = create_user
    u.update!(:is_superadmin => true)
    u
  end
  let(:ordinary) { create_user }

  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary user" do
    login_as(ordinary)
    get admin_styleguide_path

    expect(response).not_to have_http_status(:ok)
  end

  it "refuses a signed-out visitor" do
    get admin_styleguide_path

    expect(response).not_to have_http_status(:ok)
  end

  context "for a superadmin" do
    before do
      login_as(superadmin)
      get admin_styleguide_path
    end

    let(:doc) { Nokogiri::HTML(response.body) }

    it "renders" do
      expect(response).to have_http_status(:ok)
    end

    # The invalid specimens come from a real Game.valid?, so they are drawn by
    # the real field_error_proc -- not hand-copied markup that could drift.
    it "renders real invalid specimens" do
      expect(doc.at_css("input#game_name.is-invalid")).to be_present
      expect(doc.at_css("#game_name-error")).to be_present
      expect(doc.at_css("input#game_max_team_number[type=number][aria-invalid=true]")).to be_present
      expect(doc.at_css("input[type=radio][name='game[visibility]'][aria-invalid=true]")).to be_present
    end

    it "shows every button kind" do
      %w[btn--go btn--quiet btn--danger].each do |kind|
        expect(doc.at_css(".styleguide .btn.#{kind}")).to be_present, kind
      end
      expect(doc.at_css(".styleguide .btn[disabled]")).to be_present
    end

  end

  it "writes nothing to the database" do
    login_as(superadmin)

    expect { get admin_styleguide_path }.not_to change(Game, :count)
  end

  it "is linked from the admin dashboard" do
    login_as(superadmin)
    get admin_dashboard_path

    expect(response.body).to include(admin_styleguide_path)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/requests/admin_styleguide_spec.rb`
Expected: errors with `undefined local variable or method 'admin_styleguide_path'`.

- [ ] **Step 3: Route, controller, i18n**

`config/routes.rb`, inside `namespace :admin do`, after `get "/", to: "dashboard#show", as: :dashboard`:

```ruby
    # Every shared component, rendered from real code. Read-only, so no audit
    # entry -- see spec/requests/admin_audit_spec.rb.
    get "/styleguide", to: "styleguide#show", as: :styleguide
```

`app/controllers/admin/styleguide_controller.rb`:

```ruby
# A page that renders every shared component, for reviewing the theme on a
# real device and for spec/layout/styleguide_layout_spec.rb to measure.
#
# Read-only, so no AdminAudit call: that concern records changes, and
# spec/requests/admin_audit_spec.rb enumerates only mutating actions.
class Admin::StyleguideController < ApplicationController
  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    # The invalid specimens are drawn by the real field_error_proc. valid?
    # writes nothing; the uniqueness check on name only reads.
    @invalid_game = Game.new(:name => "", :max_team_number => 0, :visibility => "bogus")
    @invalid_game.valid?
    @valid_game = Game.new(:name => "Ночной город", :max_team_number => 12, :visibility => "listed")
  end
end
```

Add three keys to each locale file under the existing `admin:` mapping (do not create a second `admin:` key — `spec/i18n_spec.rb` "defines no key twice" would fail). Add `styleguide:` as a sibling of `dashboard:` inside `admin:`, and add `styleguide_link` inside `admin.dashboard.show`:

| Locale | `admin.styleguide.show.title` | `admin.styleguide.show.intro` | `admin.dashboard.show.styleguide_link` |
|---|---|---|---|
| ru | `"Стайлгайд"` | `"Все общие компоненты в текущей теме. Переключите тему в шапке, чтобы проверить вторую."` | `"Стайлгайд интерфейса"` |
| en | `"Styleguide"` | `"Every shared component in the current theme. Switch the theme in the header to check the other."` | `"Interface styleguide"` |
| uk | `"Стайлгайд"` | `"Усі спільні компоненти в поточній темі. Перемкніть тему в шапці, щоб перевірити другу."` | `"Стайлгайд інтерфейсу"` |
| be | `"Стайлгайд"` | `"Усе агульныя кампаненты ў бягучай тэме. Пераключыце тэму ў шапцы, каб праверыць другую."` | `"Стайлгайд інтэрфейсу"` |
| pl | `"Przewodnik stylu"` | `"Wszystkie wspólne komponenty w bieżącym motywie. Przełącz motyw w nagłówku, aby sprawdzić drugi."` | `"Przewodnik stylu interfejsu"` |
| tr | `"Stil rehberi"` | `"Tüm ortak bileşenler geçerli temada. Diğerini kontrol etmek için başlıktan temayı değiştirin."` | `"Arayüz stil rehberi"` |
| ka | `"სტილის გზამკვლევი"` | `"ყველა საერთო კომპონენტი მიმდინარე თემაში. მეორის შესამოწმებლად თემა სათაურში გადართეთ."` | `"ინტერფეისის სტილის გზამკვლევი"` |

- [ ] **Step 4: The view**

`app/views/admin/styleguide/show.html.erb`. Specimen strings are sample content, rendered verbatim and deliberately not i18n'd (spec §3). The countdown is shown as a static `.countdown` span: the real `shared/_countdown` partial needs a live `@game` and jQuery, and only its look is being specimened.

```erb
<div class="styleguide">
  <h1><%= t("admin.styleguide.show.title") %></h1>
  <p class="notice"><%= t("admin.styleguide.show.intro") %></p>

  <h2>Type</h2>
  <% %w[h1 h2 2xl xl lg md body sm xs].each do |step| %>
    <p style="font-size: var(--text-<%= step %>)">--text-<%= step %> · Ночной город, уровень 3</p>
  <% end %>

  <h2>Colour</h2>
  <div class="stat-grid">
    <% %w[bg surface surface-2 border border-input text text-dim go time danger focus].each do |token| %>
      <div class="stat">
        <div style="height: 2.5rem; border-radius: var(--radius-sm); border: 1px solid var(--border); background: var(--<%= token %>)"></div>
        <div class="stat-label">--<%= token %></div>
      </div>
    <% end %>
  </div>

  <h2>Buttons</h2>
  <p>
    <button type="button" class="btn btn--go">Отправить</button>
    <button type="button" class="btn">Сохранить</button>
    <button type="button" class="btn btn--quiet">Отмена</button>
    <button type="button" class="btn btn--danger">Удалить</button>
  </p>
  <p>
    <button type="button" class="btn btn--go" disabled>Отправить</button>
    <button type="button" class="btn" disabled>Сохранить</button>
    <button type="button" class="btn btn--quiet" disabled>Отмена</button>
    <button type="button" class="btn btn--danger" disabled>Удалить</button>
  </p>

  <h2>Inputs</h2>
  <%= form_with :model => @valid_game, :url => admin_styleguide_path, :method => :get, :scope => :valid_game do |f| %>
    <div class="field"><%= f.label :name, "Название" %><%= f.text_field :name %></div>
    <div class="field"><%= f.label :max_team_number, "Команд" %><%= f.number_field :max_team_number %></div>
    <div class="field"><label for="sg_email">E-mail</label><input type="email" id="sg_email" value="captain@example.com"></div>
    <div class="field"><label for="sg_password">Пароль</label><input type="password" id="sg_password" value="secret"></div>
    <div class="field"><label for="sg_search">Поиск</label><input type="search" id="sg_search"></div>
    <div class="field"><label for="sg_url">Ссылка</label><input type="url" id="sg_url"></div>
    <div class="field"><label for="sg_tel">Телефон</label><input type="tel" id="sg_tel"></div>
    <div class="field"><label for="sg_date">Дата</label><input type="date" id="sg_date"></div>
    <div class="field"><label for="sg_datetime">Начало</label><input type="datetime-local" id="sg_datetime"></div>
    <div class="field"><label for="sg_select">Язык</label><select id="sg_select"><option>Русский</option><option>English</option></select></div>
    <div class="field"><%= f.label :description, "Описание" %><%= f.text_area :description %></div>
    <div class="field"><label for="sg_disabled">Отключено</label><input type="text" id="sg_disabled" value="только чтение" disabled></div>
  <% end %>

  <h2>Invalid</h2>
  <%= error_messages_for @invalid_game, :header => "<h2>#{t("shared.error_header")}</h2>" %>
  <%= form_with :model => @invalid_game, :url => admin_styleguide_path, :method => :get, :scope => :game do |f| %>
    <div class="field"><%= f.label :name, "Название" %><%= f.text_field :name %></div>
    <div class="field"><%= f.label :max_team_number, "Команд" %><%= f.number_field :max_team_number %></div>
    <div class="field"><%= f.label :description, "Описание" %><%= f.text_area :description %></div>
    <fieldset class="field">
      <legend>Видимость</legend>
      <label class="check"><%= f.radio_button :visibility, "draft" %> Черновик</label>
      <label class="check"><%= f.radio_button :visibility, "listed" %> В списке</label>
    </fieldset>
  <% end %>

  <h2>Checks</h2>
  <label class="check"><input type="checkbox" checked> Начислять очки</label>
  <label class="check"><input type="checkbox"> Разрешить пропуск уровня</label>
  <label class="check"><input type="checkbox" disabled> Отключённый флажок</label>
  <label class="check"><input type="radio" name="sg_radio" checked> Командная игра</label>
  <label class="check"><input type="radio" name="sg_radio"> Одиночная игра</label>

  <h2>File</h2>
  <div class="field"><label for="sg_file">Вложение</label><input type="file" id="sg_file"></div>

  <h2>Flash</h2>
  <p class="flash flash--notice" role="status">Игра сохранена.</p>
  <p class="flash flash--error" role="alert">Неверный код.</p>

  <h2>Table</h2>
  <table class="table--cards">
    <thead><tr><th>Команда</th><th>Уровень</th><th>Время</th></tr></thead>
    <tbody>
      <tr><td data-label="Команда">Совы</td><td data-label="Уровень">3</td><td data-label="Время">01:12:40</td></tr>
      <tr><td data-label="Команда">Ёжики</td><td data-label="Уровень">2</td><td data-label="Время">01:30:05</td></tr>
    </tbody>
  </table>

  <h2>Tags and countdown</h2>
  <p>
    <span class="tag">черновик</span>
    <span class="tag tag--live">идёт</span>
    <span class="tag tag--danger">закрыта</span>
  </p>
  <p class="countdown">До следующей подсказки 12 мин 04 сек</p>
</div>
```

Note on the two `style=` attributes: they are the specimens themselves (each type step, each swatch), driven by tokens, on a page that exists to show tokens. They are not layout and do not belong in a stylesheet.

Append to `app/views/admin/dashboard/show.html.erb`:

```erb

<p><%= link_to t("admin.dashboard.show.styleguide_link"), admin_styleguide_path %></p>
```

- [ ] **Step 5: Run the access spec and the i18n specs**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec spec/requests/admin_styleguide_spec.rb spec/i18n_spec.rb spec/i18n_play_screen_spec.rb spec/requests/admin_audit_spec.rb spec/requests/admin_nav_spec.rb`
Expected: 0 failures. If `admin_audit_spec.rb` fails because it enumerates every admin route, add `admin_styleguide` to its explicit list of **read-only** routes the way it lists other GETs — do not add an audit call.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/admin/styleguide_controller.rb app/views/admin/styleguide config/routes.rb \
        app/views/admin/dashboard/show.html.erb config/locales spec/requests/admin_styleguide_spec.rb
git commit -m "Add a superadmin styleguide that renders every shared component

One read-only page with the type scale, colour tokens, every button and
input kind, real invalid specimens from Game#valid?, flashes, a card table
and tags. Linked from the admin dashboard; three keys in all seven locales."
```

---

### Task 4: Complete the form controls, measured

**Files:**
- Create: `spec/layout/styleguide_layout_spec.rb`
- Modify: `public/stylesheets/tokens.css` (both theme blocks)
- Modify: `public/stylesheets/components.css` (Buttons and Forms sections)

**Interfaces:**
- Consumes: the styleguide page and class names from Task 3; `LayoutMeasurement#measure(html, width, height, script, tmp_name:)` from `spec/support/layout_measurement.rb`, which returns the probe's `RESULT` as a Hash.
- Produces: `--border-input` token; `.btn--quiet`; `.check`; `:disabled` styling.

- [ ] **Step 1: Write the failing layout spec**

`spec/layout/styleguide_layout_spec.rb`:

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# The styleguide, measured in a real browser in both themes. Neither suite
# can see contrast, tap size or computed font size; this is where the form
# system's promises are checked. Excluded from the default run (needs
# chrome-headless-shell); run with LAYOUT_SPECS=1. A missing browser raises.
describe "the styleguide, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    admin = create_user
    admin.update!(:is_superadmin => true)
    put login_path, :params => { :email => admin.email, :password => "1234" }
    get admin_styleguide_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");

      function rgb(s) { var m = s.match(/[\\d.]+/g).map(Number); return { r: m[0], g: m[1], b: m[2], a: m.length > 3 ? m[3] : 1 }; }
      function lum(c) {
        var f = function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
      }
      function ratio(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
      function backdrop(el) {
        for (var n = el.parentElement; n; n = n.parentElement) {
          var c = rgb(getComputedStyle(n).backgroundColor);
          if (c.a > 0) return c;
        }
        return rgb(getComputedStyle(document.body).backgroundColor);
      }

      // WCAG 1.4.11 exempts inactive components, so :disabled is excluded --
      // by the pseudo-class, not by any class name.
      var controls = Array.prototype.slice.call(document.querySelectorAll(
        ".styleguide input:not([type=checkbox]):not([type=radio]):not([type=file]):not(:disabled), " +
        ".styleguide select:not(:disabled), .styleguide textarea:not(:disabled)"
      ));
      var lowContrast = controls.map(function (el) {
        var s = getComputedStyle(el), border = rgb(s.borderTopColor);
        var fill = rgb(s.backgroundColor);
        var worst = Math.min(ratio(border, fill), ratio(border, backdrop(el)));
        return { id: el.id || el.name || el.type, worst: Math.round(worst * 100) / 100 };
      }).filter(function (c) { return c.worst < 3; });

      var shortTargets = Array.prototype.slice.call(document.querySelectorAll(".styleguide .btn, .styleguide .check"))
        .map(function (el) { return { text: el.textContent.trim().slice(0, 30), h: Math.round(el.getBoundingClientRect().height) }; })
        .filter(function (t) { return t.h < 44; });

      // The allowed sizes are read from the tokens in this page, at this
      // viewport -- the clamps resolve differently at 390 and 1280.
      var steps = ["xs", "sm", "md", "lg", "xl", "2xl", "body", "h1", "h2"];
      var allowed = steps.map(function (s) {
        var d = document.createElement("span");
        d.style.fontSize = "var(--text-" + s + ")";
        document.body.appendChild(d);
        var px = parseFloat(getComputedStyle(d).fontSize);
        d.remove();
        return px;
      });
      function inScale(px) { return allowed.some(function (a) { return Math.abs(a - px) < 0.05; }); }
      var offScale = Array.prototype.slice.call(document.body.querySelectorAll("*"))
        .filter(function (el) {
          if (el.closest("script, style, pre")) return false;
          if (el.matches("input[type=checkbox], input[type=radio]")) return false;
          if (el.matches("input, select, textarea, button")) return true;
          return Array.prototype.some.call(el.childNodes, function (n) { return n.nodeType === 3 && n.textContent.trim() !== ""; });
        })
        .map(function (el) { return { tag: el.tagName.toLowerCase() + (el.className ? "." + String(el.className).split(" ").join(".") : ""), px: parseFloat(getComputedStyle(el).fontSize) }; })
        .filter(function (e) { return !inScale(e.px); });

      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        controls: controls.length,
        lowContrast: lowContrast,
        shortTargets: shortTargets,
        offScale: offScale,
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  %w[dark light].each do |theme|
    { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
      context "#{theme} theme at #{width}x#{height} -- #{name}" do
        let(:m) { measure(page_html, width, height, probe(theme), :tmp_name => "styleguide-measure.html") }

        it "measured the theme it was asked for, and found controls to measure" do
          expect(m["theme"]).to eq(theme)
          expect(m["controls"]).to be >= 12
        end

        it "draws every enabled form control's border at 3:1 or better" do
          expect(m["lowContrast"]).to eq([])
        end

        it "makes every button and check row at least 44px tall" do
          expect(m["shortTargets"]).to eq([])
        end

        it "puts every text size on the type scale" do
          expect(m["offScale"]).to eq([])
        end

        it "does not scroll sideways" do
          expect(m["hOverflow"]).to eq(0)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && LAYOUT_SPECS=1 bundle exec rspec spec/layout/styleguide_layout_spec.rb`
Expected: in all four contexts, "draws every enabled form control's border" fails at least for the text, email and password inputs and the textarea (their `--border` measures 1.2–1.45:1; the unstyled `number`/`search`/`url`/`tel`/`datetime-local` inputs get the browser's own border, which may or may not pass); "makes every button and check row at least 44px" fails listing the `.check` rows; "puts every text size on the type scale" fails listing the `input[type=number]` and other unstyled controls at the browser's 13.33px. If it raises "No chrome-headless-shell found", install it (`npx playwright install chromium`) — do not skip.

- [ ] **Step 3: Add `--border-input`**

In `public/stylesheets/tokens.css`, dark block, after `--border:     #332e29;`:

```css
  /* Form-control edges. WCAG 1.4.11 needs 3:1 for the boundary that tells
     you where a field is; --border (1.41 / 1.30 / 1.21) is decorative and
     stays for cards. Against bg / surface / surface-2: 3.92 / 3.61 / 3.37. */
  --border-input: #7a7066;
```

Light block, after `--border:     #ddd5cd;`:

```css
  /* As in the dark block. --border is 1.37 / 1.45 / 1.27 here.
     Against bg / surface / surface-2: 3.91 / 4.14 / 3.62. */
  --border-input: #857b71;
```

- [ ] **Step 4: Complete the controls**

In `public/stylesheets/components.css`:

After `.btn--danger:hover { ... }` add:

```css
/* Secondary: cancel, back. Quieter than neutral, never competing with go. */
.btn--quiet {
  background: transparent;
  border-color: transparent;
  color: var(--text-dim);
}
.btn--quiet:hover { color: var(--text); border-color: transparent; }

/* Disabled by colour and cursor, never opacity: a faded control on the dark
   theme becomes unreadable rather than inactive. WCAG exempts inactive
   controls from contrast minimums; legibility is still the point. */
.btn:disabled,
.btn:disabled:hover {
  background: var(--surface);
  border-color: var(--border);
  color: var(--text-dim);
  cursor: not-allowed;
}
```

Update the hierarchy comment at the top of the Buttons section so it reads:

```css
/* --- Buttons -------------------------------------------------------------
 * Hierarchy: go -> neutral (.btn) -> quiet, with danger set apart.
 * go / time / danger are neighbouring hues in this palette, so they are
 * separated by TREATMENT as well:
 *   .btn--go     filled, the only filled warm control on a screen
 *   .btn--quiet  no fill, no border -- cancel and back
 *   .btn--danger outlined, never filled, always behind a confirm
 *   .countdown   not a button at all -- see below
 */
```

Replace the input selector and border at lines 77–83:

```css
input[type="text"], input[type="email"], input[type="password"],
input[type="date"], textarea, select {
```

with:

```css
input[type="text"], input[type="email"], input[type="password"],
input[type="date"], input[type="datetime-local"], input[type="number"],
input[type="search"], input[type="url"], input[type="tel"],
textarea, select {
```

and inside that same rule change `border: 1px solid var(--border);` to `border: 1px solid var(--border-input);`.

After `textarea { min-height: 8em; }` add:

```css
input:disabled, select:disabled, textarea:disabled {
  background: var(--surface);
  color: var(--text-dim);
  cursor: not-allowed;
}

/* A checkbox or radio wrapped in its label: the whole row is the target. */
.check {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  min-height: var(--tap);
  cursor: pointer;
}
input[type="checkbox"], input[type="radio"] {
  width: 1.25rem;
  height: 1.25rem;
  margin: 0;
  accent-color: var(--go);
}

input[type="file"] { font: inherit; }
input[type="file"]::file-selector-button {
  min-height: var(--tap);
  margin-right: var(--space-3);
  padding: 0 var(--space-4);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: var(--surface-2);
  color: var(--text);
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}

fieldset.field { border: 0; padding: 0; }
fieldset.field > legend { margin-bottom: var(--space-1); color: var(--text-dim); font-size: var(--text-sm); }
```

- [ ] **Step 5: Run the layout spec to verify it passes**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && LAYOUT_SPECS=1 bundle exec rspec spec/layout/styleguide_layout_spec.rb spec/stylesheets/token_discipline_spec.rb`
Expected: 20 layout examples and 3 discipline examples, 0 failures. If `offScale` lists an element, fix the CSS so the element takes a `--text-*` token — never widen the probe's allowed list.

- [ ] **Step 6: Mutation-check the probe**

1. In `tokens.css` dark block, temporarily set `--border-input: #4a433d;` → "draws every enabled form control's border" fails in the dark contexts only. Revert.
2. Temporarily delete `min-height: var(--tap);` from `.check` → "makes every button and check row" fails. Revert.
3. Temporarily add `disabled` to the `sg_select` `<select>` in the view → the contrast example still passes and `controls` drops by one (proves `:disabled` is what excludes). Revert.

Re-run Step 5 after reverting; it must be green.

- [ ] **Step 7: Commit**

```bash
git add public/stylesheets/tokens.css public/stylesheets/components.css spec/layout/styleguide_layout_spec.rb
git commit -m "Complete the form controls, and measure them in both themes

Input borders move to a new --border-input token at 3:1 or better against
every surface, the shared input rule covers number, search, url, tel and
datetime-local, checkboxes and radios get 44px label rows, the file button
matches .btn, and buttons gain quiet and disabled states. A layout spec
checks contrast, tap size, type scale and overflow on the styleguide."
```

---

### Task 5: Verification and PR (orchestrator)

The orchestrator does this task itself; it runs the full suites.

**Files:** none modified unless a check fails.

- [ ] **Step 1: Play screen**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bin/measure-play-screen`
Expected: pass at 390×680, 375×553 and 1280×800. The `.hint-text` size moved 0.9 → 0.875rem.

- [ ] **Step 2: All layout specs**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && LAYOUT_SPECS=1 bundle exec rspec spec/layout`
Expected: 0 failures across all four files.

- [ ] **Step 3: Full RSpec**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec rspec`
Expected: 0 failures; pending count unchanged from master (6). Record the example count at this commit.

- [ ] **Step 4: Full Cucumber and the inherited contract**

Run: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" && bundle exec cucumber`
Then the inherited-contract run from CLAUDE.md:

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected: 228 scenarios (226 passed, 2 undefined) / 2325 steps. `git diff origin/master --stat -- features/` must print nothing.

- [ ] **Step 5: Before/after screenshots**

Both themes, 390 and 1280 wide, on master and on this branch: the play screen, signup submitted with a blank nickname, the dashboard, the new-game form (number fields and checkboxes), the admin dashboard (`.stat-value`), and a game's file table containing a non-image attachment (the generic thumbnail label, 0.68 → 0.8rem in a 48px box — it must not clip). Save under the scratchpad; attach the play screen and new-game pairs to the PR description.

- [ ] **Step 6: Open the PR**

Push `design/foundations` and open a PR titled "UX foundations: one type scale, a complete form system, and a styleguide". The body lists: the spec and plan paths; what changed visibly (labels and tags 11–12px → 12.8px, input borders, inline errors); the measured RSpec count; the inherited Cucumber figure; the screenshots; and that C (exit confirm) is deferred pending a feature-file decision.
