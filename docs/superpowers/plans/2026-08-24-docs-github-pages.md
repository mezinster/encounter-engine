# Docs on GitHub Pages — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish thirteen existing markdown files from `docs/` as a static site at `https://mezinster.github.io/encounter-engine/`, built by GitHub Actions, without changing a single byte of the source files or anything under `app/`.

**Architecture:** A pure-Ruby stager (`DocsSite::Stager`) copies an allowlisted subset of `docs/` into `docs-site/build/`, preserving relative paths so existing links resolve untouched; it injects a visible machine-translation banner into the five manuals whose first line declares one, and refuses to run if any relative `.md` link points outside the staged set. MkDocs Material then builds that directory. A workflow builds on pull requests and builds-and-deploys on master.

**Tech Stack:** Ruby 3.3.12 (stager + RSpec, no Rails), Python 3.12 + MkDocs 1.6 + mkdocs-material (build only, CI-side), GitHub Actions, GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-08-24-docs-github-pages-design.md`

## Global Constraints

- **No file under `docs/manual/`, `docs/runbooks/`, or `docs/perf/` may be modified.** They are application content shipped inside the Docker image and rendered at request time by `ManualController`. The stager reads them and writes elsewhere.
- **No file under `app/`, `config/`, or `features/` is touched.** This is a standalone mirror (spec §3).
- **Ruby is not on `PATH` in non-login shells.** Every command below assumes `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` has been run.
- **Use an isolated test database** when running RSpec, to avoid colliding with a parallel session: `export DATABASE_URL="sqlite3:/tmp/claude-1000/-home-mezinster-encounter-engine/bc0c1da5-2090-47f2-b448-4fb17686073d/scratchpad/pages-test.sqlite3"`. (The stager specs need no database, but `spec_helper` is loaded either way.)
- **Hash rockets (`:key => value`) are the house style** in older files; new standalone Ruby files in this repo (`ops/vmscale/policy.rb`) use modern syntax. Match `ops/vmscale/policy.rb`: `frozen_string_literal`, keyword args, modern hash syntax.
- **Actions must be SHA-pinned with a `# vN` trailing comment**, matching `.github/workflows/ci.yml`.
- **MkDocs pins:** `mkdocs==1.6.1`, `mkdocs-material==9.5.44`. `validation.anchors` requires MkDocs **≥ 1.6**.
- The published set is exactly: `manual/{ru,en,uk,be,pl,tr,ka}.md`, `manual/deployment.{ru,en}.md`, `manual/performance.{ru,en}.md`, `runbooks/restore.md`, `perf/README.md`.

---

### Task 1: The stager copies the allowlist and nothing else

**Files:**
- Create: `docs-site/stager.rb`
- Test: `spec/docs_site/stager_spec.rb`
- Create: `spec/fixtures/docs_site/` (fixture tree, described in Step 1)

**Interfaces:**
- Produces: `DocsSite::Stager.new(docs_root:, out_root:)` with `#call → Array<String>` (staged paths relative to `out_root`, sorted) and `#sources → Array<String>`. Later tasks add `ClosureError` and banner behaviour to this same class.

- [ ] **Step 1: Build the fixture tree**

The specs never read the real `docs/` — see spec §5.2. Create this tree by hand:

```bash
mkdir -p spec/fixtures/docs_site/manual spec/fixtures/docs_site/runbooks \
         spec/fixtures/docs_site/perf spec/fixtures/docs_site/secret
```

`spec/fixtures/docs_site/manual/ru.md`:
```markdown
# Руководство

Смотри [английскую версию](en.md) и [восстановление](../runbooks/restore.md).

## 6. Первый администратор

Ссылка внутрь страницы: [сюда](#6-первый-администратор).
```

`spec/fixtures/docs_site/manual/en.md`:
```markdown
# Manual

See [the Russian version](ru.md) and [performance](../perf/README.md).
```

`spec/fixtures/docs_site/manual/uk.md`:
```markdown
<!-- Machine-translated from ru.md on 2026-08-22. Not reviewed by a native speaker. -->
# Посібник

Дивись [англійську версію](en.md).
```

`spec/fixtures/docs_site/runbooks/restore.md`:
```markdown
# Restoring

No relative links here.
```

`spec/fixtures/docs_site/perf/README.md`:
```markdown
# Performance records

Back to [the guide](../manual/en.md).
```

`spec/fixtures/docs_site/secret/findings.md`:
```markdown
# Findings

This file must never be staged.
```

- [ ] **Step 2: Write the failing test**

Create `spec/docs_site/stager_spec.rb`:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../docs-site/stager"

