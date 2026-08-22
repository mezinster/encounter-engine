# The manual on the web — implementation plan (sub-project A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the user manual at `/manual`, rendered from `docs/manual/*.md` at
request time, in the reader's locale, inside the app's own layout.

**Architecture:** Three collaborators, each with one job. `Manual::Source`
answers "give me the manual for locale X" from the files that ship in the image
and reports which locale it actually used. `Manual::Renderer` turns that
markdown into HTML and rewrites its relative links. `ManualController` joins
them with a `Rails.cache` entry keyed on the file's digest. `Manual::Source` is
the seam sub-project B replaces; nothing above it changes when it does.

**Tech Stack:** Rails 8.0.5.1, Ruby 3.3.12, kramdown + kramdown-parser-gfm
(new), Nokogiri (already present via Rails), RSpec, Cucumber.

**Spec:** `docs/superpowers/specs/2026-08-22-manual-on-the-web-design.md` — read
it first; this plan argues from it and does not repeat its reasoning.

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Every command below assumes
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` has been run.
- **Never edit a `.feature` file.** Not one character, of either provenance.
  This work adds no feature file and changes none.
- **Hash rockets** (`:key => value`) throughout, including for symbol keys —
  match the surrounding file.
- **A new i18n key goes into all seven locale files** (`ru`, `en`, `uk`, `ka`,
  `tr`, `be`, `pl`). The test environment sets `raise_on_missing_translations`,
  and `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity.
- **`create_user` takes no arguments** (it generates its own nickname and
  e-mail); the password every fixture user has is `"1234"`; request specs sign
  in with `put login_path, :params => { :email => ..., :password => "1234" }`.
- **Never assert with `include(I18n.t(key))`** — it cannot fail on a missing
  key, because both sides resolve the same way. Pin the literal string.
- **If `db/test.sqlite3` is locked** by another session's suite, do not wait:
  run with `DATABASE_URL="sqlite3:/tmp/claude-1000/manual-plan-test.sqlite3"`
  and `bin/rails db:test:prepare` against it first.
- **The full Cucumber and RSpec suites are run by the orchestrator**, not by a
  task subagent. A subagent that backgrounds a suite stalls.
- **Do not add a markdown gem other than the two named here** without redoing
  the measurement in §2.1 of the spec.

---

## File map

| File | Responsibility |
|---|---|
| `Gemfile` | Adds `kramdown`, `kramdown-parser-gfm` |
| `app/services/manual/renderer.rb` | markdown → HTML; rewrites relative links. No filesystem, no locale knowledge |
| `app/services/manual/source.rb` | locale → `{markdown, locale_used, digest}` from `docs/manual/`. The seam for sub-project B |
| `app/controllers/manual_controller.rb` | Joins the two, caches on digest |
| `app/views/manual/show.html.erb` | The `.manual` wrapper, the fallback note, the rendered HTML |
| `app/views/layouts/_left_menu.html.erb` | One link in each of the two branches |
| `config/routes.rb` | `get "/manual"` |
| `config/locales/*.yml` (7) | `layout.left_menu.manual`, `manual.fallback_note` |
| `public/stylesheets/screens.css` | `.manual` rules; tables scroll, the page does not |
| `.dockerignore` | Re-includes `docs/manual` |
| `.github/workflows/images.yml` | Proves `/manual` serves from the built image |
| `spec/services/manual/renderer_spec.rb` | Anchor integrity over the four real files |
| `spec/services/manual/source_spec.rb` | Locale resolution, fallback, digest, missing-directory failure |
| `spec/requests/manual_spec.rb` | The page, the fallback note, the menu links |
| `spec/layout/manual_layout_spec.rb` | Horizontal overflow is 0 at 390×660 |

---

### Task 1: The renderer's parse stage, and the anchor-integrity guard

The whole point of this task is the spec, not the four lines of implementation:
it is the only thing standing between a heading rename and a table of contents
that silently scrolls nowhere.

**Files:**
- Modify: `Gemfile`
- Create: `app/services/manual/renderer.rb`
- Test: `spec/services/manual/renderer_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Manual::Renderer.call(markdown) -> String` (an HTML fragment).
  Task 2 extends the same entry point; Task 4 calls it.

- [ ] **Step 1: Add the gems**

In `Gemfile`, after the `gem "anthropic", "~> 1.0"` line:

```ruby
# The user manual is markdown in docs/manual, rendered at request time (see
# app/services/manual/renderer.rb). Pure Ruby, so nothing new compiles in the
# docker build stage. The GFM parser is what supplies tables and ``` fences;
# kramdown's own dialect has neither in the form these files use.
gem "kramdown", "~> 2.5"
gem "kramdown-parser-gfm", "~> 1.1"
```

Run: `bundle install`
Expected: `kramdown 2.5.2` and `kramdown-parser-gfm 1.1.0` installed, and
`Gemfile.lock` updated. `config/application.rb` calls `Bundler.require`, so no
explicit `require` is needed anywhere.

- [ ] **Step 2: Write the failing test**

Create `spec/services/manual/renderer_spec.rb`:

```ruby
require "rails_helper"

