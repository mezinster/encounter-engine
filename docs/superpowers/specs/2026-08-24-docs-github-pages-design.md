# The docs on GitHub Pages — design

**Date:** 2026-08-24
**Status:** design approved in chat; implementation plan not yet written
**Related:** `docs/manual/*.md`, `docs/runbooks/restore.md`, `docs/perf/README.md`,
`app/services/manual/renderer.rb` (which is **not** changed here), `.dockerignore`,
`.github/workflows/ci.yml` (whose conventions this follows).

## 1. What this is

A static site at **https://mezinster.github.io/encounter-engine/**, built from
thirteen markdown files already in `docs/`, published by a GitHub Actions
workflow.

The audience is people who do not have a checkout: a player who wants the
manual in Belarusian, and — more to the point — somebody deciding whether to
run this engine themselves. That second reader is served today by
`docs/manual/deployment.ru.md`, a 24 KB file whose only web presence is
GitHub's markdown viewer, reachable only if they already found the repository.

### 1.1 What is in scope, and why exactly this set

Thirteen files, chosen as a **link closure** rather than as a folder:

| Group | Files |
|---|---|
| User manual | `manual/{ru,en,uk,be,pl,tr,ka}.md` |
| Installation | `manual/deployment.{ru,en}.md` |
| Performance | `manual/performance.{ru,en}.md`, `perf/README.md` |
| Runbooks | `runbooks/restore.md` |

`docs/manual/` alone is *not* a valid boundary: `deployment.{ru,en}.md` link
out to `../runbooks/restore.md` and `performance.{ru,en}.md` link out to
`../perf/README.md`. Publishing the folder would ship two dangling links.
Following those two edges closes the graph — `perf/README.md` links only back
into `manual/performance.{ru,en}.md`, and `restore.md` links nowhere relative
at all. Measured, not assumed: fourteen distinct relative targets across the
thirteen files, every one of them inside the set.

### 1.2 Non-goals

* **`docs/superpowers/` is not published.** 3.2 MB of plans and specs, 90% of
  `docs/` by size, written for whoever is implementing — including this file.
* **`docs/security/` is not published.** The 2026-08-07 findings register
  describes verified defects, some still open. It is already public in a public
  repository; there is a difference between *public* and *indexed*, and this
  design declines to close it.
* **`docs/handoff/` is not published.** Session context, of interest to nobody.
* **The app is not changed.** No file under `app/`, no route, no spec of
  existing behaviour. See §3.

## 2. The constraint that shapes everything

`docs/manual/*.md` is **not documentation**. It is application content: the
files ship inside the Docker image (`.dockerignore` excludes `docs` wholesale
and then re-includes `!docs/manual`), and `ManualController` renders them at
request time through `Manual::Source` and `Manual::Renderer`. Their heading
anchors are pinned by `spec/services/manual/renderer_spec.rb` against the real
files.

So the Pages build is a **second renderer over live source**, and the first
rule it must obey is that the source stays byte-identical. This rules out the
obvious approach — pointing GitHub Pages at the `/docs` folder and letting
Jekyll build it — because **Jekyll only renders files carrying YAML front
matter**. Adding `---` blocks to these files would make kramdown render them as
content inside the running application, breaking `/manual` and its specs. The
zero-configuration path is the one path that is actually unavailable.

## 3. Standalone mirror, not a migration

Three relationships with the live `/manual` were considered:

1. **Standalone mirror** — the app is untouched; Pages is an independent copy
   that additionally carries deployment, performance and runbooks.
2. **Pages as docs home** — repoint `Manual::Renderer::GITHUB_BLOB` at the
   Pages site so an in-app link to `deployment.ru.md` lands on a readable page
   instead of GitHub's blob view.
3. **Pages replaces `/manual`** — retire `ManualController`.

