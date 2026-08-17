# Translating large games — encounter-engine

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-17
**Related:** amends `2026-08-16-ai-translation-design.md`. That design is otherwise intact; this
changes one guard, one estimator, and one stylesheet. No new table, no new state, no new concept.

## Goal

Let a superadmin translate a game of any realistic size in one press, and give the panel that
starts it a layout that reads as deliberate.

The trigger was a real report: translating the quiz **«Викторина»** — ~70 levels, five options
each — refused with *«Слишком много полей за один раз (максимум 400).»*, and the reporter asked
what would happen when translating into several languages at once.

## The answer to that question, because it shaped the design

Worse, proportionally. `Translation::Runner.plan` (`app/services/translation/runner.rb:19`) is:

```ruby
locales.reject { |l| l.to_s == game.primary_locale.to_s }
       .flat_map { |locale| game.missing_translated_fields_in(locale) }
```

`work.size` is therefore **fields × locales**, and that product is what the cap is checked against
in `TranslationRunsController#create:39`. Every additional language multiplies the count, so a game
that fails at one language fails harder at six.

### Why «Викторина» is over 400 at one language

Translatable fields are declared per model: `Game` `name`+`description`, `Level` `name`+`text`,
`Hint` `text`, `Option` `text`, and `Question` **none** — its column is vestigial and deliberately
empty (`app/models/question.rb:5`).

| source | fields |
|---|---|
| game name + description | 2 |
| ~70 levels × (`name`, `text`) | ~140 |
| ~70 × 5 options | ~350 |
| **one locale** | **~492** |
| six non-primary locales | ~2952 |

The exact figure depends on how many fields are already translated and on hint count; the shape is
what matters — a quiz's option rows dominate, and they scale with the question count.

### The cap was doing a second, undocumented job

`create` checks `too_large` **before** calling `render_confirmation`, and that method runs
`Translation::Runner.estimate_input_tokens`, which is **one `count_tokens` HTTP round trip per unit
per locale** (`runner.rb:76`), synchronously inside the POST. A unit is the game header plus one
per level, so «Викторина» is 71 units: 71 blocking round trips at one language, ~426 at six.

So the 400 cap is currently the only thing standing between the operator and a pre-flight that
does not terminate in web-request time. **Raising the number alone would convert a clean Russian
refusal into a hang and a 502.** This is the same unbounded pre-flight already recorded as an open
follow-up after the feature shipped; it is fixed here because it cannot be avoided any longer.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Chunking mechanism | **None added** | The runner's unit loop already *is* resumable batching — see §3. A parent/child run layer would add a table, states and index rules to solve a solved problem |
| `translation_max_fields_per_run` | Kept, meaning changed: backstop not working limit. Default **400 → 5000** | Already a `Setting`, admin-editable, `too_large` translated in all seven locales, covered by specs. 5000 clears «Викторина» into all six non-primary locales (2952) with headroom while still refusing pathological input |
| Pre-flight | Prefix + bulk arithmetic, **≤ locales + 1 calls** | Constant in game size instead of linear. Uses the same `request_body` seam, so it still prices the run that actually happens |
| Cost in money on the confirmation screen | **Out of scope** | Needs per-model pricing the app does not hold. The screen keeps showing estimated input tokens |
| Panel layout | CSS only, no markup change | The staircase is unstyled default; no `.translate-panel`/`.translate-locales` rule exists anywhere |

## §1 — The wall

One `if` refuses the job before any of the working machinery runs
(`app/controllers/translation_runs_controller.rb:39`). Nothing else changes about it: same guard,
same message, same `Setting`, same position in the sequence of refusals. Only
`app/models/setting.rb:44` moves, `400` → `5000`.

Keeping the guard rather than deleting it matters. It is the only bound on a single press, it is
already reachable by an admin who needs a bigger or smaller one, and the message
(`translations.runs.too_large`, `"Слишком много полей за один раз (максимум %{count})."`) stays
accurate at any value because it interpolates the setting.

The existing spec that sets the value to `1` and expects a refusal
(`spec/requests/translation_runs_spec.rb:126`) stays exactly as it is — it is what proves the
backstop still bites after the default moves.

## §2 — The pre-flight

`Translation::Client#request_body` (`app/services/translation/client.rb:92`) builds every call as:

```
system:   [ RULES ]  +  [ unit.source_text ]     ← cache breakpoint on the second block
user:     "Translate the above into <Language>."
```

So a call's input tokens are `CONST` (rules + JSON-schema/output-config overhead) plus
`tokens(unit source)` plus `tokens(instruction for that locale)`, and the job total is:

```
Σ  =  n_units × Σ_locales baseline(locale)  +  n_locales × Σ_units tokens(source)
```

Both terms are measurable in a constant number of calls:

* **`baseline(locale)`** — one `count_tokens` per target locale, with a unit whose source is a
  minimal placeholder. `Translation::Unit.new(key, fields)` is a plain constructor, so a
  synthetic unit needs no new class.
* **`Σ tokens(source)`** — one `count_tokens` over a synthetic unit carrying **every** field in the
  work-list, minus that locale's baseline.

That is **`locales + 1` round trips** — at most 7 here — against 426 today. Detail 3 below can raise
it to `locales + k` for a game whose sources need splitting into `k` pieces, where `k` is small and
grows with total source size, never with unit count. The property to hold on to is that the call
count is **independent of how many levels the game has**.

Three details the implementation must get right:

1. **The placeholder must not be empty.** The Anthropic API rejects empty text blocks, and the
   source is a text block. Use a one-character source and accept the resulting error of roughly one
   token per call, which is noise against a five-figure total.
2. **Tokenisation is not perfectly additive.** Concatenating sources may tokenise a few tokens
   differently at each boundary. This is an estimate on a screen, and the error is far below the
   variance the estimate already has against real usage (prompt caching means actual billed input
   is a fraction of it).
3. **The bulk call needs a size guard.** A game large enough that its concatenated sources approach
   the model's input limit must have the bulk call split into a handful of pieces, each with its
   baseline subtracted. Still O(few), never O(units).

The failure behaviour is unchanged and deliberate: `render_confirmation` rescues
`Translation::Client::Error` and renders "unknown" rather than refusing the run. The estimate is a
courtesy; a guard that blocked translation because a free token count failed would cost more than
it saves.

## §3 — What deliberately does not change

`Translation::Runner#call` (`runner.rb:102`) already executes chunk-wise and resumably:

* one API call **per unit per locale** — never one giant request;
* proposals committed in a transaction **per call** (`record_proposals`), so progress is durable at
  every step;
* `@run.touch` after every call, so `TranslationRun.sweep_stale!`'s 15-minute window is measured
  per call and never fires on a healthy long run;
* `cancelled?` checked before every call;
* `already_proposed?` scoped to this run, which is what makes Retry resume rather than re-pay.

Consequently a long run needs no new machinery. Checked against ~426 calls:

| concern | why it holds today |
|---|---|
| stale sweep kills a healthy run | `touch` is per call, not per run |
| deploy kills the thread | run goes stale → swept to `failed` → **Retry** re-enters and skips everything already proposed |
| memory on a 1 vCPU / ~1.1 GB host | ~71 `Unit` objects and ~3000 `MissingTranslation` structs |
| operator cancels | checked before every call |
| two threads on one run | partial unique index `index_translation_runs_one_active_per_game` |

**Honest limitation, recorded rather than solved:** wall-clock. A six-language run on a game this
size is hundreds of sequential calls and may well exceed an hour. It survives a deploy and it can
be cancelled, but it is not quick, and the confirmation screen should not imply that it is.

## §4 — The panel

`app/views/games/edit.html.erb:89-99` renders a `<ul class="translate-locales">` of `<li>`, each
holding a text label and a `button_to` (which renders its own `<form>`). **No rule for either class
exists in `public/stylesheets/`** — the staircase in the report is the browser's default rendering
of a form after a text node, nothing more.

CSS only, no markup change:

```css
.translate-locales { display: grid; grid-template-columns: max-content max-content; }
.translate-locales li { display: contents; }
```

`max-content` sizes the label column to the widest endonym — ქართული and Беларуская are the long
ones — so every «Перевести» starts at the same x without a hard-coded width that would break on a
font, a locale addition, or a translation change. `display: contents` is what promotes each `li`'s
two children into items of the parent grid, which is the only way to align across rows without
subgrid.

**To verify, not assume:** `display: contents` on a list item historically dropped list semantics
from the accessibility tree in Chrome and Safari. That has been fixed, but this codebase's standing
lesson is that layout claims are checked in a real browser. Confirm it; if it has not been fixed in
a browser we care about, fall back to a flat `<div>` grid and drop the list semantics explicitly
rather than silently.

The panel is superadmin-only, so phone width is a low-stakes case — but it must not overflow
sideways, which is asserted rather than eyeballed (§5).

## §5 — Testing

* **`Runner.estimate_input_tokens`** — `Client` stubbed, as every spec in this feature already does.
  The load-bearing assertion is a **call count**: a many-unit, many-locale game must issue
  `locales + 1` `count_tokens` calls (no splitting at that size), and — the part that actually pins
  the fix — **the count must not change when the level count doubles**. An assertion on the returned
  number alone would pass identically with the O(units × locales) loop still in place, which is
  exactly the bug being fixed.
* **Arithmetic** — with stubbed per-call counts, the returned total must equal the closed form in
  §2 for a game of known shape.
* **Bulk splitting** — a work-list large enough to trip the size guard still returns a total and
  still issues O(few) calls.
* **Request spec** — a game above 400 but below the new ceiling now reaches the confirmation screen
  instead of `too_large`. The Setting-of-1 refusal spec stays.
* **Layout** — one example in `spec/layout` asserting the «Перевести» buttons share an x offset and
  that the panel does not overflow horizontally at phone width. `spec/layout` is excluded from an
  ordinary `rspec` run and needs `chrome-headless-shell`; it raises rather than skips when asked to
  run without one. This is the same class of bug as the play-screen chrome that was invisible to
  both suites for weeks — neither Capybara nor a request spec can see a two-column grid.

## §6 — Delivery

Two PRs, in either order — they touch disjoint files.

1. **The panel.** `public/stylesheets/*.css` plus the layout example. Small and independently
   useful.
2. **The wall and the pre-flight.** `app/models/setting.rb`, `app/services/translation/runner.rb`,
   and its specs.

## Non-goals

* No parent/child run tables, no new run states, no scheduler, no ActiveJob backend.
* No cost-in-money display.
* No change to what is translatable, to the review/accept flow, or to the publish gate.
* No overwrite path: the work-list is still missing fields only.
* No Turbo, no rails-ujs, no JavaScript added to the panel.