RSpec.describe DocsSite::Stager do
  # The fixture tree stands in for docs/. Running against the real docs/ would
  # mean an ordinary edit to a manual could redden the default rspec run --
  # the exact failure CLAUDE.md records against renderer_spec.rb's file list.
  FIXTURE_DOCS = File.expand_path("../fixtures/docs_site", __dir__)

  # Every example gets its own output directory and removes it afterwards.
  def stage(docs_root: FIXTURE_DOCS)
    Dir.mktmpdir("docs-site-spec") do |out|
      yield described_class.new(:docs_root => docs_root, :out_root => out), out
    end
  end

  describe "the allowlist" do
    it "stages every manual, plus the two named extras" do
      stage do |stager, _out|
        expect(stager.call).to eq(
          [
            "manual/en.md",
            "manual/ru.md",
            "manual/uk.md",
            "perf/README.md",
            "runbooks/restore.md"
          ]
        )
      end
    end

    it "does not stage a file outside the allowlist" do
      stage do |stager, out|
        stager.call
        expect(File.exist?(File.join(out, "secret/findings.md"))).to be false
      end
    end

    it "preserves each file's path relative to docs/, which is what keeps links working" do
      stage do |stager, out|
        stager.call
        expect(File.exist?(File.join(out, "manual/ru.md"))).to be true
        expect(File.exist?(File.join(out, "runbooks/restore.md"))).to be true
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/docs_site/stager_spec.rb
```

Expected: FAIL — `cannot load such file -- .../docs-site/stager`.

- [ ] **Step 4: Write the minimal implementation**

Create `docs-site/stager.rb`:

```ruby
# frozen_string_literal: true

# Stages the publishable subset of docs/ into a directory MkDocs can build.
#
# Pure Ruby, no Rails, no network -- the same shape as ops/vmscale/policy.rb,
# and for the same reason: a function from a tree of files to a tree of files
# is testable from fixtures, and bin/stage-docs-site is the only thing with
# side effects on the real repository.
#
# The one rule this file exists to enforce is that docs/ is NOT publishable
# wholesale. docs/superpowers/ and docs/security/ stay unpublished, and the
# check in #assert_closed is what stops a link from quietly dragging one of
# them onto the public web.
require "fileutils"

module DocsSite
  class Stager
    # docs/manual is already the vetted-public directory: it is the one part of
    # docs/ that .dockerignore re-includes into the shipped image. So a glob is
    # safe here, and a new translation publishes itself the day it lands.
    MANUAL_GLOB = "manual/*.md"

    # Everything else is named one file at a time, so that widening the
    # published set is a visible diff line rather than a side effect.
    EXTRA_FILES = %w[runbooks/restore.md perf/README.md].freeze

    def initialize(docs_root:, out_root:)
      @docs_root = File.expand_path(docs_root)
      @out_root = File.expand_path(out_root)
    end

    # Relative paths of everything that will be published, sorted.
    def sources
      (Dir.glob(MANUAL_GLOB, :base => @docs_root) + EXTRA_FILES).uniq.sort
    end

    def call
      FileUtils.rm_rf(@out_root)
      sources.each { |relative_path| stage(relative_path) }
      sources
    end

    private

    def stage(relative_path)
      destination = File.join(@out_root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, File.read(File.join(@docs_root, relative_path)))
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rspec spec/docs_site/stager_spec.rb
```

Expected: PASS, 3 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add docs-site/stager.rb spec/docs_site/stager_spec.rb spec/fixtures/docs_site
git commit -m "Stage an allowlisted subset of docs/ for publication"
```

---

### Task 2: The machine-translation banner becomes visible

**Files:**
- Modify: `docs-site/stager.rb`
- Test: `spec/docs_site/stager_spec.rb`

**Interfaces:**
- Consumes: `DocsSite::Stager#call` from Task 1.
- Produces: `DocsSite::Stager::MissingBannerError`, raised when a file declares a machine translation for a locale with no banner text. `BANNERS` is a `Hash<String, Array(String, String)>` keyed by locale, holding `[title, body_template]`.

**Why:** the five translated manuals declare their status in an HTML comment, which renders to *nothing*. On a public indexed site a Belarusian reader would have no way to know 52 KB of prose has never been read by a speaker of their language. See spec §4.7.

- [ ] **Step 1: Write the failing test**

Append inside the `RSpec.describe` block in `spec/docs_site/stager_spec.rb`:

```ruby
  describe "the machine-translation banner" do
    it "renders the invisible HTML comment as a visible admonition, in the page's own language" do
      stage do |stager, out|
        stager.call
        uk = File.read(File.join(out, "manual/uk.md"))

        expect(uk).to include('!!! warning "Машинний переклад"')
        expect(uk).to include("`ru.md`")
        expect(uk).to include("2026-08-22")
      end
    end

    it "puts the banner after the heading, so the page still has its title first" do
      stage do |stager, out|
        stager.call
        lines = File.read(File.join(out, "manual/uk.md")).lines.map(&:chomp)

        expect(lines[0]).to start_with("<!--")
        expect(lines[1]).to eq("# Посібник")
        expect(lines[3]).to start_with("!!! warning")
      end
    end

    it "leaves a file without the comment byte-identical" do
      stage do |stager, out|
        stager.call

        expect(File.read(File.join(out, "manual/ru.md")))
          .to eq(File.read(File.join(FIXTURE_DOCS, "manual/ru.md")))
      end
    end

    it "refuses to publish a machine-translated locale it has no banner for" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.mkdir_p(File.join(src, "manual"))
        FileUtils.mkdir_p(File.join(src, "runbooks"))
        FileUtils.mkdir_p(File.join(src, "perf"))
        File.write(File.join(src, "runbooks/restore.md"), "# R\n")
        File.write(File.join(src, "perf/README.md"), "# P\n")
        File.write(
          File.join(src, "manual/zz.md"),
          "<!-- Machine-translated from ru.md on 2026-08-22. Not reviewed by a native speaker. -->\n# Z\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::MissingBannerError, /zz/)
        end
      end
    end
  end
```

Note the last example is why `stage` takes a `docs_root:` argument.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/docs_site/stager_spec.rb -e "machine-translation banner"
```

Expected: FAIL — the staged `uk.md` contains no `!!! warning`.

- [ ] **Step 3: Add the banner logic**

In `docs-site/stager.rb`, add above `def initialize`:

```ruby
    class MissingBannerError < StandardError; end

    # The uniform first line of every machine-translated manual. It names both
    # the source and the date, so the banner is derived rather than maintained:
    # a locale that gets reviewed by a human loses its banner by having this
    # comment deleted, in the same commit as the review.
    MT_COMMENT = /
      \A<!--\s*Machine-translated\ from\ (?<source>\S+)\ on\ (?<date>\d{4}-\d{2}-\d{2})\.
      \s*Not\ reviewed\ by\ a\ native\ speaker\.\s*-->
    /x

    # [title, body] per locale. These strings are themselves machine-produced,
    # which is self-consistent rather than ironic: they say so.
    #
    # The Turkish entry follows CLAUDE.md's rule for agglutinative languages --
    # the case suffix lands on "dosya" (file), never on the interpolated
    # filename, because which suffix is correct depends on the value's final
    # vowel.
    BANNERS = {
      "uk" => [
        "Машинний переклад",
        "Цю сторінку перекладено машинно з `%{source}` %{date}. Її не перевіряв носій мови."
      ],
      "be" => [
        "Машынны пераклад",
        "Гэтая старонка перакладзена машынна з `%{source}` %{date}. Яе не правяраў носьбіт мовы."
      ],
      "pl" => [
        "Tłumaczenie maszynowe",
        "Ta strona została przetłumaczona maszynowo z `%{source}` %{date}. Nie sprawdził jej native speaker."
      ],
      "tr" => [
        "Makine çevirisi",
        "Bu sayfa %{date} tarihinde `%{source}` dosyasından makineyle çevrildi. Ana dili konuşan biri tarafından kontrol edilmedi."
      ],
      "ka" => [
        "მანქანური თარგმანი",
        "ეს გვერდი მანქანურად ითარგმნა `%{source}`-დან %{date}. მშობლიური ენის მატარებელს არ შეუმოწმებია."
      ]
    }.freeze
```

Replace `#stage` with:

```ruby
    def stage(relative_path)
      destination = File.join(@out_root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, with_banner(relative_path, File.read(File.join(@docs_root, relative_path))))
    end

    # Additive and derived: files with no declaration pass through untouched,
    # and nothing on disk is modified.
    def with_banner(relative_path, markdown)
      declaration = MT_COMMENT.match(markdown)
      return markdown if declaration.nil?

      locale = File.basename(relative_path, ".md")
      title, body = BANNERS[locale]
      if title.nil?
        raise MissingBannerError,
              "#{relative_path} declares a machine translation but DocsSite::Stager::BANNERS " \
              "has no text for locale #{locale.inspect}. Add it rather than publishing an " \
              "unmarked machine translation."
      end

      admonition = format(
        "!!! warning \"%<title>s\"\n\n    %<body>s\n",
        :title => title,
        :body => body % { :source => declaration[:source], :date => declaration[:date] }
      )

      insert_after_heading(markdown, admonition)
    end

    # After the H1, so the page keeps its title as the first thing rendered.
    def insert_after_heading(markdown, admonition)
      lines = markdown.lines
      heading = lines.index { |line| line.start_with?("# ") }
      return "#{admonition}\n#{markdown}" if heading.nil?

      lines.insert(heading + 1, "\n#{admonition}").join
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/docs_site/stager_spec.rb
```

Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add docs-site/stager.rb spec/docs_site/stager_spec.rb
git commit -m "Render the machine-translation notice where readers can see it"
```

---

### Task 3: The closure check refuses to publish a link out of the set

**Files:**
- Modify: `docs-site/stager.rb`
- Test: `spec/docs_site/stager_spec.rb`

**Interfaces:**
- Consumes: `DocsSite::Stager#call` from Tasks 1–2.
- Produces: `DocsSite::Stager::ClosureError`, raised by `#call` after staging when any relative `.md` link resolves outside the staged set.

