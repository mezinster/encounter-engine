# UI refactor — cross-platform, dark-first

**Status:** approved 2026-08-06

## The problem

The interface is the 2008 Merb original with a Rails port underneath it. `master.css` is 277
lines with **zero media queries**: a fixed 200px sidebar floated left, 12px Arial, `.gif`
background tiles, fixed widths throughout. On a phone it does not adapt at all.

That matters more here than for most products, because of who uses it and where:

- **A player** is outdoors, at night, one-handed, possibly in rain, entering a code while
  walking. They are on a phone by definition — the game happens in a city, not at a desk.
- **An author or operator** is at a laptop under time pressure, watching a running game and
  occasionally reaching in to fix something for a team standing on a street corner.

Neither is served by a desktop-only layout designed before either device existed.

## Scope

Everything: a design system, a responsive shell, a component layer covering all 60 views, and
bespoke attention on the four screens that carry the product — play, live stats and
intervention, dashboard and game page, and the admin console.

**Out of scope:** replacing jQuery 1.3.2 (the hint poller, calendar, autocomplete and thickbox
all depend on it — its own project); any change to application behaviour, routes or
controllers beyond what markup requires; installation documentation; screenshots for the user
manual, which want a settled UI first.

## The constraint everything is built against

`features/**/*.feature` is a frozen contract — 234 scenarios, byte-identical to what the Merb
app passed. **Every visible Russian link and button label must stay exactly as it is.** This
refactor changes markup and CSS; it never changes copy.

Step definitions *are* editable, and only three DOM anchors exist across them:
`table#stats`, `#locale-switcher`, and a block-id helper. Everything else is driven by visible
text, which is not changing.

This is a gift rather than a burden: 234 end-to-end scenarios are a full regression suite for a
60-view rebuild, and most refactors of this size have nothing comparable.

## No build step

The project has no asset pipeline — no propshaft, no sprockets, no `package.json`, no
`app/assets`. Stylesheets are static files under `public/stylesheets/` served directly.

Hand-written modern CSS keeps it that way. Custom properties, Grid, `clamp()` and
`prefers-color-scheme` are all natively supported everywhere the app runs. Adding Tailwind
would mean introducing Node tooling and an ongoing build into a project that currently has
none, in exchange for styling nobody could read directly. Rejected on those grounds.

The single 277-line `master.css` is replaced by several focused files, each linked from the
layouts.

## Theme: dark first, light by choice

Dark is the default identity. A light theme is available and persists.

**Mechanism:** CSS custom properties define every colour. `prefers-color-scheme` sets the
initial value; an explicit toggle overrides it and persists in `localStorage`.

Deliberately **not** a database column, unlike the locale preference. A theme is a
device-and-lighting choice rather than a personal one — the same person wants dark at night in
the street and light at a desk at noon — and `localStorage` also works for anonymous visitors
and needs no migration.

Because both themes are the same tokens with different values, no component is authored twice.
A light theme that is merely inverted looks worse than none, so both are designed, and both are
checked for contrast.

## Colour: ember

Warm dark, continuous in spirit with the existing `#c55` heading red.

| Role | Value |
|---|---|
| Go | `#fbbf24` amber |
| Time | `#fb923c` orange |
| Danger | `#dc5555` red |
| Surface | `#12100e` / `#1c1917` |

**Ember's known weakness, and how it is handled.** Amber, orange and red are neighbours on the
wheel, so *time* and *danger* — the two meanings least safe to confuse during a live game — are
the hardest to tell apart at arm's length in bad light. Hue alone cannot carry the distinction
here, so treatment does:

- **Go** — solid amber fill, dark text. The only filled warm button on any screen.
- **Time** — never filled. Amber numerals on the surface colour, tabular figures. A countdown
  is information, not an action, and must never look pressable.
- **Danger** — red, always outlined rather than filled, always behind a confirm step, and never
  placed adjacent to a go button. Withdraw, end game, delete, quit the race.

The three are then distinguishable by shape even when the colours blur.

## Navigation

