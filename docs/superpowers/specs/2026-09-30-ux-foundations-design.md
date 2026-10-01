# UX Foundations: type scale, form system, styleguide — encounter-engine

**Status:** approved in conversation 2026-09-30; this is the written spec for review.
**Date:** 2026-09-30
**Programme:** first of four sub-projects in the 2026-09 visual/UX wave. The others, each with its
own spec later: A+G (retire the Dynarch calendar and jQuery autocomplete; style translation
review), E (public face), D (operator on a phone). A fifth, C (destructive actions behind a
confirm), is **deferred** — see "Out of scope".
**Related:** `2026-08-06-ui-refactor-design.md`, the previous UI wave. That wave tokenised colour
and spacing completely (zero hex literals in the four main stylesheets) and never reached type,
breakpoints, z-index, or form controls beyond text inputs. This spec finishes those.

## Goal

Give every later screen in the wave one system to draw from, so no sub-project restyles the same
control twice:

1. A **type scale** that every `font-size` resolves through.
2. **Breakpoints and stacking layers** that are a documented, enforced set rather than loose numbers.
3. A **complete form system**: every input type the views use, inline field errors that work on a
   phone, a secondary and a disabled button state, and input borders that meet WCAG 1.4.11.
4. A **styleguide page** that renders all of it from real code, visible to superadmins in
   production, which the layout specs measure and Superdesign uses as context.
5. **Guards** in the default RSpec run so the system does not drift back.

Success is: both suites green with the inherited 228/2325 Cucumber contract intact and no
`.feature` file touched; the new token-discipline spec red on any raw `font-size`, off-set
`@media` width, or raw `z-index`; and the styleguide layout spec passing in both themes at
390×680 and 1280×800.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Type scale | **Snap** all sizes to six steps plus the existing fluid clamps | A real scale, not 14 named sizes. Small visible shifts are accepted; the 11–12px uppercase labels rise to 12.8px, a readability gain outdoors |
| Breakpoints | Keep **48 / 52 / 60rem**, enforced by spec | CSS variables do not work in `@media`. 52rem is not noise: it is where the play bar becomes a side panel, and the owner's ~845px laptop sits just above it |
| Field errors | **Mark + inline message**, summary kept | On a phone the summary scrolls out of view; inline messages make each field fixable in place |
| Styleguide | **Superadmin-visible in production** at `/admin/styleguide` | Lets the live theme be reviewed on real devices; reuses the existing superadmin guard |
| Checkbox / radio | **Native, `accent-color`**, not redrawn | Redrawing in CSS costs accessibility and buys only looks |
| Specimen text | **Verbatim**, not i18n'd | It is sample content, like author-written game text; only page chrome gets `t()` keys |

## §1 Tokens

All in `public/stylesheets/tokens.css`. Values below are the spec; the implementation may not
invent others.

### §1.1 Type scale

```
--text-xs:   0.8rem;    /* 12.8px */
--text-sm:   0.875rem;  /* 14px   */
--text-md:   1rem;      /* 16px   */
--text-lg:   1.125rem;  /* 18px   */
--text-xl:   1.25rem;   /* 20px   */
--text-2xl:  1.5rem;    /* 24px   */
--text-body: clamp(16px, 0.95rem + 0.2vw, 18px);          /* today's body size, unchanged */
--text-h1:   clamp(1.6rem, 1.3rem + 1.4vw, 2.4rem);       /* today's h1, unchanged */
--text-h2:   clamp(1.2rem, 1.05rem + 0.7vw, 1.6rem);      /* today's h2, unchanged */
```

`--text-body` keeps its **16px floor deliberately**: iOS zooms a focused input below 16px, and
inputs use `font: inherit`. Nothing in this spec may put an input below `--text-body`.

`--text-md` and `--text-2xl` have no current declaration mapped to them. They are steps of the
scale, provided for E and D, not dead tokens.

Every existing declaration (19 across `base`, `components`, `layout`, `screens`) maps as follows:

| Today | Selector(s) | Becomes | Shift |
|---|---|---|---|
| `clamp(16px…18px)` | `body` (`base.css:31`) | `--text-body` | none |
| h1 clamp | `h1` (`base.css:40`) | `--text-h1` | none |
| h2 clamp | `h2` (`base.css:41`) | `--text-h2` | none |
| 1.05rem | `h3` (`base.css:42`) | `--text-lg` | +0.075rem |
| 0.68rem | `.file-table .file-thumb-generic` (`components.css:166`) | `--text-xs` | +0.12rem — **check it still fits its 48px box** |
| 0.72rem | `.table--cards td::before` (`components.css:136`) | `--text-xs` | +0.08rem |
| 0.75rem | `.tag` (`components.css:222`) | `--text-xs` | +0.05rem |
| 0.78rem | `th`, `.stat-label`, `ul.language-tabs .missing-count`, `.attachment-item--generic` | `--text-xs` | +0.02rem |
| 0.875rem | `.topbar-time` (`layout.css:82`) | `--text-sm` | none |
| 0.9rem | `.field > label`, `.participation`, `.notice, .hint-text` | `--text-sm` | −0.025rem |
| 1.1rem | `.attachment-generic-icon` (`screens.css:426`) | `--text-lg` | +0.025rem |
| 1.15rem | `.generated-password` (`components.css:71`) | `--text-lg` | −0.025rem |
| 1.2rem | `#drawer-toggle` (`layout.css:212`) | `--text-xl` | +0.05rem |
| 1.8rem | `.stat-value` (`screens.css:133`) | `--text-h1` | 1.6rem on phones, up to 2.4rem wide — a display numeral, sized like a heading |

`.hint-text` is on the play screen, and `.notice` shares its rule; both shrink by 0.4px.
`bin/measure-play-screen` must pass after this mapping lands (§4.3).

### §1.2 Breakpoints

`tokens.css` gains a header comment declaring the allowed set and why each exists:

| Width | Used by | Meaning |
|---|---|---|
| `max-width: 47.99rem` / `min-width: 48rem` | `layout.css`, `components.css`, `screens.css` | drawer becomes a static column; `.table--cards` stops stacking |
| `min-width: 52rem` | `layout.css:397`, `screens.css:442` | the play bar becomes a side panel |
| `min-width: 60rem` | `screens.css:10` | wide layouts |

No value changes. The set is enforced by §4.1. `prefers-reduced-motion` and other non-width
media features are not restricted.

### §1.3 Stacking layers

The audit that started this wave reported six z-index values from 15 to 100. That was wrong:
there are **five declarations, four distinct values**. Each becomes a token, values unchanged:

```
--z-sticky:   15;  /* .playbar (screens.css:329) */
--z-scrim:    25;  /* .drawer-scrim (layout.css:255) */
--z-drawer:   30;  /* #drawer (layout.css:239) */
--z-topbar:   40;  /* .topbar (layout.css:46) */
--z-dropdown: 25;  /* .locale-menu (layout.css:147) -- inside .topbar's stacking
                      context, so this orders it only among the topbar's children */
```

`--z-dropdown` and `--z-scrim` share a value but not a meaning, which is why they are two tokens.
(The conversation that approved this spec named the tokens sticky/drawer/dropdown/overlay before
the declarations were inventoried; this list is the corrected one, from the code.)

### §1.4 Input border

WCAG 1.4.11 requires **3:1** for the boundary that identifies a form control. It does **not**
apply to card and panel borders, which are decorative — the three surface shades already separate
them — so `--border` stays as it is.

Inputs are filled with `--bg` and can sit on `--bg`, `--surface`, or `--surface-2`, so
`--border-input` must clear 3:1 against all three:

| Theme | `--border` today (vs bg / surface / surface-2) | `--border-input` | vs bg / surface / surface-2 |
|---|---|---|---|
| dark | `#332e29`: 1.41 / 1.30 / 1.21 | **`#7a7066`** | 3.92 / 3.61 / **3.37** |
| light | `#ddd5cd`: 1.37 / 1.45 / 1.27 | **`#857b71`** | 3.91 / 4.14 / **3.62** |

Both are the first candidate on the theme's warm grey ramp with at least ~10% margin over 3:1,
so rendering and rounding cannot drop them below the line. The ratios go into a comment beside
the token, matching how `tokens.css` already records its contrast decisions.

## §2 Form system and field errors

### §2.1 Controls (`components.css`)

- **Text-like inputs.** The shared selector at `components.css:77` extends to `number`, `search`,
  `url`, `tel`, and `datetime-local` (the last is for A), and its border becomes
  `--border-input`. This styles the 20 `number_field`s that render with browser defaults today.
- **Checkbox and radio.** `accent-color: var(--go)`, `width`/`height: 1.25rem`. A new `.check`
  pattern — a label wrapping its input, `display: flex`, `min-height: var(--tap)` — makes the
  whole row the tap target. Applies to the 17 `check_box` and 5 `radio_button` uses; existing
  `.quiz-option` styling is left as it is.
