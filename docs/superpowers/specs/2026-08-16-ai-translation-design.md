# AI translation of game content — encounter-engine

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-16
**Related:** builds entirely on the multilingual content subsystem already in the tree —
`ContentTranslation`, `TranslatableContent`, `Game#missing_translations`, and the language-tab
authoring UI. This design adds no new concept to that model; it automates filling it.

## Goal

Let a **superadmin** translate a game's author-written content into any registered locale using the
Claude API, review what the model produced, and accept it — after which the stored translation is
byte-identical to one typed by hand, and the game cannot tell the difference.

In scope: the four models that declare translatable fields — `Game` (`name`, `description`),
`Level` (`name`, `text`), `Hint` (`text`), `Option` (`text`). `Question::TRANSLATABLE_FIELDS` is
empty and stays empty. `Answer` has no translatable fields and must never acquire any.

## Decisions already taken

| Decision | Choice | Why |
|---|---|---|
| Execution | Persisted run + background `Thread` | No ActiveJob backend exists (`:inline` in all three environments) and the host has 1 vCPU / ~1.1 GB spare. A DB-backed run needs no gem, no Redis, no second container, and survives a browser close |
| Write path | **Staged.** Proposals reviewed before they land | Nothing reaches `content_translations` without a human action, so the publish gate can never be satisfied by text nobody looked at |
| Existing translations | Never touched | The work-list is missing fields only. There is no overwrite path in v1 |
| Secret | `ANTHROPIC_API_KEY` env var via Kamal secret | Kamal 2.12 ships no Azure Key Vault adapter (see below). This is the pattern the other four secrets already use, and it keeps a billable credential out of Postgres and out of every wal-g backup |
| Call shape | One call per **level subtree** | Game content is referential; a hint points back at its level's puzzle. Also the cheapest shape per unit of translated text (see §3) |
| Loop order | Levels outer, **locales inner** | Makes the source content a cached prefix reused across every target language. Reversing the loops makes every call a cache miss |
| Model | `Setting`, allow-listed, default `claude-opus-5` | The hard locales here need structural rewriting, not word substitution — but the superadmin owns the cost/quality call per game |
| Effort | `low`, thinking left **on** | Largest cost lever after model choice. Not `disabled` — see §3 |
| Progress UI | `<meta http-equiv="refresh">` | Needs no JavaScript. Adopting Turbo is an explicit non-goal — see §9 |
| Access | `require_superadmin!` | Not `ensure_author`, which is a marked security chokepoint that already admits superadmins to author actions |

## Why not Azure Key Vault

The original instinct was to put the API token in Azure Key Vault. Checked rather than assumed, and
the answer is no — for a recordable reason:

* **There is no Key Vault in this deployment.** Every secret flows GitHub Actions secret →
  `.kamal/secrets` (which references variable *names*, never values) → container env.
* **Kamal 2.12 ships no Azure adapter.** `lib/kamal/secrets/adapters/` contains
  `aws_secrets_manager`, `gcp_secret_manager`, `one_password`, `last_pass`, `bitwarden`,
  `bitwarden_secrets_manager`, `doppler`, `enpass`, `passbolt` — and nothing for Azure. Wiring Key
  Vault in means writing a custom adapter, or an entrypoint shim that shells out to `az` using the
  VM's managed identity.

Either route adds an auth path, a package to the image, a role assignment, and a **new boot-time
failure mode for the whole application** — for one key. The rejected middle option, a `Setting` row
editable at `/admin/settings`, buys deploy-free rotation at the cost of putting a live billable
credential in Postgres and therefore in every offsite backup. If Key Vault is revisited later, it
should be revisited for *all* the secrets at once, not for this one.

## Out of scope, deliberately

* **Turbo / rails-ujs.** See §9.
* **Staleness detection.** Editing a level's primary-language text after a translation was accepted
  does not flag the now-stale translation. Real gap, separate feature.
