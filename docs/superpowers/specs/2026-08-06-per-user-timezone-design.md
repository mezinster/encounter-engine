# Per-user timezone — design

**Date:** 2026-08-06
**Status:** approved, not yet implemented

Every timestamp in this application renders in one instance-wide zone —
`config.time_zone = ENV.fetch("TZ", "UTC")` (`config/application.rb:32`). A game
start shows as `2026-08-06 12:00:00 +0200` to a player in Tbilisi as readily as
to one in Berlin, and only one of them is reading the right number.

This lets each user choose their own zone in their profile. Times render in it.
A user who never sets one sees exactly what they see today.

---

## The binding constraint

Four frozen feature files assert **exact wall-clock strings**:

| File | Asserts | Rendered by |
|---|---|---|
| `features/games/create-game.feature:87` | `2050-03-21 18:01` | `games/show.html.erb:19` |
| `features/games/registration-deadline.feature:21` | `2010-05-27 00:00` | `games/show.html.erb:26` |
| `features/time/time-in-header.feature:15` | `2050-05-20 00:00` | `layouts/_header.html.erb:6` |
| `features/games/hide-left-column-when-in-game.feature:25` | `Личный кабинет 2009-02-02 15:01` | `layouts/_header.html.erb:6` |

`features/**/*.feature` is read-only. So the contract is not "the suite happens
to stay green" — it is:

> **A user with no timezone set must render byte-identically to today.**

Cucumber's users never set one, so they take the instance fallback. Every choice
below is subordinate to that, and it is the first thing to check if anything in
the suite moves.

---

## Global constraints