# Renders the SHIPPED manuals, not a fixture, and that is the point.
#
# The risk this file exists for is a heading whose generated id stops matching
# the ](#anchor) written to point at it -- and the damage is invisible: the
# page renders, the link is clickable and styled, the browser scrolls nowhere,
# nothing raises. Only the real documents can demonstrate it.
#
# Measured on 2026-08-22 (see the design doc, §2.1): kramdown 2.5.2 produces
# руководство-пользователя, установка and 6-первый-администратор, with zero
# dead anchors across all four files. Nothing guarantees it keeps agreeing with
# GitHub on headings these files do not yet contain, which is why this is a
# test rather than a comment.
MANUAL_FILES = Rails.root.glob("docs/manual/*.md").sort.freeze

describe Manual::Renderer do
  it "is looking at all four manuals" do
    expect(MANUAL_FILES.map { |path| path.basename.to_s })
      .to eq(%w[deployment.en.md deployment.ru.md en.md ru.md])
  end

  MANUAL_FILES.each do |path|
    context path.basename.to_s do
      let(:doc) { Nokogiri::HTML5.fragment(Manual::Renderer.call(path.read)) }
      let(:ids) { doc.css("[id]").map { |node| node["id"] } }

      it "resolves every internal anchor" do
        wanted = doc.css("a[href^='#']").map { |a| a["href"].delete_prefix("#") }.uniq

        expect(wanted - ids).to eq([])
      end

      it "gives every heading a distinct id" do
        expect(ids.tally.select { |_id, count| count > 1 }).to eq({})
      end

      it "renders the markdown tables as tables" do
        expect(doc.css("table").size).to eq(6)
      end

      # hard_wrap: the GFM parser defaults it to TRUE, which turns every single
      # newline into <br>. These manuals are hard-wrapped prose at ~85 columns,
      # so the default renders 158-189 spurious line breaks per file and every
      # paragraph keeps its authoring width instead of the browser's.
      it "emits no <br> for the source's own line wrapping" do
        expect(doc.css("br")).to be_empty
      end
    end
  end

  it "keeps the Cyrillic heading ids the manuals link to" do
    doc = Nokogiri::HTML5.fragment(Manual::Renderer.call(Rails.root.join("docs/manual/ru.md").read))

    expect(doc.css("[id]").map { |node| node["id"] })
      .to include("руководство-пользователя", "игроку", "файлы-и-изображения")
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bundle exec rspec spec/services/manual/renderer_spec.rb`
Expected: every example errors with
`NameError: uninitialized constant Manual::Renderer`.

- [ ] **Step 4: Write the implementation**

Create `app/services/manual/renderer.rb`:

```ruby
# app/services/manual/renderer.rb
#
# The user manual's markdown, as HTML.
#
# Deliberately knows nothing about locales or the filesystem -- Manual::Source
# decides WHICH document this is, and this decides what it looks like. That
# split is what lets sub-project B replace the source with database-backed
# translations without touching rendering.
#
# Heading ids come from kramdown's auto_ids, which was measured against all
# four real manuals before this was written: it produces exactly the anchors
# the files were authored against, in both alphabets. See the design doc §2.1
# and spec/services/manual/renderer_spec.rb, which is the thing that would
# notice if that ever stopped being true.
module Manual
  class Renderer
    # hard_wrap is the option that matters. The GFM parser defaults it to true,
    # which renders every newline in the source as <br> -- and these files are
    # hard-wrapped prose, so the default produced 189 spurious breaks in en.md
    # alone and pinned every paragraph to its authoring width.
    OPTIONS = { :input => "GFM", :hard_wrap => false }.freeze

    def self.call(markdown)
      Kramdown::Document.new(markdown, OPTIONS).to_html
    end
  end
end
```

- [ ] **Step 5: Run it and watch it pass**

Run: `bundle exec rspec spec/services/manual/renderer_spec.rb`
Expected: 18 examples, 0 failures (1 file-list example + 4 per file × 4 files +
1 Cyrillic example).

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock app/services/manual/renderer.rb spec/services/manual/renderer_spec.rb
git commit -m "Render the manual's markdown, and pin its anchors to a test

kramdown's auto_ids already produce the GitHub anchors these files were
written against, including the Cyrillic ones -- measured across all four
before choosing it. The spec renders the shipped manuals rather than a
fixture because the failure it guards is invisible: a heading whose id no
longer matches the link pointing at it still renders, still looks like a
link, and scrolls nowhere.

hard_wrap: false is load-bearing. The GFM parser defaults it to true and
these manuals are hard-wrapped prose, so the default emitted 189 stray
<br> in en.md and froze every paragraph at its authoring width."
```