* **Overwriting existing translations.** v1 fills gaps only.
* **The Batches API.** Plausibly a further discount for exactly this async shape, but the current
  terms and their interaction with prompt caching need verifying before anything is designed around
  them. Follow-up, not a guess.
* **Translating `Answer`.** Never. Codes are codes.

---

## §1 Data model

Two new tables. No column on any existing table changes.

### `translation_runs`

One row per "Translate" press.

| Column | Type | Notes |
|---|---|---|
| `game_id` | integer | |
| `actor_id` | integer | the superadmin who started it |
| `model` | string | resolved from the `Setting` **at start time**, then frozen on the row |
| `state` | string | `pending` / `running` / `succeeded` / `failed` / `cancelled` |
| `target_locales` | string | comma-joined, the same convention as `games.available_locales` |
| `fields_total` | integer | |
| `fields_done` | integer | |
| `fields_failed` | integer | |
| `estimated_input_tokens` | integer | from the pre-flight `count_tokens` |
| `input_tokens` | integer | accumulated actual spend |
| `output_tokens` | integer | |
| `cache_read_tokens` | integer | proves the caching in §3 is actually hitting |
| `error_message` | text | |
| `started_at`, `finished_at` | datetime | |

`target_locales` is a comma-joined string rather than a serialised column for the same reason
`Game#available_locale_list` is (`app/models/game.rb:430-432`): it is a short list of ASCII locale
codes and it has to be readable in a database console during an incident.

`model` is frozen on the run rather than read live, so changing the `Setting` mid-run cannot produce
a run whose proposals came from two different models with no way to tell which.

### `translation_proposals`

One row per translated field.

| Column | Type | Notes |
|---|---|---|
| `translation_run_id` | integer | |
| `translatable_type`, `translatable_id` | string, integer | polymorphic, same shape as `content_translations` |
| `field` | string | |
| `locale` | string | |
| `source_text` | text | **snapshotted** at translation time |
| `proposed_text` | text | |
| `flags` | string | comma-joined check names — see §5 |
| `state` | string | `pending` / `accepted` / `rejected` |
| `reviewed_by_id` | integer | |
| `reviewed_at` | datetime | |

**Unique index on `(translation_run_id, translatable_type, translatable_id, field, locale)`.** This
index is not merely hygiene — it is the mechanism that makes a killed run resumable instead of
duplicating work (§4).

`source_text` is snapshotted for the same reason `AdminAction#target_label` snapshots its target's
name (`app/models/admin_action.rb:17-27`): if the level text is later edited, a proposal that only
pointed at the record would silently start claiming to be a translation of text that no longer
exists. The snapshot is what makes the table an audit trail rather than a cache.

## §2 Building the work-list

`Game#missing_translations` (`app/models/game.rb:445`) is almost the work-list, but line 446
hard-wires it to `available_locale_list`. A superadmin needs to translate *into* a locale before
declaring it — translate, then tick the box, then the publish gate passes — so the field-walking is
extracted:

```ruby
# New. Takes any locale, declared or not.
def missing_translated_fields_in(locale)
  translatable_records.flat_map do |record|
    record.class::TRANSLATABLE_FIELDS.map do |field|
      next if record.translated?(field, locale)
      MissingTranslation.new(record, field, locale, label_for(record, field))
    end.compact
  end
end

# Unchanged behaviour, now expressed in terms of the above.
def missing_translations
  non_primary = self.available_locale_list - [self.primary_locale.to_s]
  return [] if non_primary.empty?

  non_primary.flat_map { |locale| missing_translated_fields_in(locale) }
end
```

Pure extraction: every existing `missing_translations` spec stays green and the publish gate
(`declared_locales_are_translated_before_publication`) is untouched.

The runner rejects a target locale equal to `primary_locale` up front. The primary language lives in
the model's own columns; `TranslatableContent#persist_pending_translations` already skips it
(`app/models/concerns/translatable_content.rb:110-111`), so writing it would silently no-op.