- **File input.** `::file-selector-button` takes the `.btn` look.
- **`:disabled`.** Inputs and buttons get `color: var(--text-dim)` and `cursor: not-allowed`.
  **No opacity**: on the dark theme a faded control becomes unreadable rather than inactive.
- **Invalid.** `.is-invalid` on an input sets `border-color: var(--danger)`; on a label it colours
  the label `--danger`. `.field-error` is `--text-sm`, `--danger`, directly under its field.

### §2.2 Buttons

Add `.btn--quiet`: transparent background, no border, `--text-dim`, `--text` on hover — for
cancel and back. The hierarchy comment at the top of `components.css` becomes
**go → neutral → quiet**, with danger set apart. Danger placement is untouched (C).

### §2.3 `field_error_proc`

Set `config.action_view.field_error_proc` in `config/application.rb` — this app deliberately has
no `config/initializers/`. It replaces Rails' default, which wraps the field **and its label** in
`<div class="field_with_errors">`; that wrapper breaks `.field > label` today, so invalid fields
silently lose their label style. Nothing in `app/`, `spec/`, `features/` or `public/` references
`field_with_errors`, so removing it breaks nothing.

The proc receives `(html_tag, instance)` and parses `html_tag` as a fragment:

- **`<input>`, `<select>`, `<textarea>`** (excluding `type="hidden"`): add `aria-invalid="true"`
  and the `is-invalid` class. If the element has an `id`, add
  `aria-describedby="<id>-error"` and emit, immediately after it,
  `<span class="field-error" id="<id>-error">…</span>`, containing
  `instance.object.errors[<method>]` joined with `"; "`, **HTML-escaped**.
- **`type="radio"`**: mark invalid only, **no** message span — a group would otherwise repeat the
  message under every option. The summary still lists it.
- **`type="checkbox"`**: same as any input (one control, one message). Rails' companion hidden
  input is left untouched.
- **`<label>`**: add the `is-invalid` class only. No wrapper, no message.
- **No `id`** (rare; `*_tag` helpers without one): mark invalid, no message span — there is
  nothing to link it to.

Messages are shown as stored, without the attribute name. Most are the **predicate** form
("не может быть пустым"), which reads correctly because the field's own label sits directly above
it — the convention CLAUDE.md already sets, and a second reason to keep it. Older models are not
all on that convention: `User`'s Merb-era messages are full sentences ("Вы не ввели имя"). Those
read correctly under a field too, so they are shown unchanged rather than rewritten here.

### §2.4 Live regions

- `error_messages_for` wraps its summary with `role="alert"`, so a failed submit is announced.
- `layouts/application.html.erb:42` and `layouts/in_game.html.erb:21`: the flash `<p>` gets
  `role="status"` for `notice`, and `role="alert"` for `alert`/`error`.

## §3 Styleguide page

- **Route:** inside the existing `namespace :admin`: `get "/styleguide", to: "styleguide#show",
  as: :styleguide`.
- **Controller:** `Admin::StyleguideController < ApplicationController`, `before_action
  :require_authentication!`, `before_action :require_superadmin!` — the same guards as
  `Admin::SettingsController`. A non-superadmin gets what `require_superadmin!` already raises
  (`Authentication::Unauthorized`, `errors.must_be_superadmin`). **No `AdminAudit` call**: it
  is read-only, and `spec/requests/admin_audit_spec.rb` lists only mutating actions.
- **Layout:** the normal `application` layout, so the real header, drawer and locale switcher are
  part of what is measured.
- **Dashboard link:** one link on the admin dashboard.
- **Sections, in order:** type scale (every step with its value); colour tokens as swatches with
  their contrast against `--surface`; buttons (go, neutral, quiet, danger, each also disabled);
  every input type, each normal / disabled / invalid; `.check` checkboxes and radios; file input;
  error summary; every flash type; a `.table--cards` table; tags; the countdown.
- **Invalid specimens are real.** The controller builds an unsaved model instance and calls
  `valid?`, so the invalid specimens are rendered by the real `field_error_proc` and
  `error_messages_for`, not by hand-copied markup. The page always shows the system's true
  behaviour. The model is
  `Game.new(:name => "", :max_team_number => 0, :visibility => "bogus")` after `valid?`: it gives
  errors on text fields (`name`, `description`), a number field (`max_team_number`, 0 fails
  `greater_than: 0`) and a field rendered as a radio group (`visibility`, fails `inclusion`). It
  writes nothing — `uniqueness` on `name` only reads. No `Game` boolean is validated, so there is
  no invalid-checkbox specimen; that case is covered by the field-error proc spec (§4.1) instead.