**Chosen: 1.** It is the only one with an implementation cost of zero in
`app/`, and the only one that cannot regress the running game. 2 remains
available later as a one-constant change; 3 was argued against — it would lose
the in-app locale integration, put the manual behind an external hop, and make
the site an availability dependency of the product.

The accepted cost is duplication: the user manual will exist at two URLs, and
neither points at the other. This is judged acceptable because the two serve
different readers — a logged-in player mid-game, and a search engine result.

## 4. The design

### 4.1 New files

| Path | What it is |
|---|---|
| `docs-site/mkdocs.yml` | Site config: nav, theme, search languages. Lives **outside** `docs/`, so it can never itself be published. |
| `docs-site/requirements.txt` | Exact version pins for `mkdocs` and `mkdocs-material`. |
| `docs-site/stager.rb` | `DocsSite::Stager` — pure Ruby, no Rails. Copies the allowlist, injects translation banners, runs the closure check. |
| `bin/stage-docs-site` | Thin executable: requires the above and runs it. |
| `.github/workflows/docs-site.yml` | Build on pull request; build and deploy on master. |
| `spec/docs_site/stager_spec.rb` | Fixture-driven specs for the stager. |

The logic/executable split mirrors `ops/vmscale/`, where `policy.rb` is a pure
function and `gather.sh` is the thing with side effects: it is what lets the
spec `require_relative` the logic without running it. Everything the site needs
lives under `docs-site/`, so the whole feature is one directory plus one
workflow.

Staging output goes to `docs-site/build/` and is gitignored.

### 4.2 Why MkDocs Material

The alternatives were Jekyll (blocked by §2 unless the stager injects front
matter into copies — extra machinery for a weaker result) and a hand-rolled
Ruby generator reusing kramdown, which is already in the Gemfile.

The hand-rolled option was rejected on a specific, recorded risk. It would mean
owning navigation, search, dark mode and **responsive layout** for a
thirteen-page site with no unusual layout requirements — and this repository has
paid for that twice. `bin/measure-play-screen` exists because a play screen
whose submit button sat below the fold shipped green through both suites.
`spec/layout/manual_layout_spec.rb` exists because the manual's own spacing
regression passed three overflow assertions that measured the wrong thing.
CLAUDE.md's rule is that layout is invisible to both suites; the cheapest way to
respect it is to not author layout. Material is a maintained, mobile-tested
theme.

The cost is a Python toolchain in a Ruby repository. It is confined to the
workflow and to anyone who chooses to preview locally; nothing in `bundle
install`, `bin/rails` or either suite acquires a Python dependency.

### 4.3 The directory layout is preserved, and that is load-bearing

The stager copies files into the build directory **keeping their paths relative
to `docs/`** — `manual/ru.md`, `runbooks/restore.md`, `perf/README.md`.

This is what makes every existing link resolve with **no rewriting at all**:
`](en.md)`, `](deployment.ru.md#6-первый-администратор)`,
`](../runbooks/restore.md)`, `](../perf/README.md)` are all already correct
relative to that structure. MkDocs resolves relative `.md` links to their built
pages natively.

The alternative — reorganising into per-locale trees (`/ru/`, `/en/`, …) to
enable Material's header language switcher — would require rewriting
cross-file links in the staging step. That would put a **second link-rewriting
implementation** in this repository, competing with `Manual::Renderer.rewrite_links`
and free to drift from it. Not worth a dropdown.

### 4.4 Navigation

A hand-written `nav:` in `mkdocs.yml`, four groups, each language labelled with
its own endonym:

```
Руководство пользователя
  Русский · English · Українська · Беларуская · Polski · Türkçe · ქართული
Установка / Installation
  Русский · English
Нагрузочное тестирование / Performance
  Русский · English · Records
Runbooks
  Restoring the database
```

Each of the seven user manuals is one long page — 32 KB to 76 KB. Material builds a persistent
right-hand table of contents from the `##` headings, so `ru.md`'s
Игроку / Автору игры / Администратору become navigable sections. This is
strictly better reading than the app's `/manual`, which has no such index.

