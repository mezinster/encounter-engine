# Per-game multilingual content — design

**Status:** approved 2026-08-05
**Supersedes nothing.** Extends the i18n work delivered with the Merb → Rails 8 port, which
translated platform chrome only and deliberately left author-written game content untranslated.

## The problem

The port established a clean split: platform chrome goes through `t()`/`l()`, while game titles,
level descriptions, hints and question text are author-written free text rendered verbatim. That
split was correct — running author content through `t()` would print `translation missing:` into a
live game — but it left the platform monolingual in the only dimension that matters to players.

Today:

- There is no `games.available_locales`. The only locale column in the schema is on `users`. An
  author cannot declare which languages a game offers.
- `games.name`, `games.description`, `levels.name`, `levels.text`, `hints.text` and
  `questions.questions` are single columns holding whatever the author typed.
- There is no authoring UI for entering task text per language.
- There is no fallback policy for a Georgian-speaking player reaching a level written only in
  Russian.
- The instance default locale is still `:ru`.

## Scenario being supported

**One game, many languages, simultaneously.** A Georgian team and a Russian team race through the
same levels, each reading the task in their own language. This is the demanding case: it requires
per-language storage for every author-written field, an authoring UI that surfaces gaps before the
game starts, and a defined outcome for the moment a player meets untranslated content.

This is a *race*. A team that reaches a level it cannot read does not suffer a display glitch — it
loses the leg. Translation completeness is therefore a fairness property, enforced before a game
starts, not a rendering concern handled at the last moment.

## Decisions

| Question | Decision |
|---|---|
| Playing scenario | One game, many languages at once |
| Answer codes | **Shared** across languages — no per-locale answer sets |
| Missing translation | **Blocked at publish**; labelled fallback only as a runtime safety net |
| Storage | **Side table**; existing columns keep the primary-language text |
| Player's content language | User's locale by default, **overridable per game** |
| Authoring UI | **Language tabs** on the existing forms |
| Default locale flip | Ships **separately**, after this work |

### Answer codes stay shared

`Question has_many :answers`, and `Question#matches_any_answer` compares case-insensitively against
every stored value. An author expecting different renderings registers each as an accepted answer —
the mechanism already exists and needs no schema change.

Answer codes are not really content: they are what is physically at the location. A player still has
to stand in front of the plaque. A Russian speaker who typed the Georgian variant would have had to
be there to know it, so accepting all variants leaks nothing.

The cost is that nothing prompts an author to register every variant. A task reading "enter the
street name" needs each language's rendering entered by hand. Help text beside the answers field
must say so.

## Data model

All changes are additive. **No existing row is updated by the migration.**

```ruby
# games
t.string :primary_locale,    default: "ru", null: false   # existing content is Russian
t.string :available_locales, default: "ru", null: false   # comma-separated: "ru,en,ka"
                                                          # ALWAYS includes primary_locale

create_table :content_translations do |t|
  t.string  :translatable_type, null: false   # "Game", "Level", "Hint", "Question"
  t.integer :translatable_id,   null: false
  t.string  :field,             null: false   # "text", "name", "description", "questions"
  t.string  :locale,            null: false
  t.text    :value
  t.timestamps
end
add_index :content_translations,
  %i[translatable_type translatable_id field locale], unique: true

create_table :game_locale_preferences do |t|
  t.references :user, null: false
  t.references :game, null: false
  t.string     :locale, null: false
  t.timestamps
end
add_index :game_locale_preferences, %i[user_id game_id], unique: true
```

### Why the existing columns keep the primary text

`content_translations` holds **only non-primary languages**. `games.name`, `levels.text` and the
rest continue to hold exactly what they hold today.

This is the decision the rest of the design rests on:

- Existing games are byte-identical, so the 234 read-only Cucumber scenarios keep passing without a
  single `.feature` file being touched.
- There is no destructive backfill to get wrong against a live database.
- A game that never declares a second locale takes no join and no new code path.

The acknowledged cost: the primary language lives somewhere different from the others, so
`translated` carries a branch, and sorting a games list by translated name needs a `LEFT JOIN` with
a `COALESCE` back to the column. This is a deliberate trade against rewriting a production
database's content columns.

## Reading path

```ruby
# app/models/concerns/translatable_content.rb
module TranslatableContent
  extend ActiveSupport::Concern

  included { has_many :content_translations, as: :translatable, dependent: :destroy }

  # Falls back to the column rather than returning nil: a gap degrades to readable
  # text in another language, never to a blank task in the middle of a race.
  def translated(field, locale)
    return self[field] if locale.to_s == translation_game.primary_locale
    content_translations.find { |t| t.field == field.to_s && t.locale == locale.to_s }
                        &.value.presence || self[field]
  end

  def translated?(field, locale)
    return self[field].present? if locale.to_s == translation_game.primary_locale
    content_translations.any? { |t| t.field == field.to_s && t.locale == locale.to_s && t.value.present? }
  end
end
```

`translated?` answers "is there usable text for this locale", not "does a row exist". A blank
primary column is therefore *not* translated — otherwise the publish gate would happily pass a game
whose author left a task description empty in the primary language, which is precisely the state it
exists to catch.

`available_locales` always contains `primary_locale`; a validation enforces it, and the authoring UI
renders the primary language's tab as permanently ticked and non-removable. Without that
invariant, an author could untick their own primary language and produce a game with content the
locale resolution can reach only through fallback.

Per-model wiring is one method: `Level#translation_game` → `game`; `Hint` and `Question` →
`level.game`; `Game` → `self`.