---

### Task 2: The link pass

Relative markdown links are correct in a repository and meaningless in a
browser. `](ru.md)` must become the app's own route so it goes through the
locale machinery; everything else that points at a `.md` file must go to
GitHub, which renders it.

**Files:**
- Modify: `app/services/manual/renderer.rb`
- Test: `spec/services/manual/renderer_spec.rb`

**Interfaces:**
- Consumes: `Manual::Renderer.call(markdown) -> String` from Task 1.
- Produces: the same signature, now with links rewritten. Task 4 depends on
  `manual_path` existing — it does not yet, so this task uses the literal path
  and Task 4's request spec proves the two agree.

- [ ] **Step 1: Write the failing test**

Append to `spec/services/manual/renderer_spec.rb`, inside `describe Manual::Renderer do`:

```ruby
  describe "the link pass" do
    def hrefs(markdown)
      Nokogiri::HTML5.fragment(Manual::Renderer.call(markdown))
        .css("a[href]").map { |a| a["href"] }
    end

    it "sends the other language's manual through the app's own locale switch" do
      expect(hrefs("Russian version: [ru.md](ru.md).")).to eq(["/manual?locale=ru"])
    end

    it "keeps a fragment when switching language" do
      expect(hrefs("[en](en.md#for-players)")).to eq(["/manual?locale=en#for-players"])
    end

    # The deployment guide has no route: its readers do not have a running
    # instance to read it on. GitHub renders it, with the anchors it was
    # written against.
    it "sends the deployment guide to GitHub, fragment intact" do
      expect(hrefs("[install](deployment.ru.md#6-первый-администратор)")).to eq(
        ["https://github.com/mezinster/encounter-engine/blob/master/docs/manual/deployment.ru.md#6-первый-администратор"]
      )
    end

    it "resolves a link that climbs out of docs/manual" do
      expect(hrefs("[restore](../runbooks/restore.md)")).to eq(
        ["https://github.com/mezinster/encounter-engine/blob/master/docs/runbooks/restore.md"]
      )
    end

    it "leaves in-page anchors and absolute URLs alone" do
      expect(hrefs("[a](#игроку) and [b](https://game.mezin.eu/)"))
        .to eq(["#игроку", "https://game.mezin.eu/"])
    end

    it "leaves no relative .md link anywhere in the shipped manuals" do
      MANUAL_FILES.each do |path|
        relative = hrefs(path.read).reject do |href|
          href.start_with?("http://", "https://", "#", "mailto:")
        end

        expect(relative.grep(/\.md(#|\z)/)).to eq([]), "#{path.basename} still has a raw .md link"
      end
    end
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/services/manual/renderer_spec.rb -e "the link pass"`
Expected: FAIL — the first example gets `["ru.md"]` instead of
`["/manual?locale=ru"]`.

- [ ] **Step 3: Write the implementation**

Replace the body of `app/services/manual/renderer.rb`'s class with:

```ruby
    OPTIONS = { :input => "GFM", :hard_wrap => false }.freeze

    # Where a relative .md link points once it is on the web. Pinned to master
    # rather than to the running commit: a reader following a link out of the
    # manual wants the current document, and this app has no way to know which
    # commit built it.
    GITHUB_BLOB = "https://github.com/mezinster/encounter-engine/blob/master/".freeze

    # The directory the manuals live in, which is what a relative link is
    # relative TO. Not Rails.root: this resolves link text, not files on disk.
    DOCUMENT_ROOT = "docs/manual".freeze

    # The two documents this app serves itself. Everything else goes to GitHub.
    IN_APP = { "ru.md" => :ru, "en.md" => :en }.freeze

    def self.call(markdown)
      document = Nokogiri::HTML5.fragment(
        Kramdown::Document.new(markdown, OPTIONS).to_html
      )
      rewrite_links(document)
      document.to_html
    end

    # Relative markdown links are correct in a repository and meaningless in a
    # browser. ru.md/en.md become the app's own route WITH ?locale=, so that
    # following one goes through LocaleSelection and is remembered in the
    # session -- exactly as if the header switcher had been used. Anything else
    # ending in .md is resolved against docs/manual and handed to GitHub.
    def self.rewrite_links(document)
      document.css("a[href]").each do |anchor|
        href = anchor["href"]
        next if href.start_with?("#", "http://", "https://", "mailto:")

        path, fragment = href.split("#", 2)
        suffix = fragment ? "##{fragment}" : ""

        if (locale = IN_APP[path])
          anchor["href"] =
            "#{Rails.application.routes.url_helpers.manual_path(:locale => locale)}#{suffix}"
        elsif path.end_with?(".md")
          resolved = Pathname.new(DOCUMENT_ROOT).join(path).cleanpath
          anchor["href"] = "#{GITHUB_BLOB}#{resolved}#{suffix}"
        end
      end
    end
    private_class_method :rewrite_links
```

