# The manual on the web — design (sub-project A)

**Date:** 2026-08-22
**Status:** design approved in chat; implementation plan not yet written
**Related:** `docs/manual/{en,ru,deployment.en,deployment.ru}.md`,
`app/controllers/concerns/locale_selection.rb`, `.dockerignore`,
`.github/workflows/` (the `app-image` job), and sub-project B — the
superadmin-run translation of the manual, which is **not** designed here.

## 1. What this is

`docs/manual/` holds 116 KB of markdown that nobody using the site can read.
It is four files in a repository: `en.md` and `ru.md` (the user
manual, written for players, game authors and administrators) and
`deployment.en.md` / `deployment.ru.md` (how to run your own server).

This sub-project puts the **user manual** on the web at `/manual`, rendered by
the application, in the reader's chosen language, inside the app's own chrome.
The **deployment guide** stays on GitHub and is reached by a link.

### 1.1 Why this is two sub-projects

The manual exists in Russian and English; the application registers seven
locales. The agreed answer to "what does a Polish player see" is *the manual,
in Polish, produced by the existing Claude translation pipeline and reviewed by
a superadmin* — which is a substantial piece of work in its own right:

* Every entry point in `app/services/translation/` takes a **Game**
  (`Runner.plan(game, locales)`, `game.primary_locale`,
  `game.missing_translated_fields_in`), and `TranslatableContent` requires
  including models to define `#translation_game`. A manual has no game.
* The unit of work there is **a field of a record**. The user manual is one
  document per language — 29 KB in English, 50 KB in Russian, Cyrillic costing
  two bytes a character — and it has to be split along its heading structure,
  *stably*, or a re-run re-translates everything.
* `Translation::Flags`' five checks are right for short strings and blind to
  what breaks a manual: a heading whose translation no longer matches the link
  pointing at it, a dropped code block, an inverted list.
* Game content and its translations live in the same database and change
  together. The manual's **source ships in the Docker image** and changes on
  deploy, while a superadmin-produced translation lives in the **database** and
  does not. That is a staleness axis game content does not have, and it needs a
  source fingerprint stored beside each translation.

None of that can be built before there is something to serve translations
*into*. So: **A first** — the serving layer, with the content source behind one
seam — **then B**, which changes what that seam returns and nothing else.

### 1.2 Non-goals

* **No translation of the manual.** Sub-project B. Until it lands, locales
  without a document fall back to Russian with a visible, honest note.
* **No GitHub Pages.** See §6.
* **No table of contents, sidebar, or search.** The documents carry their own
  in-page navigation already.
* **No splitting the manual into per-section pages.** One document, one page;
  the existing `](#anchor)` links depend on it.
* **No editing of manuals through the web.** They are files in git.

## 2. What the content actually is

Measured on the four real files, because the design depends on it:

| | `en.md` | `ru.md` | `deployment.en.md` | `deployment.ru.md` |
|---|---|---|---|---|
| bytes | 29 204 | 50 369 | 14 352 | 22 512 |
| lines | 687 | 656 | 356 | 355 |
| table rows | 47 | 47 | 54 | 54 |
| fenced code blocks | 2 | 2 | 28 | 28 |
| images | 0 | 0 | 0 | 0 |
| raw HTML | 0 | 0 | 0 | 0 |

Tables are at most three columns; the longest markdown table row is 135
characters. There is no raw HTML — the one apparent match is `` `<service>-db` ``
inside a code span.

Two consequences:

1. The converter must handle **GFM tables and ``` fences**. A bare CommonMark
   parser is not enough.
2. Those tables have to survive a 390 px phone. See §5.3.

### 2.1 The anchors are the sharp edge

The manuals cross-link themselves with GitHub-generated anchors, in both
alphabets:

```
](#игроку)                    ← ## Игроку
](#6-первый-администратор)    ← ## 6. Первый администратор
](#for-players)               ← ## For players
](#файлы-и-изображения)       ← ### Файлы и изображения
```

Most Ruby markdown libraries generate heading ids with an ASCII-centric slug
that strips non-Latin characters outright, which would turn every Russian
anchor into `section`, `section-1`, `section-2`. **The links would still
render.** They would be clickable, styled, and land nowhere, and nothing would
raise — the same failure shape this repository has recorded twice already
(`Vips.get_suffixes.include?(".heic")` returning true on a machine that cannot
decode HEIC; the countdown examples reporting *pending* in CI for a fortnight).

So the design does not delegate heading ids to the library. See §4.2.

## 3. Why render at request time

Three approaches were considered:

| | Runtime render (chosen) | Convert during docker build | Commit generated HTML |
|---|---|---|---|
| App chrome (menu, locale switcher) | free | must be duplicated, then drifts | same |
| Dev loop | edit `.md`, refresh | run a task first | run a task, commit |
| New build step in the Dockerfile | none | **the first one this image has had** | none |
| Bad markdown surfaces as | 500 at request time | build failure | CI failure |
| Compatible with sub-project B | **yes** | no | no |

The last row decides it. **B writes translations at runtime, from a
superadmin's browser, into a database; a docker image is read-only.** Both
build-time approaches bake the set of available languages into the artifact, so
the first superadmin-produced Polish translation would have nowhere to go that
the serving layer could see — and the serving layer would be rewritten into the
runtime approach to fix it. Choosing either now means building it twice.

The secondary arguments agree. The Dockerfile says of itself: *"No asset
precompile: this app has no asset-pipeline gem. Static files are served
straight from `public/`."* Zero build steps means the build has zero ways to
fail, and neither test suite evaluates `config/environments/production.rb`, so
image-level breakage is caught only by the `app-image` CI job — adding the
first build step widens exactly the gap that job exists to cover.

The one real cost of rendering at request time is that malformed markdown
becomes a runtime error rather than a build error. §5.1 answers that with a
spec that renders every shipped manual, which the other two approaches would
have needed anyway.

Cost on the host is not a concern: `Rails.cache` is `:memory_store`, so this is
one conversion per document per container lifetime (§4.4).

## 4. The design

### 4.1 Route, controller, resolver

One route, public, no `before_action` guard:

```ruby
get "/manual" => "manual#show", as: :manual
```

Linked from **both** branches of `app/views/layouts/_left_menu.html.erb` —
signed in and signed out. The manual's first section is "Signing up and signing
in", written for someone who has done neither.

`ManualController#show` does not touch the filesystem. It asks a resolver:

```
Manual::Source.for(I18n.locale)
  → { markdown:, locale_used:, digest: }
```

File-backed today: `docs/manual/#{locale}.md` when that file exists, otherwise
`ru.md`, **reporting which one it actually used**. `locale_used` is the point
of the interface — the view renders an honest note when it differs from
`I18n.locale` ("this manual is not yet available in your language; showing the
Russian version") and omits the note when they match.

**`Manual::Source` is the seam for sub-project B.** B changes one thing: the
resolver consults an approved translation row before it consults the file.
Controller, cache, renderer and view are unaffected.

### 4.2 The rendering pipeline

Four stages, each independently testable:

1. **Parse** — `kramdown` with `kramdown-parser-gfm` (`input: 'GFM'`). Pure
   Ruby, so no native extension enters the image; the GFM parser covers the
   tables and ``` fences that §2 found. **`auto_ids` is off**, deliberately.
   HTML input is escaped — nothing in these files needs raw HTML.
2. **Anchor pass** — Nokogiri (already present via Rails) walks `h1`–`h6` and
   assigns ids with our own GitHub-compatible slugger: Unicode-aware downcase,
   drop everything that is not a letter, number, space, hyphen or underscore,
   spaces to hyphens, duplicates suffixed `-1`, `-2`.
3. **Link pass** — same Nokogiri document:

   | href in the markdown | becomes |
   |---|---|
   | `ru.md`, `en.md` | `/manual?locale=ru`, `/manual?locale=en` |
   | `deployment.en.md`, `deployment.ru.md` (with or without `#fragment`) | GitHub blob URL on `master`, fragment preserved |
   | `../runbooks/restore.md` | GitHub blob URL on `master` |
   | `#fragment` | untouched |
   | `http://`, `https://` | untouched |

   Rewriting `ru.md` to `/manual?locale=ru` reuses the existing `?locale=`
   precedence in `LocaleSelection`, which also writes `session[:locale]` — so
   choosing a language from inside the manual behaves exactly like choosing it
   from the header switcher.
4. **Cache** — `Rails.cache.fetch(["manual", locale_used, digest])`. Keyed on
   the **file digest**, not a constant: editing `ru.md` in development
   invalidates it without a restart, and a fresh container recomputes exactly
   once per document.

### 4.3 Why we own the slugger

Every markdown library has its own slug rule, and if the library's rule
disagrees with the anchors already written into these files, the links break
silently (§2.1). Owning the slug generation makes it a function a test can be
pointed at, with the real cases in it.

It also sets B up correctly: a translated document's headings and its own
internal links are slugged by the **same** function, so they agree with each
other. This deliberately does not chase byte-parity with GitHub for Turkish
`İ`, where Ruby's `downcase` and GitHub's differ — self-consistency inside one
document is what makes a link work; parity with GitHub is not needed.

CLAUDE.md's ban on Ruby-side `.upcase`/`.downcase` is about **user-facing
text**, where locale-blind casing turns `i` into `I` rather than `İ`. An `id`
attribute is machine-facing and never displayed; this is the one place that
rule does not bite, and the reason is recorded here so the next reader does not
have to re-derive it.

### 4.4 New dependencies

`kramdown` and `kramdown-parser-gfm`. Both pure Ruby and MIT-licensed, so
nothing new has to compile in the build stage. The `bundler-audit` CI job
covers them like any other gem.

The library choice is **provisional until proven on the real files**: the
implementation plan's first task renders all four and checks tables, fences and
anchors. If kramdown mangles any of them, `commonmarker` is the fallback and
the rest of this design is unchanged — stages 2, 3 and 4 sit above the parser
precisely so that swap costs one stage.

### 4.5 i18n

New keys in **all seven** locale files (`ru`, `en`, `uk`, `ka`, `tr`, `be`,
`pl`): the left-menu label, the page title, and the fallback note. Missing keys
fall back to `ru` and only raise when `ru` lacks them too, but
`spec/i18n_spec.rb` enforces exact `ru`↔`en` parity, and writing all seven at
once is cheaper than a follow-up.

The manual's **content** is never run through `t()` — same rule as game
content. It is prose in a file, rendered verbatim.

## 5. Testing

### 5.1 Unit and request

| Spec | What it pins |
|---|---|
| `spec/services/manual/slugger_spec.rb` | The real cases as a table: `Игроку → игроку`, `6. Первый администратор → 6-первый-администратор`, `For players → for-players`, `Файлы и изображения → файлы-и-изображения`, plus duplicate-heading suffixing |
| `spec/services/manual/renderer_spec.rb` | **Anchor integrity over all four shipped files**: render, collect every `id`, collect every `href="#…"`, assert each resolves. Plus tables become `<table>`, fences become `<pre><code>`, and **no `.md` href survives the link pass** |
| `spec/services/manual/source_spec.rb` | Locale resolution and fallback; `locale_used` reports honestly; the digest changes when content does |
| `spec/requests/manual_spec.rb` | 200 signed out and signed in; the fallback note present for `pl`, absent for `ru`; the menu link present in both branches |

The anchor-integrity spec reads the **actual shipped manuals**, not a fixture.
That is what makes it fail the day someone renames a heading without updating
the link pointing at it.

### 5.2 The frozen acceptance suite

Adding a left-menu entry changes the rendered body of **every** page in the
suite. Before merge, run the inherited set exactly as CLAUDE.md prescribes:

```bash
git ls-tree -r --name-only d035146 | grep '\.feature$' | sort > /tmp/inherited
git ls-files 'features/**/*.feature' | sort > /tmp/current
bundle exec cucumber $(comm -12 /tmp/inherited /tmp/current | tr '\n' ' ')
```

Expected, unchanged: **228 scenarios (226 passed, 2 undefined) / 2325 steps**.
No `.feature` file is edited by this work, of either provenance.

### 5.3 Layout

`spec/layout/manual_layout_spec.rb`, joining the two specs already in
`spec/layout/`. 47 table rows at up to 135 characters, rendered at 390 px:
tables get an `overflow-x: auto` wrapper, and the spec asserts **page-level
horizontal overflow is 0** at 390×660 — the table scrolls, the page does not.
The rules go in `public/stylesheets/layout.css` under a `.manual` scope, beside
the existing layout rules; this app has no asset pipeline and no second place
to put them.
Under the `:layout` tag, excluded from an ordinary `bundle exec rspec`, and
**raising** rather than skipping when the browser binary is absent.

### 5.4 The gap the specs structurally cannot close

`.dockerignore` line 4 is `docs`. Every spec runs from a checkout where the
manuals exist, so **the whole suite stays green against an image that has no
manual at all**. This is the shape CLAUDE.md records for the libvips package
name: *the error existed only at the seam between the image and a developer's
machine.*

So the `app-image` CI job — which already proves the image serves — gains one
assertion: `GET /manual` returns 200 and contains a known heading. That is the
only check in the system capable of failing if the `.dockerignore` edit is ever
reverted.

## 6. Rollout

**`.dockerignore`** — un-ignore `docs/manual` only, keeping
`docs/security/`, `docs/handoff/`, `docs/runbooks/` and `docs/superpowers/` out
of the image. The intended form is:

```
docs
!docs/manual
```

**This must be verified, not assumed.** Re-including a subdirectory of an
excluded directory behaves differently in `.gitignore` — where excluding a
directory stops git descending into it — than in Docker, whose matcher
evaluates full paths. The plan proves it by building the image and listing the
file. If BuildKit does not re-include, the fallback is naming the other
`docs/*` subdirectories explicitly.

Keeping the rest of `docs/` out is not only about image size:
`docs/security/2026-08-07-findings-register.md` has no business inside a
running container.

**The deployment guide** gets no route and no Pages site. GitHub already
renders `docs/manual/deployment.ru.md` at a stable URL, with correct Cyrillic
anchors, using the renderer those files were written against. Its readers are
people about to clone the repository. GitHub Pages would mean a workflow to
publish `docs/manual` alone (pointing Pages at `docs/` would publish the
security register as an indexed website), and it renders through
Jekyll/kramdown, which brings the anchor problem of §2.1 straight back. If a
real documentation site is wanted later, it should be built on the converter
this sub-project produces — that is the only way to get the anchors right.

## 7. Scope boundary

**In:** the route, `Manual::Source`, the renderer, the slugger, the link pass,
the cache, menu links in seven locale files, the specs of §5, the
`.dockerignore` change, the `app-image` assertion.

**Out:** translation of the manual (sub-project B), a table of contents,
sidebar navigation, search, per-section pages, GitHub Pages, and any editing of
manuals through the web.