## §3 The Claude integration

`gem "anthropic"`, wrapped behind exactly one seam: `Translation::Client`. Nothing else in the
application references the SDK, which is what lets every spec run without a network.

### Request shape

One call per level subtree — the level's `name` and `text`, all its hints (with their `delay`, so
"the first hint" reads correctly), and every question's options. The game's own `name` and
`description` are one additional small call.

```ruby
client.messages.create(
  model: run.model,
  max_tokens: 8_000,
  output_config: {
    effort: "low",
    format: { type: "json_schema", schema: KEYED_FIELDS_SCHEMA }
  },
  system_: [
    { type: "text", text: TRANSLATION_RULES },
    { type: "text", text: source_block,
      cache_control: { type: "ephemeral" } }
  ],
  messages: [{ role: "user", content: "Translate the above into #{language_name}." }]
)
```

Structured output returns a keyed object (`{"level.name": …, "hint.17.text": …, "option.94.text": …}`)
validated at the tool-call layer, so a malformed response is retried by the API rather than by a
parse-failure loop that burns a second full call.

### Why `effort: "low"` and why thinking stays on

Output tokens are priced 5× input, and the translation itself *is* output. On top of that, Claude
Opus 5 runs adaptive thinking on by default at `high` effort — for a translation task that readily
produces more thinking tokens than translated text, billed at the same rate. Left at defaults,
thinking would be the largest line on the bill, spent deliberating over sentences that need no
deliberation.

`thinking: {type: "disabled"}` is **not** the answer. On Claude Opus 5 disabled thinking has a
documented tendency to leak `<thinking>` tags into the visible response — which here would land
verbatim inside a game level. Low effort with thinking on is both cheaper in practice and safe.

### Why the loop runs levels-outer, locales-inner

Prompt caching is a strict **prefix** match, rendered `tools` → `system` → `messages`. The design
puts the reusable part first and the volatile part last:

```
[ system: translation rules ]        stable across the entire run
[ system: this level's source ]      stable across all target LOCALES   ← cache breakpoint
[ user: "translate into Polish" ]    the only varying part
```

So the runner translates level 1 into every target language, then moves to level 2. The first locale
pays a cache write (1.25×); the rest read the same prefix at 0.1×. Looping the other way — every
level into Polish, then every level into Turkish — means that by the time level 1 comes round again
the prefix has been replaced eleven times, and **every call is a miss**.

Two supporting constraints:

* **The per-level locale calls must be sequential.** A cache entry only becomes readable once the
  first response begins streaming; firing all four at once means all four pay full price. Sequential
  costs nothing here — the work is in a background thread with nobody waiting on it.
* **Claude Opus 5's minimum cacheable prefix is 512 tokens** (it was 1024 on Opus 4.8). A bare
  system prompt may not clear that floor; system prompt *plus* one level's source comfortably does.
  This is a second reason the source content belongs inside the cached prefix rather than after it.

This also settles why "one call per field" is the expensive option rather than the cheap one: it
re-sends the rules for every one of ~300 calls, and each call is far too short to reach the cache
floor, so nothing ever caches at all.

### The rule that matters most is about codes, not language

`Answer` correctly has no translatable fields, so answers themselves are never sent to the API. But
a level's `text` or a hint can quote a code the player must type, a coordinate, a house number, a
time. Translating one silently breaks the game for every team.

`TRANSLATION_RULES` therefore states that any digit sequence, Latin-script token, or URL is copied
verbatim. §5 verifies this mechanically rather than trusting it.

## §4 The runner

```
POST /games/:id/translation_runs
  → require_superadmin!
  → reject: key absent, target == primary_locale, a run already active for this game
  → pre-flight count_tokens → confirmation screen showing a measured estimate
  → TranslationRun.create!(state: :pending)
  → Thread.new { Rails.application.executor.wrap { Translation::Runner.new(run).call } }
  → redirect to the run page
```