**Why:** spec §4.6. One check, two failure modes — a link *out* of the published set (someone references a security finding from a manual), and a link *broken* by a rename, which nothing currently catches for the files the app does not serve.

- [ ] **Step 1: Write the failing test**

Append inside the `RSpec.describe` block:

```ruby
  describe "the closure check" do
    it "accepts a set whose links all resolve inside it" do
      stage do |stager, _out|
        expect { stager.call }.not_to raise_error
      end
    end

    it "refuses a link pointing at a document that is not published" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.write(
          File.join(src, "manual/en.md"),
          File.read(File.join(src, "manual/en.md")) +
            "\nSee [the findings](../secret/findings.md).\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::ClosureError, %r{secret/findings\.md})
        end
      end
    end

    it "refuses a link broken by a rename" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        File.rename(File.join(src, "manual/en.md"), File.join(src, "manual/eng.md"))

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }
            .to raise_error(DocsSite::Stager::ClosureError, %r{en\.md})
        end
      end
    end

    it "ignores absolute links and bare anchors, which are not its business" do
      Dir.mktmpdir("docs-site-src") do |src|
        FileUtils.cp_r(File.join(FIXTURE_DOCS, "."), src)
        # The GitHub link is the load-bearing case: it ends in ".md" and starts
        # with a letter, so a check that only excluded ":" as a leading
        # character would report it as dangling and fail every real build.
        File.write(
          File.join(src, "manual/en.md"),
          "# Manual\n\n" \
          "[site](https://game.mezin.eu/) " \
          "[spec](https://github.com/mezinster/encounter-engine/blob/master/docs/security/x.md) " \
          "[top](#manual) [ru](ru.md)\n"
        )

        stage(:docs_root => src) do |stager, _out|
          expect { stager.call }.not_to raise_error
        end
      end
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/docs_site/stager_spec.rb -e "closure check"
```

Expected: FAIL — `ClosureError` is not defined; the "accepts" example errors on the missing constant too.

- [ ] **Step 3: Add the closure check**

In `docs-site/stager.rb`, add next to `MissingBannerError`:

```ruby
    class ClosureError < StandardError; end

    # A markdown link target, with any #fragment split off.
    #
    # The lookahead is doing real work: excluding ":" from a leading character
    # class is NOT enough, because "https://github.com/x/y/blob/master/z.md"
    # begins with "h" and ends in ".md", so it would sail through as a relative
    # link and be reported as dangling. Schemes and absolute paths are rejected
    # as a whole, up front.
    RELATIVE_LINK = %r{\]\(\s*(?!\w+://|/)(?<target>[^)\s#]+\.md)(?:\#[^)\s]*)?\s*\)}
```

Change `#call` to run the check after staging:

```ruby
    def call
      FileUtils.rm_rf(@out_root)
      sources.each { |relative_path| stage(relative_path) }
      assert_closed
      sources
    end
```

And add to the private section:

```ruby
    # Every relative .md link in the published set must resolve to something
    # else in the published set. Anything else is either a link onto a document
    # this repository deliberately does not publish, or a link broken by a
    # rename -- and the right response to both is a red build, not a quiet
    # widening of the allowlist.
    def assert_closed
      published = sources.to_set
      dangling = []

      sources.each do |relative_path|
        markdown = File.read(File.join(@docs_root, relative_path))

        # RELATIVE_LINK has exactly one capturing group, so scan yields
        # one-element arrays; destructuring reads more plainly than
        # Regexp.last_match inside a block.
        markdown.scan(RELATIVE_LINK).each do |(target)|
          # Resolved as an absolute path rooted at "/" so that "../" is
          # normalised by expand_path, then stripped back to a docs-relative
          # path for comparison. Doing this on real filesystem paths would
          # resolve against the machine instead of against the published set.
          resolved = File.expand_path(target, File.dirname("/#{relative_path}")).delete_prefix("/")
          dangling << "#{relative_path} -> #{target}" unless published.include?(resolved)
        end
      end

      return if dangling.empty?

      raise ClosureError,
            "these links leave the published set:\n  #{dangling.join("\n  ")}\n" \
            "Either the target belongs on the site (add it to EXTRA_FILES, deliberately), " \
            "or the link is wrong."
    end
```