**No header language switcher.** Material's `extra.alternate` swaps the whole
site between locale trees, and only the user manual is seven-lingual —
installation is two languages, runbooks are one. A Turkish reader on the
installation page would be offered a control that lies. Seven nav entries are
honest and always visible.

`theme.language` is `ru`, matching the application's `DEFAULT_LOCALE`.

### 4.5 The allowlist

`docs/manual/*.md` by **glob**, plus an explicit list naming
`docs/runbooks/restore.md` and `docs/perf/README.md` one file at a time.

The glob is safe precisely because `docs/manual/` is *already* the
vetted-public directory — it is the one part of `docs/` that ships inside the
Docker image. A new translation therefore publishes itself the day it lands,
which is the desired behaviour. Everywhere else, adding a file to the site is a
visible diff line in `bin/stage-docs-site`, which is the point.

### 4.6 The closure check

After staging, the stager scans every staged file for relative `.md` links and
exits non-zero if any target is not in the staged set.

One check, two failure modes, and the second is the one that matters:

* A link **out** of the published set — someone adds
  `see [the findings](../security/2026-08-07-findings-register.md)` to a
  manual, and the build refuses rather than publishing a link to an
  unpublished document, or worse, prompting someone to widen the allowlist to
  "fix" it.
* A link **broken** by a rename, which today nothing catches for the files the
  app does not serve.

`mkdocs build --strict` then runs as a second net, failing on any internal link
or nav reference MkDocs itself cannot resolve.

### 4.7 The machine-translation banner

Five manuals — `uk`, `be`, `pl`, `tr`, `ka` — carry a first-line HTML comment:

```
<!-- Machine-translated from ru.md on 2026-08-22. Not reviewed by a native speaker. -->
```

**HTML comments are invisible in rendered output.** On a public, indexed site a
Belarusian reader would have no way to learn that 52 KB of prose has never been
read by a speaker of their language. CLAUDE.md is emphatic that this state is
"known and recorded rather than an oversight"; publishing it silently would
make that untrue in the one place it matters most.

The stager parses that comment — the format is uniform across all five files,
and it names both source and date — and emits a Material warning admonition at
the top of the page, in the page's own language. Derived from the source, so
there is no hand-maintained second list of which locales are machine-translated:
a locale reviewed by a human loses its banner by having its comment removed, in
the same commit as the review.

This is the only content transformation in the build. It is additive, it
touches no file on disk, and files without the comment pass through untouched.

### 4.8 The workflow

`.github/workflows/docs-site.yml`, following `ci.yml`'s conventions —
SHA-pinned actions with `# vN` comments, step names that state the reason.

* `pull_request` → **build only**. Link closure and `--strict` report in the PR,
  before anything is public.
* `push` to `master`, filtered by `paths:` on the thirteen source files,
  `docs-site/**`, `bin/stage-docs-site` and the workflow itself → build, then a
  separate `deploy` job with `environment: github-pages` and
  `permissions: {pages: write, id-token: write}`.
* `workflow_dispatch` for manual rebuilds.
* `concurrency: {group: pages, cancel-in-progress: false}`, so two merges cannot
  race a half-built site onto the domain.

The `paths:` filter is not tidiness. Without it every merge to master rebuilds
and redeploys, and this repository already runs `vm-scale.yml` every fifteen
minutes.

### 4.9 The anchors are the sharp edge, again

`spec/services/manual/renderer_spec.rb` exists because the manuals' heading
anchors were authored by hand against **kramdown's** `auto_ids`, and the
in-app renderer has to keep reproducing them. The Pages build inherits exactly
the same problem from the other side, and it is worse there, because MkDocs
renders with **Python-Markdown**, whose `toc` extension slugifies by
*stripping non-ASCII characters entirely*.