**Drawer.** Hamburger on mobile opening the existing menu; a persistent sidebar from tablet
width up.

Chosen over a bottom tab bar despite the bottom bar's better one-handed ergonomics, because the
menu carries up to nine items once the admin section appears, and a bar would demote half of
them to a submenu. The drawer holds all of them at one depth.

**The play screen is the exception** and keeps almost no chrome at all. A player mid-task needs
the task, the code field and the countdown; a menu is in the way. This is what the existing
`in_game` layout is for — it already renders without the sidebar, it has simply never been
styled as a focused screen.

## The play screen

A pinned bottom bar carries the three live things: **the code field, the countdown, and the
newest hint**. Task text and older hints scroll above it.

The reasoning: task text can run to a paragraph, and hints accumulate below it as timers fire —
so the code field, the thing the player came to use, gets pushed further down the page exactly
as the game gets more stressful. Pinning it means the distance to the input never grows.

The pinned hint clamps to two lines; its full text is always present in the scrolling list
above, so nothing is lost to truncation.

**The input disables autocapitalise, autocorrect and spellcheck**, and sets an appropriate
`inputmode`. A phone helpfully capitalising a code is a real way to lose a game. Server-side
matching is already case- and whitespace-insensitive (`strip.upcase` on both sides), so this is
belt and braces rather than the only defence.

**When the game is paused the banner takes over the pinned bar entirely.** Codes are refused
while paused, so leaving a field that looks usable would be a lie.

Tap targets are 44px minimum throughout.

## Live stats and intervention

The list becomes **read-only and scannable** — team, task, time at task, status. Tapping a team
opens a **detail panel** carrying its full state and every action in context.

This replaces a table with a `<select>` and two buttons on every row. Two problems with that
arrangement:

1. **It does not fit a phone.** Six columns with controls in each row are unusable at 390px,
   and the operator may be outdoors themselves when a team calls.
2. **Every row is armed.** Move, reinstate and reset sit inches apart, on every team,
   permanently — and they change a live game under players' feet. The only thing between a
   tired 2am misclick and a team being moved to another task is aim.

The panel fixes both: one place to act, showing what is about to change, identical on phone and
laptop.

**The desktop view stays a real `<table id="stats">`.** Below the breakpoint its rows become
cards. Keeping the table at width means the `tableish('table#stats tr', 'td,th')` step
definition never has to change — one less thing to get wrong against a frozen suite.

## Everything else

**Components** carry the rest: buttons, forms, tables, flash messages, cards, panels, the
language switcher. Tables get one shared responsive treatment — real table at width, stacked
cards below — which is what lifts the remaining fifty-odd views without designing each one.

**Dashboard, game page and the admin console** get layout attention on top of the component
baseline. These are composition problems rather than new patterns.

## Testing

- **All 234 cucumber scenarios stay green at every step.** This is the acceptance gate, and it
  is what makes a refactor of this size safe. Any movement is a regression, never an expected
  cost.
- **`bundle exec rspec` stays green.** View specs render real templates and will catch a broken
  partial.
- No visible Russian copy changes anywhere.
- Both themes are checked for contrast against WCAG AA on body text and interactive elements.
- The play screen and operator screen are checked at 390px, 768px and 1280px.

## Risks

1. **The drawer is new interactive markup on every page.** A broken drawer is a broken site,
   including the login screen. It must degrade to a visible menu without JavaScript.
2. **The pinned bar and mobile keyboards interact badly** on some browsers — the keyboard can
   cover a fixed element, or the viewport can resize under it. This needs real-device
   verification rather than emulator confidence.
3. **The light theme is half the work and risks getting a fraction of the attention.** It **is**
   in scope, not a stretch goal: every component is designed and contrast-checked in both
   themes, and no task is complete with one of them unexamined. A light mode nobody really
   looked at is worse than not shipping one, so if it has to be cut, it is cut deliberately and
   the toggle goes with it — never left half-done.
4. **Sixty views is a lot of surface.** The component layer is what keeps this tractable — if
   individual views start needing bespoke CSS, that is the signal the system is wrong, not that
   the view is special.