`Rails.application.executor.wrap` is load-bearing, not ceremony. A bare `Thread` in Rails leaks a
connection from the pool and does not participate in code reloading. On a host with ~1.1 GB spare,
leaking database connections is not a theoretical concern.

Per level, per locale: one API call, then proposals written and counters incremented **in one
transaction**. Usage figures are accumulated onto the run from each response, including
`cache_read_input_tokens` — so the run page shows whether the caching in §3 is actually hitting,
rather than the design merely asserting that it does.

**Resumability** falls out of the unique index: on restart the runner skips any
`(record, field, locale)` that already has a proposal for this run. A deploy mid-run costs the level
in flight, not the run.

**Cancellation is cooperative** — the runner re-reads `run.state` between calls and stops on
`cancelled`.

**Stale runs.** A sweep marks runs `running` with no progress for ~15 minutes as `failed`, so a
thread killed by a deploy cannot leave a game permanently unable to start a new run.

## §5 UI surfaces

All plain forms. No JavaScript is required anywhere in this feature.

### Trigger

`app/views/games/edit.html.erb:47-63` already renders one row per registered locale with a checkbox.
Each **non-primary** row gains a `button_to "Translate"`. Above the list, one
`link_to "Translate multiple…"` opens a page carrying the same locale list as checkboxes plus a Run
button. Both post to the same endpoint — "translate one" is simply a run with a single target.

Both are rendered only when the actor is a superadmin **and** `ANTHROPIC_API_KEY` is present.

### Run page

`<meta http-equiv="refresh" content="3">` in the head while the run is `running`, absent once it
reaches a terminal state. Shows `fields_done / fields_total`, the model, accumulated token counts, a
Cancel button, and on completion a link to review.

### Review page

Grouped by level; source text beside proposed text; per-row Accept / Reject / Edit-then-accept; plus
**Accept all unflagged**.

The flags are what make this screen useful to a reviewer who does not read the target language. Each
proposal is checked on creation:

| Flag | Catches |
|---|---|
| `empty` | blank or whitespace-only output |
| `identical` | output byte-identical to source |
| `lost_digits` | a digit sequence present in the source is absent from the proposal |
| `lost_latin` | a Latin-script token or URL present in the source is absent |
| `length` | under 40% or over 250% of the source's length |

`identical` deserves its place: it is exactly the failure the `translation_draft` comment documents
at `app/models/concerns/translatable_content.rb:49-62`, where the authoring form pre-filled an empty
English tab with Russian text and saving unchanged persisted **Russian labelled as English** —
satisfying the publish gate through the very form built to prevent it. An automated translator that
silently echoes its input reproduces that at scale.

None of the five checks requires the reviewer to know the target language, and between them they
cover the structural failures that would otherwise pass review unnoticed.

### Accepting

Acceptance calls `record.translations_attributes = { locale => { field => text } }` and saves — the
identical path `GamesController`, `LevelsController`, `HintsController` and `OptionsController` use
for a hand-typed translation. The resulting `content_translations` row is byte-identical to one a
human produced; provenance lives only in `translation_proposals`, which the game never reads.

One consequence worth naming: `Game#primary_locale_is_settled` locks `primary_locale` once *any*
`content_translations` row exists. Because a proposal is not a translation, generating proposals
does not lock it — only accepting does. That is the correct behaviour and it comes free from staging.

## §6 Access control, audit, cost guards

* **`require_superadmin!`** (`app/controllers/concerns/security_filters.rb:37`) on every action.
  Deliberately not `ensure_author`, whose comment at line 26 marks it a security chokepoint that
  already admits superadmins to author actions and warns against widening it.
* **Audit** via explicit `record_admin_action` calls — never an `around_action`, for the reason
  `app/controllers/concerns/admin_audit.rb` gives. Actions recorded: `translation_run_started`,
  `translation_run_cancelled`, `translation_proposals_accepted`.
  `spec/requests/admin_audit_spec.rb` enumerates the audited set and is updated deliberately.