Add `require "set"` next to `require "fileutils"` at the top of the file.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/docs_site/stager_spec.rb
```

Expected: PASS, 11 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add docs-site/stager.rb spec/docs_site/stager_spec.rb
git commit -m "Fail the build when a published page links out of the published set"
```

---

### Task 4: The executable, run against the real `docs/`

**Files:**
- Create: `bin/stage-docs-site`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `DocsSite::Stager` from Tasks 1–3.
- Produces: an executable that stages `docs/` into `docs-site/build/` and exits non-zero with a readable message on `ClosureError` or `MissingBannerError`.

This is the first task that runs against the thirteen real files. Its deliverable is proof that the closure holds in the actual repository.

- [ ] **Step 1: Write the executable**

Create `bin/stage-docs-site`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Stages the publishable subset of docs/ into docs-site/build/ for MkDocs.
#
# Everything interesting is in docs-site/stager.rb, which is a pure function
# and has specs. This file is the part with side effects.
require_relative "../docs-site/stager"

root = File.expand_path("..", __dir__)
out = File.join(root, "docs-site", "build")

begin
  staged = DocsSite::Stager.new(:docs_root => File.join(root, "docs"), :out_root => out).call
rescue DocsSite::Stager::ClosureError, DocsSite::Stager::MissingBannerError => e
  warn("bin/stage-docs-site: #{e.message}")
  exit(1)
end

puts("staged #{staged.size} files into docs-site/build")
staged.each { |relative_path| puts("  #{relative_path}") }
```

- [ ] **Step 2: Make it executable and ignore the output**

```bash
chmod +x bin/stage-docs-site
printf '\n# Built by bin/stage-docs-site; never committed.\n/docs-site/build/\n' >> .gitignore
```

- [ ] **Step 3: Run it against the real docs/**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bin/stage-docs-site
```

Expected: exit 0, and exactly this list of thirteen files —

```
staged 13 files into docs-site/build
  manual/be.md
  manual/deployment.en.md
  manual/deployment.ru.md
  manual/en.md
  manual/ka.md
  manual/performance.en.md
  manual/performance.ru.md
  manual/pl.md
  manual/ru.md
  manual/tr.md
  manual/uk.md
  perf/README.md
  runbooks/restore.md
```

If the count is not 13, stop and report — the allowlist or the closure check is wrong, and neither should be adjusted to make the number come out.

- [ ] **Step 4: Verify the banners landed on exactly the five machine-translated manuals**

```bash
grep -l '!!! warning' docs-site/build/manual/*.md | sort
```

Expected: exactly `be.md`, `ka.md`, `pl.md`, `tr.md`, `uk.md`. Confirm `ru.md` and `en.md` are absent from that list, and that the sources are unchanged:

```bash
git status --short docs/
```

Expected: no output. The stager must never modify `docs/`.

- [ ] **Step 5: Commit**

```bash
git add bin/stage-docs-site .gitignore
git commit -m "Add the stager executable and prove the real closure holds"
```

---

### Task 5: MkDocs configuration, and the anchors survive

**Files:**
- Create: `docs-site/mkdocs.yml`
- Create: `docs-site/requirements.txt`

**Interfaces:**
- Consumes: `docs-site/build/` produced by `bin/stage-docs-site`.
- Produces: a built site at `docs-site/site/`, and a `mkdocs build --strict` command that CI reuses verbatim.

**Why this task is not just configuration:** the manuals' anchors were authored against **kramdown**, and Python-Markdown's default slugifier strips non-ASCII entirely, which would silently break every `#6-первый-администратор` link. See spec §4.9. Step 4 is the proof.

- [ ] **Step 1: Pin the dependencies**

Create `docs-site/requirements.txt`:

```
# Pinned exactly: this is the only Python in the repository, and an
# unpinned docs build that changes theme version on its own is a
# surprise nobody is watching for.
#
# mkdocs must stay >= 1.6 -- validation.anchors, which is what stops the
# Cyrillic heading anchors from silently breaking, was added there.
mkdocs==1.6.1
mkdocs-material==9.5.44
```

- [ ] **Step 2: Write the site configuration**

Create `docs-site/mkdocs.yml`:

```yaml
# The documentation site published to GitHub Pages.
#
# This file lives OUTSIDE docs/ deliberately: docs/ is staged wholesale by
# bin/stage-docs-site, and configuration that sat inside it would be published
# as content. docs_dir points at the staged tree, never at docs/ itself --
# docs/manual/*.md is application content, shipped in the Docker image and
# rendered at request time by ManualController, and this build must not touch it.
site_name: encounter-engine
site_description: Free open source engine for "Encounter" urban games
site_url: https://mezinster.github.io/encounter-engine/
repo_url: https://github.com/mezinster/encounter-engine
edit_uri: ""

docs_dir: build
site_dir: site

theme:
  name: material
  # Matches the application's DEFAULT_LOCALE. The site is multilingual in
  # content; the chrome has to pick one.
  language: ru
  features:
    - navigation.sections
    - navigation.top
    - content.code.copy
    - toc.follow
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle:
        icon: material/weather-night
        name: Тёмная тема
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle:
        icon: material/weather-sunny
        name: Светлая тема

markdown_extensions:
  - admonition          # the machine-translation banners
  - pymdownx.details
  - pymdownx.superfences
  - toc:
      permalink: true
      # Python-Markdown's DEFAULT slugifier strips non-ASCII entirely, which
      # would turn "### 6. Первый администратор" into an anchor containing no
      # Cyrillic and silently break every link pointing at it. This one is
      # Unicode-preserving and lowercasing, which is kramdown's behaviour --
      # and kramdown is what these files' anchors were authored against.
      slugify: !!python/name:pymdownx.slugs.slugify
      separator: "-"

# A wrong anchor is not a 404: without this, a slugifier mismatch lands the
# reader at the top of the page and nothing reports it. MkDocs 1.6 resolves
# every #fragment against the anchors it actually generated, and --strict
# turns each miss into a failed build.
validation:
  omitted_files: warn
  absolute_links: warn
  unrecognized_links: warn
  anchors: warn

plugins:
  - search:
      # lunr-languages ships ru, en and tr -- and not uk, be, pl or ka. Those
      # four are searchable without stemming. See the design doc §7.
      lang:
        - ru
        - en
        - tr

nav:
  - Руководство пользователя:
      - Русский: manual/ru.md
      - English: manual/en.md
      - Українська: manual/uk.md
      - Беларуская: manual/be.md
      - Polski: manual/pl.md
      - Türkçe: manual/tr.md
      - ქართული: manual/ka.md
  - Установка / Installation:
      - Русский: manual/deployment.ru.md
      - English: manual/deployment.en.md
  - Нагрузочное тестирование / Performance:
      - Русский: manual/performance.ru.md
      - English: manual/performance.en.md
      - Records: perf/README.md
  - Runbooks:
      - Restoring the database: runbooks/restore.md
```

- [ ] **Step 3: Install and build**

```bash
python3 -m venv /tmp/claude-1000/-home-mezinster-encounter-engine/bc0c1da5-2090-47f2-b448-4fb17686073d/scratchpad/docsvenv
/tmp/claude-1000/-home-mezinster-encounter-engine/bc0c1da5-2090-47f2-b448-4fb17686073d/scratchpad/docsvenv/bin/pip install -q -r docs-site/requirements.txt
bin/stage-docs-site
/tmp/claude-1000/-home-mezinster-encounter-engine/bc0c1da5-2090-47f2-b448-4fb17686073d/scratchpad/docsvenv/bin/mkdocs build --strict -f docs-site/mkdocs.yml
```

Expected: `INFO - Documentation built in ...`, exit 0, no warnings.

If it fails with anchor warnings naming Cyrillic fragments, the slugifier does **not** match kramdown. Do not delete the validation setting to make it pass — report the specific mismatched anchors, because that is the finding spec §4.9 says to surface.

- [ ] **Step 4: Prove the anchors actually resolve**

`--strict` passing is the machine check. Confirm one by hand:

```bash
grep -o 'id="6-[^"]*"' docs-site/site/manual/deployment.ru/index.html | head -3
```

Expected: `id="6-первый-администратор"` — Cyrillic preserved, matching the link target authored in the source.

- [ ] **Step 5: Commit**

```bash
git add docs-site/mkdocs.yml docs-site/requirements.txt
git commit -m "Configure MkDocs, with the anchor validation the Cyrillic links need"
```

---

### Task 6: The workflow

**Files:**
- Create: `.github/workflows/docs-site.yml`

**Interfaces:**
- Consumes: `bin/stage-docs-site` and `docs-site/mkdocs.yml` from Tasks 4–5.
- Produces: a `Docs site` workflow — `build` on every pull request, `build` + `deploy` on master.

- [ ] **Step 1: Look up the current action SHAs**

Do not copy SHAs from memory. Read the ones `ci.yml` already uses for `actions/checkout`, and resolve the rest:

```bash
grep -n 'uses:' .github/workflows/ci.yml
gh api repos/actions/setup-python/git/ref/tags/v5 --jq .object.sha
gh api repos/actions/configure-pages/git/ref/tags/v5 --jq .object.sha
gh api repos/actions/upload-pages-artifact/git/ref/tags/v3 --jq .object.sha
gh api repos/actions/deploy-pages/git/ref/tags/v4 --jq .object.sha
```