- [ ] **Step 4: Add the route this now depends on**

`manual_path` does not exist yet, so the link pass raises
`NoMethodError: undefined method 'manual_path'`. Add the route now — Task 4
adds the controller that answers it.

In `config/routes.rb`, immediately after the `root to: "index#index"` line:

```ruby
  # The user manual, rendered from docs/manual/*.md at request time. Public on
  # purpose: its first section is "signing up and signing in", written for
  # someone who has done neither. See app/services/manual/source.rb.
  get "/manual" => "manual#show", as: :manual
```

- [ ] **Step 5: Run it and watch it pass**

Run: `bundle exec rspec spec/services/manual/renderer_spec.rb`
Expected: 24 examples, 0 failures (18 from Task 1, 6 from the link pass).

- [ ] **Step 6: Commit**

```bash
git add app/services/manual/renderer.rb spec/services/manual/renderer_spec.rb config/routes.rb
git commit -m "Rewrite the manual's relative links for the web

](ru.md) becomes /manual?locale=ru rather than a bare path, so following
it goes through LocaleSelection and is remembered in the session -- the
same thing the header switcher does. Every other .md link resolves
against docs/manual and points at GitHub, which renders those files with
the anchors they were written against; the deployment guide has no route
here because its readers have no running instance to read it on.

The last example holds the general rule: no relative .md link survives
the pass in any shipped manual."
```

---

### Task 3: `Manual::Source` — which document, and how stale

**Files:**
- Create: `app/services/manual/source.rb`
- Test: `spec/services/manual/source_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Manual::Source.for(locale) -> Manual::Source::Document`
  - `Manual::Source::Document` — a `Struct` with `#markdown` (String),
    `#locale_used` (Symbol), `#digest` (String, SHA256 hex)
  - `Manual::Source::Missing < StandardError`
  Task 4 calls `.for` and reads all three members.

- [ ] **Step 1: Write the failing test**

Create `spec/services/manual/source_spec.rb`:

```ruby
require "rails_helper"

describe Manual::Source do
  it "serves the Russian manual for ru" do
    document = described_class.for(:ru)

    expect(document.locale_used).to eq(:ru)
    expect(document.markdown).to include("# Руководство пользователя")
  end

  it "serves the English manual for en" do
    document = described_class.for(:en)

    expect(document.locale_used).to eq(:en)
    expect(document.markdown).to include("# User manual")
  end

  # Until sub-project B lands, five of the seven registered locales have no
  # manual. Falling back is fine; pretending it did not happen is not, which
  # is what locale_used is for -- the view renders a note when it differs.
  it "falls back to Russian for a locale with no manual, and says so" do
    document = described_class.for(:pl)

    expect(document.locale_used).to eq(:ru)
    expect(document.markdown).to include("# Руководство пользователя")
  end

  it "accepts a string locale" do
    expect(described_class.for("en").locale_used).to eq(:en)
  end

  it "digests the content it returns" do
    document = described_class.for(:ru)

    expect(document.digest)
      .to eq(Digest::SHA256.hexdigest(Rails.root.join("docs/manual/ru.md").read))
  end

  it "gives the same digest to two locales served by the same file" do
    expect(described_class.for(:pl).digest).to eq(described_class.for(:ru).digest)
  end

  # .dockerignore excludes docs/ wholesale, so an image built without the
  # re-include of Task 6 has no manual in it at all -- and every spec in this
  # repository would still pass, because they all run from a checkout. Fail
  # loudly and name the cause rather than returning nil for someone to
  # NoMethodError on three frames later.
  it "raises with the reason when the directory is not there" do
    Dir.mktmpdir do |empty|
      stub_const("Manual::Source::DIRECTORY", Pathname.new(empty))

      expect { described_class.for(:ru) }
        .to raise_error(Manual::Source::Missing, /dockerignore/)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/services/manual/source_spec.rb`
Expected: `NameError: uninitialized constant Manual::Source`.

- [ ] **Step 3: Write the implementation**

Create `app/services/manual/source.rb`:

```ruby
# app/services/manual/source.rb
#
# WHICH manual document a reader gets, and what it hashes to.
#
# This is the seam sub-project B replaces. Today it answers from the files that
# ship in the image; when superadmin-run translation lands, it will look for an
# approved translation row first and fall through to here. Nothing above it --
# controller, cache, renderer, view -- knows the difference, which is the whole
# reason it exists as its own object rather than two lines in the controller.
#
# locale_used is not a detail. Five of the seven registered locales have no
# manual, and a reader who asked for Polish and got Russian is entitled to be
# told that happened rather than left to conclude the site is broken.
require "digest"

module Manual
  class Source
    DIRECTORY = Rails.root.join("docs/manual")
    FALLBACK_LOCALE = :ru

    Document = Struct.new(:markdown, :locale_used, :digest, :keyword_init => true)

    class Missing < StandardError; end

    def self.for(locale)
      locale_used = available?(locale) ? locale.to_sym : FALLBACK_LOCALE
      path = path_for(locale_used)

      unless path.exist?
        raise Missing, <<~MESSAGE
          No manual at #{path}.

          In a container this means docs/manual was not copied into the image:
          .dockerignore excludes docs, and the `!docs/manual` re-include is what
          puts it back. See the design doc, §6.
        MESSAGE
      end

      markdown = path.read
      Document.new(
        :markdown => markdown,
        :locale_used => locale_used,
        :digest => Digest::SHA256.hexdigest(markdown)
      )
    end

    def self.available?(locale)
      path_for(locale).exist?
    end

    def self.path_for(locale)
      DIRECTORY.join("#{locale}.md")
    end
    private_class_method :path_for
  end
end
```

- [ ] **Step 4: Run it and watch it pass**

Run: `bundle exec rspec spec/services/manual/source_spec.rb`
Expected: 7 examples, 0 failures.

If `Dir.mktmpdir` raises `NameError`, add `require "tmpdir"` at the top of the
spec — `rails_helper` does not pull it in on its own.

- [ ] **Step 5: Commit**

```bash
git add app/services/manual/source.rb spec/services/manual/source_spec.rb
git commit -m "Resolve which manual a locale gets, and report the fallback

Five of the seven registered locales have no manual until sub-project B
lands. Falling back to Russian is right; hiding it is not, so the
document carries locale_used and the view renders a note when it differs
from what was asked for.

This object is the seam B replaces -- it will consult an approved
translation before it consults the file, and nothing above it changes.

A missing directory raises and names .dockerignore as the cause, because
that is the only way it happens in practice: every spec here runs from a
checkout where these files exist, so no test can catch an image built
without them."
```

---

### Task 4: The page — route, controller, view, cache, menu, seven locales

**Files:**
- Create: `app/controllers/manual_controller.rb`
- Create: `app/views/manual/show.html.erb`
- Modify: `app/views/layouts/_left_menu.html.erb`
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`
- Test: `spec/requests/manual_spec.rb`
- (`config/routes.rb` already has the route, added in Task 2)

**Interfaces:**
- Consumes: `Manual::Source.for(locale) -> Document` (Task 3),
  `Manual::Renderer.call(markdown) -> String` (Tasks 1–2), `manual_path`.
- Produces: `GET /manual`; the `.manual` wrapper element that Task 5 styles and
  measures.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/manual_spec.rb`:

```ruby
require "rails_helper"

describe "the manual", type: :request do
  it "serves the Russian manual to a signed-out visitor" do
    get manual_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Руководство пользователя")
  end

  it "serves the English manual when the locale is en" do
    get manual_path(:locale => :en)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("User manual")
  end

  it "renders the markdown rather than echoing it" do
    get manual_path

    expect(response.body).to include("<table>")
    expect(response.body).not_to include("|---|")
  end

  # The literal Polish, not I18n.t: an assertion written as
  # include(I18n.t(key)) resolves the same way the view does and therefore
  # cannot fail on a missing or wrong key.
  it "tells a Polish reader that this is the Russian version" do
    get manual_path(:locale => :pl)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Podręcznik nie został jeszcze przetłumaczony")
    expect(response.body).to include("Руководство пользователя")
  end

  it "shows no fallback note when the manual is in the reader's language" do
    get manual_path(:locale => :en)

    expect(response.body).not_to include("not yet available in your language")
  end

  it "is linked from the left menu signed out" do
    get root_path

    expect(response.body).to include(%(href="/manual"))
  end

  it "is linked from the left menu signed in" do
    user = create_user
    put login_path, :params => { :email => user.email, :password => "1234" }

    get dashboard_path

    expect(response.body).to include(%(href="/manual"))
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bundle exec rspec spec/requests/manual_spec.rb`
Expected: FAIL — `ActionController::RoutingError` / `uninitialized constant
ManualController` on every example.

- [ ] **Step 3: Write the controller**

Create `app/controllers/manual_controller.rb`:

```ruby
# -*- encoding : utf-8 -*-
class ManualController < ApplicationController
  # No authentication guard, deliberately: the manual's first section is
  # "signing up and signing in".
  #
  # The cache key is the file's DIGEST, not a constant and not the locale
  # alone. Rails.cache is :memory_store here, so this costs one render per
  # document per container lifetime; keying on the digest means editing a
  # manual in development invalidates it without a restart, and two locales
  # served by the same fallback file share one entry.
  def show
    document = Manual::Source.for(I18n.locale)

    @locale_used = document.locale_used
    @manual_html = Rails.cache.fetch(["manual", document.locale_used, document.digest]) do
      Manual::Renderer.call(document.markdown)
    end
  end
end
```

- [ ] **Step 4: Write the view**