- Rails 8.0.5.1, Ruby 3.3.12 (rbenv; not on `PATH` in non-login shells — prefix
  commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`).
- Baselines: **234 cucumber scenarios** (2 pre-existing "undefined") / **2362
  steps**, and the RSpec suite green. Measure the RSpec baseline at branch time
  rather than trusting a number in this document — several branches are in
  flight.
- **No `.feature` file may be edited.** Step definitions are editable.
- Every new user-facing string is a `t()` key in all four of
  `config/locales/{ru,en,uk,ka}.yml`, with real Ukrainian and Georgian.
- Hash rockets (`:key => value`); match the surrounding file.
- No asset pipeline: plain CSS in `public/stylesheets/`, no build step.

---

## 1 · The column

```ruby
add_column :users, :timezone, :string
```

**Nullable, no default, no backfill.** NULL means "use the instance default",
which is what makes the compatibility contract above hold without touching a
single existing row.

Deliberately not `null: false` with a default: giving every existing user an
explicit zone would be a silent data write across the whole table to express
the same thing NULL already expresses, and it would make "never chose one"
indistinguishable from "chose the instance zone".

## 2 · `TimeZoneSelection`

A concern mirroring `app/controllers/concerns/locale_selection.rb`, included by
`ApplicationController`:

```ruby
module TimeZoneSelection
  extend ActiveSupport::Concern

  included do
    around_action :use_time_zone
  end

  private

  # Precedence: the signed-in user's stored preference, then the instance
  # default from config.time_zone (which is ENV["TZ"]). Unlike LocaleSelection
  # there is no ?timezone= override -- that exists so an organiser can preview
  # a translation, and there is no equivalent need here.
  def use_time_zone(&block)
    Time.use_zone(current_user_time_zone || Time.zone, &block)
  end

  # Defensive in the same shape as LocaleSelection#current_user_locale: a value
  # that is not a zone Rails knows falls back rather than raising. A stored
  # value can go stale when the tzdata Rails ships changes, and a profile
  # column must never be able to 500 every page the user visits.
  def current_user_time_zone
    return nil unless respond_to?(:current_user, true) && current_user

    ActiveSupport::TimeZone[current_user.timezone.to_s]
  end
end
```

`ActiveSupport::TimeZone[...]` returns `nil` for an unknown name, so the `||`
handles both "not set" and "no longer valid" with one expression.

**`around_action`, not `before_action`.** `Time.use_zone` restores the previous
zone in an ensure block; setting `Time.zone` in a `before_action` would leak the
last request's zone into whatever runs next on that thread.

## 3 · What follows for free, and what does not

`Time.use_zone` changes how ActiveRecord casts every `datetime` column read
inside the block, so these all follow with no further change:

- the seven `l(...)` calls in views (`games/show`, `_header`,
  `game_passings/index`, `admin/audit/index`, `admin/users/index`,
  `admin/users/show`)
- the raw `strftime("%H:%M:%S")` calls in the four log views — those read
  `log.time`, an ActiveRecord attribute, so they follow the zone too
- **form input parsing.** `f.text_field :starts_at` on the game form is parsed
  by ActiveRecord in `Time.zone`, so an author enters their own local time and
  it stores correctly.

What does **not** follow, and is out of scope: nothing computes elapsed
intervals from a wall clock. `Hint#available_in`, `GamePassing#time_at_level`
and `Game#place_of` all subtract two absolute instants, and a difference of two
`Time`s is zone-independent. This is worth stating because it is the obvious
place to fear a regression and there is none.

### The author-surprise this creates

An author who changes their profile timezone will see their own game's start
time change, because it was always stored as an absolute instant and is now
rendered in a different zone. That is correct, and it is still surprising. §5's
zone label is what makes it legible rather than alarming.

## 4 · A bug this fixes

`app/views/games/show.html.erb:89` builds the countdown as:

```erb
var date = new Date(<%= (@game.starts_at + 1).strftime("%Y,%m-1,%d,%H,%M,%S") %>);
```

Those are bare numbers with no zone, and `new Date(y, m, d, h, mi, s)`
interprets them in the **browser's** local zone. The server renders them in the
instance zone. So the countdown is **already wrong today** for every user whose
browser is not set to the instance zone — a player in Tbilisi looking at a
Berlin-hosted game sees a countdown two hours out.

Replace with an absolute instant:

```erb
var date = new Date(<%= (@game.starts_at + 1).to_i * 1000 %>);
```

`Date`'s single-argument form takes milliseconds since the epoch, which is
zone-free by construction. The countdown then reads correctly for everyone
regardless of either zone, and the whole question stops existing for this
element.

This is in scope because per-user timezones make the existing defect **more**
visible, not less: today it is wrong for users outside one zone; afterwards it
would be wrong in a way that appears to contradict the time printed directly
above it on the same page.

## 5 · The zone label

Three timestamps carry an explicit zone; everything else stays bare.

| Shows the zone | Stays bare |
|---|---|
| Game start (`games/show.html.erb:19`) | The header clock |
| Registration deadline (`games/show.html.erb:26`) | Answer logs (`logs/*.html.erb`) |
| The results screen | The audit trail, admin user lists |

A deadline with no zone is precisely where somebody misses a registration by two
hours. A log line, read in context by one operator watching one game, is not.

A helper renders it:

```ruby
  # "2026-08-06 12:00 (GMT+2)". Only for the three timestamps a user acts on --
  # see the spec. Everything else stays bare, because a zone marker on every
  # line of an answer log is noise that makes the three that matter harder to
  # notice, not easier.
  def l_with_zone(time, format:)
    return nil if time.nil?

    "#{l(time, :format => format)} (#{time.in_time_zone(Time.zone).formatted_offset})"
  end
```

`formatted_offset` gives `+02:00`. It is chosen over the zone's abbreviation
(`CEST`) deliberately: abbreviations are ambiguous across regions — `IST` is
three different zones — while an offset is unambiguous to anyone comparing two
times, which is the only thing this label is for.

**This label changes rendered output**, so it must not be applied to a string a
frozen feature asserts. `create-game.feature:87` and
`registration-deadline.feature:21` assert the game-start and deadline strings
with `должен увидеть`, which is a **substring** match — appending ` (+02:00)`
leaves the asserted substring intact and both keep passing. Verify this by
running the suite, not by reasoning about it.

## 6 · The profile form

`app/views/users/edit.html.erb` gains:

```erb
  <div class="field">
    <%= f.label :timezone, t("users.edit.timezone_label") %>
    <%= f.time_zone_select :timezone, nil, :include_blank => t("users.edit.timezone_default") %>
  </div>
```

`include_blank` is what lets a user return to "instance default" after choosing
a zone — without it, the setting is one-way, and NULL stops being reachable
through the UI the moment anyone picks anything.

`:timezone` joins `profile_params` in `UsersController`. The profile page
(`users/index.html.erb`) shows the chosen zone, or the instance default when
unset.

## 7 · Testing

**RSpec:**

- `TimeZoneSelection` — a user with a zone renders times in it; a user with NULL
  renders in the instance default; a user with a **stale or invalid** stored
  value falls back rather than raising.
- The zone leaks nowhere: after a request by a user in one zone, `Time.zone` is
  back to the instance default. This is what `around_action` buys and it should
  be pinned, since a `before_action` version would pass every other test.
- `l_with_zone` renders the offset, and returns nil for a nil time.
- Round-trip: an author in a non-instance zone enters a start time on the game
  form and the stored UTC instant is the one their local time denotes.
- The countdown emits an epoch, not a comma-separated local-time tuple.

**Cucumber:** 234 scenarios / 2362 steps, unchanged, with no `.feature` file
edited. The four exact-time assertions in §"The binding constraint" are the ones
to watch; if any moves, the fallback path is wrong.

**i18n:** two new keys (`users.edit.timezone_label`,
`users.edit.timezone_default`) plus a profile-page label, across four locales.

## 8 · Out of scope

- A per-**game** timezone ("12:00 Tbilisi time"). Considered: for an urban game
  everyone racing is physically in one city, so a shared wall clock is arguably
  the truer model. Rejected for now because the request is explicitly for the
  viewer's own zone, and the two can coexist later — a game zone would be a
  second label, not a replacement.
- Guessing the zone from the browser. It needs JavaScript in a codebase with no
  asset pipeline, and a guess that silently disagrees with a stored value is its
  own class of confusion.
- Any `?timezone=` query override.
- Per-user date **format** (as distinct from zone). `l()` formats come from the
  locale, which users already choose.