Note: a `v5`/`v4` tag may point at a tag object rather than a commit. If `.object.type` is `tag`, dereference it with `gh api repos/<repo>/git/tags/<sha> --jq .object.sha`.

- [ ] **Step 2: Write the workflow**

Create `.github/workflows/docs-site.yml`, substituting the SHAs from Step 1 for each `<sha>`:

```yaml
name: Docs site

# The paths filter is not tidiness. Without it every merge to master rebuilds
# and redeploys a site that did not change, and this repository already runs
# vm-scale.yml every fifteen minutes.
on:
  push:
    branches: ["master"]
    paths:
      - "docs/manual/**"
      - "docs/runbooks/restore.md"
      - "docs/perf/README.md"
      - "docs-site/**"
      - "bin/stage-docs-site"
      - ".github/workflows/docs-site.yml"
  pull_request:
    paths:
      - "docs/manual/**"
      - "docs/runbooks/restore.md"
      - "docs/perf/README.md"
      - "docs-site/**"
      - "bin/stage-docs-site"
      - ".github/workflows/docs-site.yml"
  workflow_dispatch:

# Two merges must not race a half-built site onto the live domain.
concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    name: Build
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Install Python
        uses: actions/setup-python@<sha> # v5
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: docs-site/requirements.txt

      - name: Install MkDocs
        run: pip install -r docs-site/requirements.txt

      # Ruby is preinstalled on ubuntu-latest and the stager needs no gems --
      # it is plain stdlib, deliberately, so this job needs no bundle install.
      - name: Stage the publishable subset of docs/
        run: ruby bin/stage-docs-site

      # --strict is what makes validation.anchors bite: a Cyrillic heading
      # anchor that stopped matching its links fails here rather than shipping
      # links that quietly go nowhere.
      - name: Build the site
        run: mkdocs build --strict -f docs-site/mkdocs.yml

      - name: Upload the artifact
        uses: actions/upload-pages-artifact@<sha> # v3
        with:
          path: docs-site/site

  deploy:
    name: Deploy
    # Pull requests build but never publish: the closure check and --strict
    # report in the PR, before anything reaches the public web.
    if: github.ref == 'refs/heads/master' && github.event_name != 'pull_request'
    needs: build
    runs-on: ubuntu-latest

    permissions:
      pages: write
      id-token: write

    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}

    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@<sha> # v4
```

- [ ] **Step 3: Verify the workflow parses**

```bash
ruby -ryaml -e 'YAML.unsafe_load_file(".github/workflows/docs-site.yml"); puts "yaml ok"'
gh workflow list 2>/dev/null | head
```

Expected: `yaml ok`. (The workflow will not appear in `gh workflow list` until it is on a pushed branch.)

- [ ] **Step 4: Confirm every action is SHA-pinned**

```bash
grep -n 'uses:' .github/workflows/docs-site.yml
```

Expected: every line has a 40-character SHA and a `# vN` comment. No bare `@v4`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/docs-site.yml
git commit -m "Build the docs site on pull requests, deploy it from master"
```

---

### Task 7: Measure the built site, then document it

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-24-docs-github-pages-design.md` (§5.3 only, with the measured result)

**Interfaces:**
- Consumes: the built site from Task 5.

Spec §5.3 states a deliberate bet — that Material's own mobile testing substitutes for a fourth `spec/layout/` file — and commits to checking it once by hand rather than assuming. This task pays that debt.

- [ ] **Step 1: Serve the built site locally**

```bash
cd docs-site/site && python3 -m http.server 8099 &
sleep 1 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8099/manual/ru/
```

Expected: `200`.

- [ ] **Step 2: Measure at a phone viewport**

Do **not** use `LayoutMeasurement#measure`: it is Rails-coupled (it rewrites `href="/stylesheets/…"` against `Rails.root` and inlines an app image fixture) and it loads pages over `file://`. A built MkDocs site has its own relative assets that only resolve over HTTP. Reuse only the genuinely portable part — the browser that `LayoutMeasurement::CHROME_GLOB` locates — and drive it against the local server from Step 1.

Per CLAUDE.md this must be `chrome-headless-shell` (`npx playwright install chromium`); the full `chromium-*` build is **not** a substitute, because it clamps windows to 500px wide and would silently measure every phone viewport as 500.

```bash
CHROME=$(ls -d ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell | tail -1)
for size in 390,680 375,553 1280,800; do
  w=${size%,*}; h=${size#*,}
  echo "=== ${w}x${h} ==="
  "$CHROME" --no-sandbox --hide-scrollbars --window-size="$w,$h" \
    --virtual-time-budget=4000 --dump-dom \
    "http://127.0.0.1:8099/manual/ru/" 2>/dev/null \
    | grep -o 'RESULT=[^<]*' || true
done
```