Create `app/views/manual/show.html.erb`:

```erb
<%# The rendered manual is trusted: it is markdown from this repository,
    reviewed in a pull request and shipped in the image, so it goes out with
    raw. Sub-project B changes that -- a translation produced by the Claude API
    and stored in the database is not the same trust class, and the html_safe
    decision has to be revisited there rather than inherited from here. %>
<div class="manual">
  <% if @locale_used.to_s != I18n.locale.to_s %>
    <p class="flash flash--notice">
      <%= t("manual.fallback_note", :language => t("locales.#{@locale_used}")) %>
    </p>
  <% end %>

  <%= raw @manual_html %>
</div>
```

- [ ] **Step 5: Add the menu links**

In `app/views/layouts/_left_menu.html.erb`, in the **signed-in** branch, add an
`<li>` immediately before the logout `<li>`:

```erb
    <li>
      <%= link_to t("layout.left_menu.manual"), manual_path %>
    </li>
```

and in the **signed-out** branch, immediately after the `teams_path` `<li>`,
add the identical block:

```erb
    <li>
      <%= link_to t("layout.left_menu.manual"), manual_path %>
    </li>
```

- [ ] **Step 6: Add the two keys to all seven locale files**

In each `config/locales/<locale>.yml`, add `manual:` to the existing
`layout.left_menu` block, and a new top-level `manual:` block immediately
before the top-level `shared:` key. Confirm that anchor exists first:

```bash
for f in config/locales/{ru,en,uk,ka,tr,be,pl}.yml; do
  printf "%s: " "$f"; grep -c '^  shared:' "$f"
done
```
Expected: `1` for each. If any file prints `0`, put the block at the end of
that file's top level instead, keeping two-space indentation.

| locale | `layout.left_menu.manual` | `manual.fallback_note` |
|---|---|---|
| `ru` | `"Руководство"` | `"Руководство пока не переведено на ваш язык — показана версия на языке «%{language}»."` |
| `en` | `"Manual"` | `"The manual is not yet available in your language — showing the version in %{language}."` |
| `uk` | `"Посібник"` | `"Посібник ще не перекладено вашою мовою — показано версію мовою «%{language}»."` |
| `be` | `"Дапаможнік"` | `"Дапаможнік яшчэ не перакладзены на вашу мову — паказана версія на мове «%{language}»."` |
| `pl` | `"Podręcznik"` | `"Podręcznik nie został jeszcze przetłumaczony na Twój język — pokazano wersję w języku %{language}."` |
| `tr` | `"Kılavuz"` | `"Kılavuz henüz sizin dilinize çevrilmedi — «%{language}» dilindeki sürüm gösteriliyor."` |
| `ka` | `"სახელმძღვანელო"` | `"სახელმძღვანელო ჯერ არ არის თარგმნილი თქვენს ენაზე — ნაჩვენებია ვერსია «%{language}» ენაზე."` |

The Turkish and Georgian strings put the case suffix on the common noun for
"language" (`dil`, `ენა`) rather than on `%{language}` itself — the rule
CLAUDE.md records for every key carrying an interpolated name, because a suffix
cannot attach to a value the template cannot inflect.

The YAML shape, using `ru.yml` as the example:

```yaml
    left_menu:
      administration: "Администрирование"
      ...
      manual: "Руководство"
      logout: "Выйти"
  manual:
    fallback_note: "Руководство пока не переведено на ваш язык — показана версия на языке «%{language}»."
  shared:
```

- [ ] **Step 7: Run the request spec and the i18n spec**

Run: `bundle exec rspec spec/requests/manual_spec.rb spec/i18n_spec.rb`
Expected: 7 request examples + the i18n examples, 0 failures. A failure in
`spec/i18n_spec.rb` about `ru`↔`en` key parity means one of the two files
missed a key.

- [ ] **Step 8: Run the whole RSpec suite**

Run: `bundle exec rspec`
Expected: 0 failures. The count moves up by the 38 examples this branch has
added so far (24 renderer, 7 source, 7 request); do not quote a total from CLAUDE.md — it has been stale eight
times. Record what this run actually prints.

- [ ] **Step 9: Prove the frozen acceptance suite is untouched**

The menu change alters the rendered body of every page in the suite, so this
is not optional. **Run this yourself; do not delegate it to a subagent.**

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```
Expected, exactly: **228 scenarios (226 passed, 2 undefined), 2325 steps**.
Any other number is a stop-and-report, not a thing to fix by editing a feature.

Then the whole suite: `bundle exec cucumber` — expected 238 scenarios / 2386
steps, unchanged, since this branch adds no feature file.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/manual_controller.rb app/views/manual/show.html.erb \
        app/views/layouts/_left_menu.html.erb config/locales/*.yml \
        spec/requests/manual_spec.rb
git commit -m "Serve the manual at /manual, in the reader's language

Public, and linked from both branches of the left menu: the manual opens
with how to sign up, which is not something a signed-in reader needs.

The locale comes from the app's own picker, so a language chosen in the
header carries into the manual and a link inside the manual carries back
out. Five locales have no manual yet and fall back to Russian with a note
that says so -- the alternative is a reader concluding the site is broken.

Cached on the file's digest rather than its name, so a manual edited in
development invalidates without a restart and two locales sharing a
fallback file share one entry."
```