### Locale precedence

Resolved in one place — a `ContentLocaleSelection` controller concern beside the existing
`LocaleSelection`:

```
per-game override  →  user's locale (already honours ?locale=)  →  game.primary_locale
```

A candidate not present in `game.available_locales` falls through to `primary_locale`. A
Georgian-speaking user browsing a Russian-only game therefore reads Russian content inside Georgian
chrome. Content locale and chrome locale are independent by design.

### The fallback marker

Because publishing is blocked on completeness, a runtime gap can only arise from content added
after a game has started. The level page checks once — `level.missing_translations(content_locale)`
— and renders a single notice through `t()`, since the notice is chrome, not author content. One
notice per page, not one per field.

Mailers keep using the recipient's `users.locale` and do not consult game content locales; their
bodies are platform chrome and already translated.

### N+1 obligation

`translated` searches a loaded association, so it is only safe when controllers preload with
`includes(:content_translations)`. A level page renders the level, its hints and its questions.
Every controller action rendering game content must preload, and a query-count test must enforce it
— this behaves acceptably in development with three hints and badly in a live game with a full field
of teams.

## Authoring

Hints and questions have their own forms (`app/views/hints/_form.html.erb`,
`app/views/questions/new.html.erb`), edited on nested pages rather than inside the level form. The
tab strip therefore lands on **four** forms: game, level, hint, question.

Each form gains a strip built from `game.available_locales`. The active tab comes from
`params[:locale]`, defaulting to `primary_locale`. Fields submit as `level[translations][ka][text]`,
handled by a `translations_attributes=` writer on the concern. Each tab shows `✓` or `⚠ N missing`
for that form's own fields.

### `primary_locale` is immutable once translations exist

It is settable only while the game is a draft with no translations. Changing it later would silently
reinterpret which stored text is primary: the columns would still hold Russian while the game
claimed English, and every fallback would then serve the wrong language. Forbidding this is far
cheaper than migrating it.

An author who picks wrong must recreate the game. The alternative — a migration that moves column
text into the side table and promotes a translation — is a larger feature and can be added if anyone
asks for it.

### Removing a locale is non-destructive

Removing a locale from `available_locales` keeps its `content_translations` rows and merely stops
offering the language. Deleting an author's translation work because they unticked a box is not a
convenience.

## The publish gate

`Game#missing_translations` returns structured entries — model, id, field, locale, human label, edit
path — rather than a boolean. A validation blocks leaving draft and blocks `start_game`.

The error renders those entries as deep links (`edit_level_path(level, locale: "ka")`), each opening
the right form on the right tab.

This is the deliberate compensation for choosing tabs over a whole-game translation matrix. Tabs
show gaps one level at a time, which alone would force an author with fourteen levels to click
through fourteen forms to learn what is missing. Making the gate *enumerate* the gaps produces the
"what is left" view exactly where it is needed, and nowhere else.

## The `:ru` → `:en` flip

Ships **separately, after this work**. It is one env var and one line of code, independently
reversible, and bundling a visible change to every existing user's chrome into a large feature
release makes both harder to judge.

```ruby
# config/application.rb — currently hardcoded
config.i18n.fallbacks = [:ru]   →   config.i18n.fallbacks = [I18n.default_locale]
```

```yaml
# config/deploy.yml — production only
DEFAULT_LOCALE: en
```

`config/environments/production.rb` already reads `ENV.fetch("DEFAULT_LOCALE", "ru")`, so the
instance default is a deployment knob rather than a code change. Development and test stay `:ru`,
which is what keeps the read-only Cucumber scenarios green — they assert Russian chrome and would
fail wholesale under an English default.

The fallback line matters more than it appears. `uk` and `ka` hold four keys each, so on an
English-defaulting instance a Ukrainian user would currently receive **Russian** chrome. Tying
fallbacks to the default locale fixes that without touching either locale file.

## Testing

RSpec carries this work. The `.feature` files are a preserved artifact of the Merb port; growing
them blurs which scenarios are the port's contract and which are new. The port's own history also
showed that suite passing green while no login form could be filled at all.

- **Model specs** for `TranslatableContent`: primary-locale reads bypass the table, missing
  translations fall back to the column, and `translated?` distinguishes absent from present-but-blank.
- **`Game#missing_translations`**: its entries are simultaneously the publish gate and the author's
  to-do list, so they must be correct, not merely non-empty.
- **Request specs** for the three-step precedence, the fallback notice, and the per-game override.
- **A query-count assertion** on the level page, so a controller that forgets
  `includes(:content_translations)` fails the build rather than the event.

Existing gates must stay green: **426 RSpec examples, 234 Cucumber scenarios**, no `.feature` file
modified.

## Rollout

The migration adds columns with defaults and two tables, and updates no rows. Every existing game
becomes a single-locale `ru` game behaving exactly as it does today. It runs through the container
entrypoint's `db:prepare` on the next deploy.

## Risks

1. **N+1 under load** — the real operational risk. Mitigated by the query-count test, which must be
   written before the controllers are considered done.
2. **Shared answer codes depend on author awareness** — the model accepts multiple values, but
   nothing prompts an author to enter each language's rendering. Needs help text beside the answers
   field.
3. **`primary_locale` immutability will occasionally frustrate** — accepted deliberately; the
   migration path can be built later if it is actually requested.

## Out of scope

- Per-language answer codes.
- A whole-game translation matrix screen.
- Machine translation of any kind.
- Translating `teams.name` or `users.nickname`, which are user-authored but not game content.
- The default-locale flip itself, which ships as its own change.