`--dump-dom` alone returns the DOM, so to get numbers, append a probe to the page instead. The simplest reliable form is to fetch the built page, inject a script, and serve that copy — or run the same measurement through `--dump-dom` on a small wrapper page. Record these three values at each of 390×680, 375×553 and 1280×800:

- `document.documentElement.scrollWidth - document.documentElement.clientWidth` — must be `0` at every size (no horizontal page scroll);
- `document.elementFromPoint(x, y)` at the header's navigation toggle — must return the toggle or a descendant of it, proving it is *hit-testable* rather than merely present, which is the distinction `bin/measure-play-screen` exists to make;
- `getComputedStyle(document.querySelector('.md-content p')).fontSize` — at least 16px, since these are long-form documents read on phones.

- [ ] **Step 2a: Stop the local server**

```bash
kill %1
```

- [ ] **Step 3: Record what was measured**

Append the measured numbers to spec §5.3 — actual values, not "looks fine". If horizontal overflow is non-zero at any viewport, stop: that is a real finding, and the response is a fourth `spec/layout/` file, not a shrug.

- [ ] **Step 4: Document the feature in CLAUDE.md**

Add a section after "The user manual is served at runtime, not just read from a checkout", since the two are neighbours and a reader of one needs the other:

```markdown
## The docs site is a second renderer over the same files

`.github/workflows/docs-site.yml` publishes thirteen files from `docs/` to
https://mezinster.github.io/encounter-engine/ — the seven user manuals, the two
installation guides, the two performance guides, `runbooks/restore.md` and
`perf/README.md`. `bin/stage-docs-site` copies them into `docs-site/build/`
and MkDocs Material builds that.

Three things about it are non-obvious:

- **`docs/` is published by allowlist, not wholesale.** `docs/manual/*.md` goes
  by glob — that directory is already the vetted-public set, since it is what
  `.dockerignore` re-includes into the image — and everything else is named one
  file at a time in `DocsSite::Stager::EXTRA_FILES`. `docs/superpowers/`,
  `docs/security/` and `docs/handoff/` are not published, and the stager's
  closure check **fails the build** if a published page links to any of them.
  That check is the thing standing between "someone adds a helpful link" and
  the security findings register acquiring a public, indexed URL.
- **The anchors are the sharp edge, from the other side.**
  `spec/services/manual/renderer_spec.rb` guards kramdown's anchors for the
  in-app renderer; the Pages build renders the same files with
  **Python-Markdown**, whose default slugifier strips non-ASCII entirely and
  would break every `#6-первый-администратор` link *silently* — a wrong anchor
  is not a 404. `mkdocs.yml` sets `toc.slugify` to pymdownx's Unicode-preserving
  one and `validation.anchors: warn`, which `--strict` promotes to an error.
  Don't remove either.
- **The five machine-translated manuals get a visible banner, derived from
  their own first line.** The `<!-- Machine-translated ... -->` comment renders
  to nothing, which is fine in a repository and not fine on an indexed public
  page. The stager turns it into an admonition in the page's own language, and
  **raises** if a file declares a machine translation for a locale
  `DocsSite::Stager::BANNERS` has no text for — so a new translated manual
  cannot publish unmarked. A locale that gets a native review loses its banner
  by deleting that comment.

The stager is plain stdlib Ruby with no Rails and no gems, specced from
fixtures in `spec/docs_site/stager_spec.rb` — fixtures rather than the real
`docs/`, so that editing a manual cannot redden the default `bundle exec rspec`
run. The real files are checked by the closure check on every push and PR.
```

- [ ] **Step 5: Run the full spec suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
export DATABASE_URL="sqlite3:/tmp/claude-1000/-home-mezinster-encounter-engine/bc0c1da5-2090-47f2-b448-4fb17686073d/scratchpad/pages-test.sqlite3"
bin/rails db:test:prepare
bundle exec rspec
```

Expected: 0 failures. Report the actual example count rather than quoting one — CLAUDE.md records that this number has been stale eight times.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-08-24-docs-github-pages-design.md
git commit -m "Document the docs site and record the measured layout"
```

---

## Verification before opening the PR

- [ ] `bundle exec rspec` — 0 failures, count reported.
- [ ] `bin/stage-docs-site` — exits 0, stages exactly 13 files.
- [ ] `mkdocs build --strict -f docs-site/mkdocs.yml` — exits 0, no warnings.
- [ ] `git status --short docs/manual docs/runbooks docs/perf` — **no output**. The source files must be untouched; this is the constraint the whole design is built around.
- [ ] `git diff --stat master -- app config features` — **no output**. No application code changed.
- [ ] Cucumber is **not** required: no `.feature` file and nothing they exercise is touched. Say so explicitly in the PR body rather than leaving its absence unexplained.