---

### Task 5: The tables, on a phone

Six tables, 41 rendered rows, markdown lines up to 135 characters, on a 390px
screen. Neither existing suite can see this: Capybara parses no
stylesheet and a request spec sees markup only.

**Files:**
- Modify: `public/stylesheets/screens.css`
- Test: `spec/layout/manual_layout_spec.rb`

**Interfaces:**
- Consumes: `GET /manual` returning a page with a `.manual` wrapper (Task 4).
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the failing test**

Create `spec/layout/manual_layout_spec.rb`:

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# The manual is the widest content this app renders: six tables, three columns,
# rows up to 135 characters, on a 390px phone. Neither suite can see it --
# Capybara's rack_test driver parses no stylesheet and a request spec sees
# markup only -- which is the same blind spot that let a play screen ship with
# its submit button below the fold.
#
# The property asserted here survives a redesign: whatever the tables look
# like, the PAGE must not be the thing that scrolls sideways.
describe "the manual, measured", :layout, type: :request do
  include LayoutMeasurement

  let(:page_html) do
    get manual_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  MANUAL_PROBE = <<~JS
    var tables = Array.prototype.slice.call(document.querySelectorAll(".manual table"));
    var RESULT = {
      tables: tables.length,
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      // A table that scrolls inside itself is the point; one that does not
      // overflow at all at this width would mean the measurement found no
      // real content.
      scrollableTables: tables.filter(function (t) {
        return t.scrollWidth > t.clientWidth;
      }).length,
      widestTableWithinPage: tables.every(function (t) {
        return t.getBoundingClientRect().width <= document.documentElement.clientWidth;
      })
    };
  JS

  it "never scrolls the page sideways on a phone" do
    result = measure(page_html, 390, 660, MANUAL_PROBE, :tmp_name => "manual-390.html")

    expect(result["tables"]).to eq(6)
    expect(result["hOverflow"]).to eq(0)
    expect(result["widestTableWithinPage"]).to be(true)
    expect(result["scrollableTables"]).to be > 0
  end

  it "never scrolls the page sideways on a narrow phone" do
    result = measure(page_html, 375, 553, MANUAL_PROBE, :tmp_name => "manual-375.html")

    expect(result["hOverflow"]).to eq(0)
  end

  it "still fits on a desktop" do
    result = measure(page_html, 1280, 800, MANUAL_PROBE, :tmp_name => "manual-1280.html")

    expect(result["hOverflow"]).to eq(0)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/manual_layout_spec.rb`
Expected: FAIL on the 390px example — `hOverflow` is a positive number, because
an unstyled `<table>` pushes the document wider than the viewport.

If it fails instead with "No chrome-headless-shell found", install it with
`npx playwright install chromium` and re-run. Do **not** convert the example to
a skip; a measurement that quietly did not happen reports as a pass.

- [ ] **Step 3: Write the CSS**

Append to `public/stylesheets/screens.css`:

```css
/* --- The manual: one long markdown document ------------------------------
   Authored as markdown, so the widest element on the page is a table nobody
   sized for a phone: six of them, three columns, some rows 135 characters of
   source wide.
   `display: block` is what makes overflow-x apply to a <table> at all -- the
   table becomes its own scrollport, so the TABLE scrolls sideways and the page
   never does. spec/layout/manual_layout_spec.rb asserts exactly that. */
.manual table {
  display: block;
  overflow-x: auto;
  max-width: 100%;
}

/* Same reasoning for code blocks: the deployment guide has 16 of them and some
   lines are long. */
.manual pre {
  overflow-x: auto;
  max-width: 100%;
}

/* A measure, not a width: unbroken prose across 1280px is unreadable, and
   nothing else on this page constrains it. */
.manual {
  max-width: 70ch;
}
```

- [ ] **Step 4: Run it and watch it pass**

Run: `LAYOUT_SPECS=1 bundle exec rspec spec/layout/manual_layout_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 5: Mutation-test the guard**

A layout spec that cannot fail is worse than none. Temporarily delete the
`display: block;` line from `.manual table`, re-run, and confirm the 390px
example fails on `hOverflow`. Put it back and confirm green again. Record both
outcomes in the commit message.

- [ ] **Step 6: Commit**