Under that default, `### 6. Первый администратор` produces an anchor with no
Cyrillic in it at all, and the eleven intra- and inter-file links of the form
`](deployment.ru.md#6-первый-администратор)` — plus in-page links such as
`deployment.ru.md:79` — silently land at the top of the page instead of the
section. Silently: a wrong anchor is not a 404.

Two settings, both required, neither optional:

```yaml
markdown_extensions:
  - toc:
      slugify: !!python/name:pymdownx.slugs.slugify
      separator: "-"

validation:
  anchors: warn      # with --strict, a warning is a failure
```

`pymdownx.slugs.slugify` is Unicode-preserving and lowercasing, which is
kramdown's behaviour. That it *matches* kramdown on these particular headings
is an empirical claim, not a deduction — so `validation.anchors` is what makes
it safe: MkDocs 1.6 resolves every `#fragment` against the anchors it actually
generated and reports the misses by name, and `--strict` turns that into a red
build. If the two slugifiers ever disagree, the build says so instead of
shipping links that quietly go nowhere.

## 5. Testing

### 5.1 What is tested

`spec/docs_site/stager_spec.rb`, using `spec_helper` rather than
`rails_helper` — the stager needs no Rails, exactly as
`spec/ops/vmscale_policy_spec.rb` needs none. Examples:

1. The allowlist is honoured: an unlisted file in a fixture `docs/` is not staged.
2. A relative link pointing outside the staged set fails the run, non-zero.
3. The banner is injected with the source and date parsed from the comment.
4. A file without the comment is staged byte-identical.

### 5.2 It runs against fixtures, not against `docs/`

Deliberately. CLAUDE.md records that `renderer_spec.rb` pinning a real file
list took the default `bundle exec rspec` red for an ordinary documentation
change, and that the fix was to assert the shape rather than the contents.
Fixture directories mean editing a manual cannot redden the default run.

The real files are still checked on every push and pull request — by the
closure check itself, running in CI. That is the right place for it: it is an
assertion about the repository's current contents, not about the stager's logic.

### 5.3 The gap the specs structurally cannot close

**The rendered site's layout is not tested.** No fourth `spec/layout/` file is
added; the reliance is on Material's own mobile testing.

This is a deliberate, stated bet rather than an oversight, and §4.2 is the
argument for it. It will be checked once, by hand, during implementation: the
built site measured at 390×680 with the existing
`spec/support/layout_measurement.rb` harness, and the result reported. If
Material disappoints, that finding upgrades this section rather than being
absorbed silently.

The second gap is smaller and worth naming: **nothing verifies the deployed
site matches the built one.** The workflow proves the artifact builds; that it
then serves is GitHub's responsibility.

## 6. Rollout

1. GitHub Pages was enabled on 2026-08-24 with `build_type: workflow`, on the
   repository owner's explicit instruction. Site URL:
   `https://mezinster.github.io/encounter-engine/`. `status` was `null` — no
   build had run, because no workflow existed yet.
2. The workflow lands on master and the first deploy runs.
3. No custom domain. `docs.mezin.eu` would need a DNS record and is not part of
   this design.

### 6.1 What the first deploy actually changes

Nothing in scope is secret, and all of it is already public in a public
repository. But **published is not the same as findable**, and `restore.md`
describes the production backup topology. This is recorded as a decision rather
than left as a surprise.

## 7. Search, honestly

Material's search stems words using lunr-languages, which ships `ru`, `en` and
`tr` — and **not `uk`, `be`, `pl` or `ka`**. Those four locales get fully
searchable pages with no morphological stemming: a Ukrainian search for
`команди` will not also match `команда`.

No off-the-shelf option fixes this, and it is not worth a hand-built index for
four machine-translated documents. Recorded so that a later report of "search
is worse in Polish" is recognised as known rather than investigated from
scratch.

## 8. Scope boundary

This design covers publishing thirteen existing files. It does not cover
writing new documentation, restructuring the manual, changing `app/`, a custom
domain, or publishing anything under `docs/superpowers/`, `docs/security/` or
`docs/handoff/`.