* **Cost guards:** the pre-flight `count_tokens` confirmation (free and exact — no guessing); one
  active run per game; a `translation_max_fields_per_run` `Setting` as a blast-radius cap.
* **`translation_model`** is a `Setting` with an **allow-list**, not free text — the same shape as
  `allowed_extensions`, which a superadmin can narrow but not widen into something dangerous.
* With `ANTHROPIC_API_KEY` unset the feature is entirely absent: no buttons rendered, no run may be
  created. Development and CI need no key.

## §7 Failure handling

Failures are scoped to a level, never to a run. An API error increments `fields_failed` by that
level's field count and the runner continues to the next level; the run page offers Retry.

There is deliberately **no `failed` proposal state**. A field that failed simply has no proposal row,
so the resumability rule in §4 — skip anything that already has a proposal for this run — re-runs
exactly the failed fields and nothing else. Retry resets `fields_failed` to zero and re-enters the
runner; the two mechanisms are the same mechanism, which is why there is only one of them.

Rate limits are retried by the SDK with backoff before any of this is reached.

`stop_reason` is checked **before** `content` is read. Game text is benign, but code that indexes
`content[0]` unconditionally breaks on a `refusal`, and production is a bad place to discover it.

## §8 Testing

Every spec stubs `Translation::Client`. No spec touches the network.

* **Work-list extraction** — existing `missing_translations` specs stay green; new examples cover
  the undeclared-locale case and the primary-locale rejection.
* **The five flag checks** — mutation-tested: each check gets an example that fails if the check is
  removed. `identical` especially, since it guards a failure this codebase has already had once.
* **Runner** — state transitions; resumability (kill mid-run, restart, assert no duplicate
  proposals); cooperative cancellation; the stale-run sweep.
* **Acceptance** — asserts the written `ContentTranslation` is indistinguishable from a
  form-written one, and that `translations_complete?` flips.
* **Authorization** — every action returns 403 for an author who is not a superadmin.
* **i18n** — every new string in **all seven** locales. `raise_on_missing_translations` is on in
  test, so a missing key is a red build rather than a `translation missing:` in the UI.

**No `.feature` file.** This is admin machinery with no pre-port ancestor; the inherited contract
stays at 228 scenarios / 2325 steps, untouched. RSpec request specs cover it better than Gherkin
would.

## §9 Explicit non-goal: Turbo and rails-ujs

Progress polling here is a `<meta http-equiv="refresh">` that is removed when the run finishes.
Adopting Turbo was considered and rejected, and the reasoning is recorded so it is not rediscovered:

* **There is no asset pipeline.** `app/assets/` is empty; no sprockets, propshaft, importmap or
  jsbundling appears in the `Gemfile` or `config/application.rb`. Every script is a hand-written
  `<script src="/javascripts/…">` served from `public/`, including jQuery **1.3.2**. Adopting Turbo
  means adopting a pipeline or vendoring a UMD bundle by hand.
* **Neither suite would see it.** Capybara runs on rack-test, which executes no JavaScript. Turbo
  Drive intercepting every link and form submit would be invisible to all 238 Cucumber scenarios —
  green whether it worked or was catastrophically broken. That is the exact blindness recorded twice
  already in `CLAUDE.md`: the play screen that shipped broken, and the countdown examples that
  reported pending for a fortnight. The prerequisite for adopting Turbo is a JS-capable test driver,
  not a translation button.
* **rails-ujs would endanger a frozen file.** `GET /logout` is a deliberate wart precisely because
  there is no rails-ujs, and `features/authentication/logout.feature:9` drives logout with a raw
  `GET`. Adding rails-ujs makes "fix that wart properly" look correct, and it would break a file
  nobody is authorised to edit.

If Turbo is wanted, it deserves its own design, starting with the test driver.