- **i18n:** three keys in all seven locales — the page title, its heading, and the dashboard link
  label. Specimen strings are verbatim sample content and are not i18n'd: fifty throwaway strings
  translated seven times would be cost without value, and every one would raise under
  `raise_on_missing_translations` if missed.
- **Theme:** whichever is active; the existing header toggle switches it. No both-themes-at-once
  view; §4.2 measures both.

## §4 Guards, verification and rollout

### §4.1 Default RSpec (runs in CI, no browser)

- **`spec/stylesheets/token_discipline_spec.rb`.** Reads `base.css`, `components.css`,
  `layout.css`, `screens.css` (not `tokens.css`; not `calendar.css` or `jquery.autocomplete.css`,
  which A deletes). Fails on:
  - a `font-size` value other than `var(--text-*)` or `inherit`;
  - a `@media` width other than `min-width: 48rem`, `max-width: 47.99rem`, `min-width: 52rem`,
    `min-width: 60rem`;
  - a `z-index` value other than `var(--z-*)`.

  It must be **mutation-tested** before it is trusted: add `font-size: 0.7rem` to a rule, add
  `@media (min-width: 50rem)`, add `z-index: 99` — each must turn it red, and the failure message
  must name the file and line.
- **Field-error proc spec.** For an invalid text field: `aria-invalid`, `aria-describedby`
  matching the span's `id`, the message present and escaped (a message containing `<b>` renders
  as text), and no `field_with_errors` element anywhere. A radio gets no span. A hidden input is
  untouched. A label gets the class and nothing else.
- **Request spec on signup**, submitted invalid: the inline message renders beside the field, and
  the summary still renders.
- **Styleguide access spec:** a superadmin gets 200; a logged-in non-superadmin and a guest get
  the refusal the other admin pages give.

### §4.2 Layout spec (excluded from the default run, needs Chrome)

`spec/layout/styleguide_layout_spec.rb`, the fourth file on the shared
`spec/support/layout_measurement.rb` harness, fetching the page as a superadmin the way
`translate_panel_layout_spec.rb` does. In **both themes** (setting `data-theme` on `<html>`
before measuring), at **390×680 and 1280×800**:

- every form control's computed border contrast is ≥3:1 against the background it actually sits
  on — computed in the page from `getComputedStyle`, not from the token file;
- every `.btn` and `.check` box is ≥44px tall;
- no horizontal overflow on the page;
- every computed `font-size` on the page is one of the scale's values at that viewport.

Like the other three, a missing browser **raises**; it is not skipped.

### §4.3 Manual verification before the PR is marked ready

- `bin/measure-play-screen` passes (the type change touches `.hint-text`).
- Before/after screenshots, both themes, 390 and 1280 wide: play screen, signup with errors,
  dashboard, new game (the number fields and checkboxes), live stats (`.stat-value`), and a file
  table with a generic thumbnail (the 0.68→0.8rem label in a 48px box).
- Full Cucumber, then the inherited-contract run from CLAUDE.md, must give 228/2325 passing as
  before — error messages now appear twice on a page, which no scenario should mind, but this is
  the run that proves it.

### §4.4 Rollout

One PR from `design/foundations`. Commits in reviewable order: tokens → type mapping → form
controls and error proc → styleguide → guards. The PR also carries the `/.superdesign/` line in
`.gitignore` (Superdesign's per-developer context directory). No migration, no new gem, no new
JavaScript. Deploy is a separate, manual dispatch as always.

## Out of scope

- **C — destructive actions behind a confirm.** The play screen's "Сойти с дистанции" is a
  neutral, one-tap `button_to` (`game_passings/show_current_level.html.erb:152`), contradicting
  the 2026-08-06 spec's "danger always behind a confirm". It is deferred because
  `features/game-passing/throw_in_the_towel.feature:21` taps it and expects the results table
  immediately — the Merb authors left the confirm steps commented out, pending their ticket #62.
  Adding a confirm step is a feature-file amendment, which needs the owner's explicit, recorded
  decision. Neither this spec nor any other wave item may do it implicitly.
- Replacing the calendar and autocomplete, and deleting `calendar.css` and the gifs (A).
- Styling translation review (G).
- Redesigning any screen (E, D). This spec changes how existing controls look, not what any
  screen contains.
- Card and panel borders (`--border`), which are decorative and stay as they are.