```bash
git add public/stylesheets/screens.css spec/layout/manual_layout_spec.rb
git commit -m "Make the manual's tables scroll instead of the page

Six tables, three columns, rows up to 135 characters, on a 390px phone.
display:block is what makes overflow-x apply to a <table>, so each table
becomes its own scrollport and the page itself never scrolls sideways.

Measured rather than assumed: neither suite can see this: rack_test
parses no stylesheet and a request spec sees markup only. Mutation-tested
by removing display:block, which takes the 390px example red on
hOverflow."
```

---

### Task 6: Put the manual in the image, and prove it is there

Everything so far passes against an image with no manual in it, because every
spec runs from a checkout. This task closes that.

**Files:**
- Modify: `.dockerignore`
- Modify: `.github/workflows/images.yml`

**Interfaces:**
- Consumes: `GET /manual` (Task 4).
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Re-include the manual**

In `.dockerignore`, replace the single line `docs` with:

```
# docs/ is excluded wholesale -- security findings and design specs have no
# business in a running container -- EXCEPT the manual, which the app serves
# at /manual and therefore has to be able to read at runtime. See
# app/services/manual/source.rb, which raises pointing back at this file.
docs
!docs/manual
```

- [ ] **Step 2: Add the proof to the image job**

In `.github/workflows/images.yml`, in the `app-image` job, immediately after
the `Prove the image actually serves` step and before
`Prove libvips is in the image, with HEIC support`:

```yaml
      # The one check in this repository capable of noticing that docs/manual
      # is missing from the image. Every spec runs from a checkout, where these
      # files always exist, so the whole suite stays green against an image
      # that 404s -- the same seam that made the libvips package name look
      # correct for months. The container from the previous step is still
      # running as ee-smoke on the host network.
      - name: Prove the manual is in the image and renders
        run: |
          code=$(curl -s -o /tmp/manual.html -w "%{http_code}" http://127.0.0.1:3000/manual)
          if [ "$code" != "200" ]; then
            echo "FAILED: /manual returned $code"
            docker logs ee-smoke | tail -40
            exit 1
          fi
          grep -q "Руководство пользователя" /tmp/manual.html || {
            echo "FAILED: /manual answered 200 without the manual's own heading in it"
            head -60 /tmp/manual.html
            exit 1
          }
          grep -q "<table>" /tmp/manual.html || {
            echo "FAILED: /manual rendered without tables -- the GFM parser is not active"
            exit 1
          }
          echo "manual ok"
```

- [ ] **Step 3: Verify it — in CI, because there is no local docker**

There is no docker daemon on this machine (`docker version` fails on
`/var/run/docker.sock`), so the `.dockerignore` re-include **cannot be checked
locally**. It is not a formality: `.gitignore` would not re-include a
subdirectory of an excluded directory this way, and Docker's matcher is a
different implementation.

Push the branch and watch the `Images / app-image` job:

```bash
git push -u origin design/manual-on-the-web
gh run watch $(gh run list --workflow=images.yml --branch=design/manual-on-the-web \
  --limit 1 --json databaseId -q '.[0].databaseId')
```
Expected: the new step prints `manual ok`.

If it fails with a 500 whose log names `Manual::Source::Missing`, the
re-include did not take. Replace the two lines with an explicit list of the
subdirectories to exclude, which needs no re-inclusion semantics at all:

```
docs/handoff
docs/perf
docs/runbooks
docs/security
docs/superpowers
```

and re-run. Note in the commit message which of the two forms was proven.

- [ ] **Step 4: Commit**

```bash
git add .dockerignore .github/workflows/images.yml
git commit -m "Ship docs/manual in the image, and prove it in CI

.dockerignore excluded docs wholesale, so /manual would have 404'd in
production with every test green: specs run from a checkout, where the
files always exist. The re-include puts the manual back and leaves the
security register and the design specs out.

The assertion in the app-image job is the only check in this repository
that can fail if this line is ever reverted, which is why it asserts on
the rendered heading and a <table> rather than on a 200."
```

---

## Definition of done

- [ ] `bundle exec rspec` — 0 failures; record the count this run prints rather
      than quoting one.
- [ ] `LAYOUT_SPECS=1 bundle exec rspec spec/layout` — 0 failures.
- [ ] Inherited Cucumber set — **228 scenarios (226 passed, 2 undefined) / 2325
      steps**, unchanged.
- [ ] Full Cucumber — 238 scenarios / 2386 steps, unchanged.
- [ ] `Images / app-image` green, with `manual ok` in the log.
- [ ] No `.feature` file modified: `git diff --stat master...HEAD -- features/`
      prints nothing.
- [ ] `/manual` read on a phone-width window in a real browser, once, by a
      human — the specs assert overflow, not legibility.

## Deliberately not in this plan

Everything §1.2 of the spec lists as a non-goal, and in particular: no
translation of the manual, no table of contents or sidebar, no search, no
per-section pages, no GitHub Pages. Sub-project B is designed separately, and
its first task is the anchor-integrity check of Task 1 applied to a proposed
translation before it can be approved.
