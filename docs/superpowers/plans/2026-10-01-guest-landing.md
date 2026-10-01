# Guest Landing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub home page with a players-first landing (hero, upcoming games, how-to-play timeline, organizers panel) that signed-in players see without the explanation and with their team's status per game.

**Architecture:** A plain query object (`UpcomingGames`) classifies visible games into running / next / scheduled / gated with a 4-row cap in two queries; a small helper (`IndexHelper`) turns a game plus the viewer's team entry into one status tag; the view is split into five partials under `app/views/index/`; the captain's actions reuse the dashboard's existing `shared/_game_entry_controls`, which gains `.btn` classes. All copy goes through `t()` in seven locales.

**Two deliberate deviations from the spec, ruled here:** (1) the team counts are not carried on `UpcomingGames`'s value object (spec §1) — the view calls the existing, per-request-memoised `game_team_counts(games)` helper, exactly as the games list does, so the page and `/games` cannot disagree and the query count stays constant either way; (2) dates go through `l_with_zone`, as the spec says, which appends the viewer's offset — «12 октября, 21:00 (+06:00)», not the drafts' bare «12 октября, 21:00». The offset is this app's established convention for every displayed time; dropping it here alone would make the home page the one place a time is ambiguous.

**Tech Stack:** Rails 8, ERB, vanilla CSS, RSpec (service, helper, request, plain), the `spec/support/layout_measurement.rb` harness.

**Spec:** `docs/superpowers/specs/2026-10-01-guest-landing-design.md` — read it alongside this plan. Visual reference: Superdesign drafts `7eaa33ad-…` (guest, B v2) and `659ef6ac-…` (signed-in), both rendered copies at `.superdesign/tmp/signed-in.html` and via `npx --yes @superdesign/cli@latest get-design --draft-id <id> --output <file>` (needs Node 22: `export PATH="$HOME/.nvm/versions/node/v22.23.1/bin:$PATH"`). The spec wins where they differ.

## Global Constraints

- Work only in the worktree `.claude/worktrees/guest-landing`, branch `design/guest-landing`.
- Prefix every command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH" &&`.
- Every RSpec run uses an isolated DB: `export RAILS_ENV=test DATABASE_URL="sqlite3:/tmp/claude-1000/-home-mezinster-encounter-engine/aebf2b26-bc2a-403f-b757-11277eb435e8/scratchpad/gl_taskN.sqlite3"` (N = your task) and `bin/rails db:schema:load` once first.
- **Never edit any `features/**/*.feature` file.** Frozen facts this page must keep: «Список игр» is a link to `games_path`; a guest sees «Войти» (the menu has it) and «Зарегистрироваться»; a **signed-in user must not see the text «Зарегистрироваться» anywhere on `/`** (`features/signup/signup.feature:15`); a guest sees no link to `/dashboard`; the page never shows «Вы не авторизованы…».
- Hash rockets in Ruby; English comments; every user-facing string through `t()`; author-written game names rendered verbatim.
- Every new key in **all seven** `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`, inside the existing `index:` → `index:` mapping (or `time:` → `formats:`), never a second copy of a mapping. YAML parse check after editing: `ruby -ryaml -e 'Dir["config/locales/*.yml"].each { |f| YAML.unsafe_load_file(f) }; puts "ok"'`.
- Never case-change user-facing text in Ruby.
- CSS: font sizes only `var(--text-*)`; no raw z-index; `@media` only 48rem/47.99rem/52rem/60rem; no shadows/gradients; tokens only (`spec/stylesheets/token_discipline_spec.rb`).
- The guest page has **exactly one** filled `.btn--go` (the hero's sign-up).
- Run only the specs your task names. No full RSpec or Cucumber suites; no background processes. Layout spec: `LAYOUT_SPECS=1`, foreground.
- Precise edits only; confirm `git diff --stat` before committing; reports with your file-writing tool, never a shell heredoc. Commit messages plain, no attribution lines.

## Review Focus

1. **A listed scheduled game with no start date** (`starts_at` nil — the app allows it, «Дата начала игры ещё не назначена») must sort after dated games and show that sentence instead of a date, not crash `l_with_zone` — Task 1 (order) and Task 4 (render) pin it.
2. **The game's own author** viewing the home page must see «Вы автор игры» on the card, never apply buttons for their own game — the dashboard already does this; the spec omitted it; Task 5 pins it.
3. **A signed-in captain whose team has a `recalled`/`canceled` entry** must see the registration tag on rows (not a stale «Заявка подана») and «Подать заявку на регистрацию заново» on the card — Tasks 3 and 5.
4. **A very long author-written game name** must not push the status tag off the row or widen the page at 390px — Task 6 (layout).
5. **A signed-in user** must never see «Зарегистрироваться» on `/` (frozen `signup.feature:15`), while «Вы зарегистрированы» is a different string, and the captain's two refusal notices contain lowercase «зарегистрироваться» (Capybara's text match is case-sensitive, so they are safe — but never capitalise them) — Task 5 pins both.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `app/services/upcoming_games.rb` (new) | classify + order + cap the home page's games | 1 |
| `spec/services/upcoming_games_spec.rb` (new) | grouping, order, cap, exclusions, query count | 1 |
| `config/locales/*.yml` (7) | `index.index.*` keys, `time.formats.home_card/home_row` | 2 |
| `spec/i18n_spec.rb` | the two new time formats are legitimate en=ru duplicates | 2 |
| `spec/i18n_home_spec.rb` (new) | manual anchors exist; dates render; tr/ka team line | 2 |
| `app/helpers/index_helper.rb` (new) | `home_registration_open?`, `home_status_tag`, `home_entry_for` | 3 |
| `spec/helpers/index_helper_spec.rb` (new) | every tag outcome | 3 |
| `app/controllers/index_controller.rb` | `@upcoming = UpcomingGames.call` | 4 |
| `app/views/index/index.html.erb` + `_hero`, `_upcoming`, `_next_game`, `_game_row`, `_how_to_play`, `_organizers` (new) | the page | 4, 5 |
| `public/stylesheets/screens.css` | `.home` block | 4 |
| `spec/requests/home_page_spec.rb` (new) | guest + signed-in states | 4, 5 |
| `app/views/index/_card_action.html.erb` (new) | the next-game card's action, per visitor kind | 5 |
| `app/views/shared/_game_entry_controls.html.erb` | `.btn` classes; texts in `.notice` | 5 |
| `spec/requests/game_entry_controls_classes_spec.rb` (new) | dashboard buttons styled, text unchanged | 5 |
| `spec/layout/home_layout_spec.rb` (new) | measured in both themes | 6 |
| `CLAUDE.md` | docs | 7 |

---

### Task 1: `UpcomingGames`

**Files:** Create `app/services/upcoming_games.rb`, `spec/services/upcoming_games_spec.rb`.

**Interfaces — Produces:** `UpcomingGames.call(scope = Game.visible) -> UpcomingGames::Result` with readers `running` (Array<Game>), `next_game` (Game or nil), `scheduled` (Array<Game>), `gated` (Array<Game>), and methods `games` (all of them, in display order: running, next_game, scheduled, gated) and `empty?`. Constant `UpcomingGames::ROW_LIMIT = 4`. Games come with `runs` preloaded.

- [ ] **Step 1: Write the failing spec**

```ruby
require "rails_helper"

describe UpcomingGames do
  def scheduled_at(time, name)
    game = create_game(:name => name)
    set_game_schedule!(game, :starts_at => time)
    game
  end

  it "takes the earliest scheduled game as the next game, the rest as rows in start order" do
    late  = scheduled_at(3.days.from_now, "Поздняя")
    early = scheduled_at(1.day.from_now, "Ранняя")
    mid   = scheduled_at(2.days.from_now, "Средняя")

    result = UpcomingGames.call

    expect(result.next_game).to eq(early)
    expect(result.scheduled).to eq([mid, late])
  end

  it "puts running games first and gated games last" do
    running = create_game(:name => "Идущая")
    set_game_schedule!(running, :starts_at => 1.hour.ago)
    gated = create_game(:name => "Платная", :access_mode => "pass_required")
    upcoming = scheduled_at(1.day.from_now, "Будущая")

    result = UpcomingGames.call

    expect(result.running).to eq([running])
    expect(result.next_game).to eq(upcoming)
    expect(result.gated).to eq([gated])
    expect(result.games).to eq([running, upcoming, gated])
  end

  it "sorts a scheduled game with no start date after dated ones" do
    undated = create_game(:name => "Без даты")
    set_game_schedule!(undated, :starts_at => nil)
    dated = scheduled_at(5.days.from_now, "С датой")

    result = UpcomingGames.call

    expect(result.next_game).to eq(dated)
    expect(result.scheduled).to eq([undated])
  end

  it "caps the rows at four, filling running, then scheduled, then gated" do
    2.times { |i| set_game_schedule!(create_game(:name => "Идёт #{i}"), :starts_at => (i + 1).hours.ago) }
    5.times { |i| scheduled_at((i + 1).days.from_now, "План #{i}") }
    create_game(:name => "Код", :access_mode => "pass_required")

    result = UpcomingGames.call

    expect(result.running.size).to eq(2)
    expect(result.next_game.name).to eq("План 0")
    expect(result.scheduled.map(&:name)).to eq(["План 1", "План 2"])
    expect(result.gated).to eq([])
    expect(result.running.size + result.scheduled.size + result.gated.size).to eq(UpcomingGames::ROW_LIMIT)
  end

  it "leaves out finished, draft, withdrawn and test-run games" do
    finished = create_game(:name => "Прошла")
    set_game_schedule!(finished, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    create_game(:name => "Черновик", :is_draft => true)
    create_game(:name => "Снята").update_column(:withdrawn_at, Time.now)
    testing = create_game(:name => "Тест")
    set_game_schedule!(testing, :starts_at => 1.hour.ago, :is_testing => true)

    expect(UpcomingGames.call.games).to eq([])
    expect(UpcomingGames.call).to be_empty
  end

  it "costs the same number of queries for three games as for thirty" do
    3.times { |i| scheduled_at((i + 1).days.from_now, "A#{i}") }
    small = count_queries { UpcomingGames.call.games.each(&:current_run) }
    27.times { |i| scheduled_at((i + 10).days.from_now, "B#{i}") }
    large = count_queries { UpcomingGames.call.games.each(&:current_run) }

    expect(large).to eq(small)
  end
end
```

- [ ] **Step 2: Run it — expect `uninitialized constant UpcomingGames`.**

Run: `bundle exec rspec spec/services/upcoming_games_spec.rb`

- [ ] **Step 3: Implement**

`app/services/upcoming_games.rb`:

```ruby
# app/services/upcoming_games.rb
#
# The games the home page shows, in the order it shows them: running games
# first (a player opening the site on game night wants the live one), then the
# earliest scheduled game as the prominent card, then other scheduled games by
# start time, then code-gated games, which have no start date. At most
# ROW_LIMIT rows besides the card; everything else is behind "Список игр".
#
# One query for the games and one for their runs (Game#status reads the
# current run, so runs are preloaded), however many games exist. Classification
# happens in memory because Game#status is the single source of truth for what
# a game's state is -- re-deriving it in SQL would drift from it.
class UpcomingGames
  ROW_LIMIT = 4

  Result = Struct.new(:running, :next_game, :scheduled, :gated, :keyword_init => true) do
    def games
      [*running, next_game, *scheduled, *gated].compact
    end

    def empty?
      games.empty?
    end
  end

  def self.call(scope = Game.visible)
    new(scope).call
  end

  def initialize(scope)
    @scope = scope
  end

  def call
    by_status = @scope.includes(:runs).to_a.group_by(&:status)

    running   = by_start(by_status.fetch(:running, []))
    scheduled = by_start(by_status.fetch(:scheduled, []))
    gated     = by_status.fetch(:available, []).sort_by { |game| [game.name.to_s, game.id] }
    next_game = scheduled.shift

    rows = (running + scheduled + gated).first(ROW_LIMIT)
    Result.new(:running   => running   & rows,
               :next_game => next_game,
               :scheduled => scheduled & rows,
               :gated     => gated     & rows)
  end

  private

  # A listed game may have no start date yet; it sorts after every dated one.
  def by_start(games)
    games.sort_by { |game| [game.starts_at ? 0 : 1, game.starts_at || Time.at(0), game.id] }
  end
end
```

- [ ] **Step 4: Run it — expect 6 examples, 0 failures.** If the query-count example fails, the cause is a per-game query outside `includes(:runs)`; fix the service, not the test.

- [ ] **Step 5: Commit**

```bash
git add app/services/upcoming_games.rb spec/services/upcoming_games_spec.rb
git commit -m "Add UpcomingGames: the home page's games, classified and capped

Running first, the earliest scheduled game as the card, other scheduled
games by start time (undated last), then code-gated games; at most four
rows. Two queries regardless of how many games exist."
```

---

### Task 2: Copy, dates and manual anchors (all seven locales)

**Files:** Modify `config/locales/{ru,en,uk,be,pl,tr,ka}.yml`, `spec/i18n_spec.rb`; create `spec/i18n_home_spec.rb`.

**Interfaces — Produces:** keys under `index.index.*` (listed below) and `time.formats.home_card` / `time.formats.home_row`. Tasks 3–5 use these exact names.

- [ ] **Step 1: Write the failing spec**

`spec/i18n_home_spec.rb`:

```ruby
require "rails_helper"

# The home page's copy that a plain parity check cannot judge: deep links into
# each language's own manual (heading ids differ per language), the two date
# formats, and the team line's placeholder in the suffixing languages.
describe "home page copy" do
  LOCALES_FOR_HOME = %w[ru en uk be pl tr ka].freeze

  def value(locale, key)
    YAML.unsafe_load_file(Rails.root.join("config/locales/#{locale}.yml"))[locale].dig(*key.split("."))
  end

  LOCALES_FOR_HOME.each do |locale|
    it "points #{locale}'s manual links at real chapter headings of #{locale}'s manual" do
      html = Manual::Renderer.call(File.read(Rails.root.join("docs/manual/#{locale}.md"))).to_s
      ids = Nokogiri::HTML(html).css("h1, h2, h3").map { |h| h["id"] }

      expect(ids).to include(value(locale, "index.index.manual_player_anchor"))
      expect(ids).to include(value(locale, "index.index.manual_author_anchor"))
    end

    it "renders #{locale}'s home dates with a month name and the time" do
      time = Time.utc(2050, 10, 12, 21, 0)
      I18n.with_locale(locale) do
        expect(I18n.l(time, :format => :home_card)).to match(/\A12 \S+, 21:00\z/)
        expect(I18n.l(time, :format => :home_row)).to match(/\A12 \S+, 21:00\z/)
      end
    end
  end

  it "renders the Russian card date with the genitive month" do
    I18n.with_locale(:ru) { expect(I18n.l(Time.utc(2050, 10, 12, 21, 0), :format => :home_card)).to eq("12 октября, 21:00") }
  end

  # CLAUDE.md: Turkish and Georgian put case suffixes on a common noun, never on
  # a user-authored name. The team line must end the name with its closing
  # quote, with no suffix attached.
  %w[tr ka].each do |locale|
    it "keeps #{locale}'s team line free of a suffix on the team name" do
      expect(value(locale, "index.index.team_line")).to match(/«%\{team\}»\z/)
    end
  end
end
```

- [ ] **Step 2: Run it — expect failures (keys missing).** `bundle exec rspec spec/i18n_home_spec.rb`

- [ ] **Step 3: Add the keys**

Inside each file's existing `index:` → `index:` mapping (keep `title` and `games_list` as they are), add exactly these keys. The YAML below shows the key list once with the Russian values; the table after it gives the other six languages.

```yaml
      hero_title: "Городские игры: найди код раньше всех"
      hero_lead: "Команды ищут коды по всему городу — с телефона."
      hero_signup: "Зарегистрироваться"
      hero_how: "Как играть"
      upcoming_heading: "Ближайшие игры"
      teams_count: "Команд: %{count} из %{max}"
      registration_open: "Регистрация открыта"
      registration_closed: "Регистрация закрыта"
      running: "Идёт сейчас"
      gated: "По коду доступа"
      gated_live: "Доступ есть"
      entry_rejected: "Заявка отклонена"
      member_note: "Заявку подаёт капитан команды"
      no_team: "Создайте команду или вступите в неё, чтобы играть"
      empty_title: "Сейчас игр не запланировано"
      empty_text: "Загляните позже — или посмотрите все игры, включая прошедшие."
      team_line: "Команда: «%{team}»"
      team_room: "Комната команды"
      how_heading: "Как играть"
      step1_title: "Зарегистрируйтесь"
      step1_text: "Нужны только имя и e-mail; пароль придёт письмом."
      step2_title: "Соберите команду"
      step2_text: "Создайте команду или вступите в неё; капитан записывает команду на игру."
      step3_title: "Играйте с телефона"
      step3_text: "В день игры откройте игру: задание, подсказки и поле для кода — на одном экране."
      how_more: "Подробнее в руководстве"
      organizers_heading: "Проводите игры в своём городе"
      organizers_item1: "Уровни с кодами или вопросами квиза, импорт списком"
      organizers_item2: "Тестовые прогоны перед игрой"
      organizers_item3: "История прогонов и результаты"
      organizers_item4: "Перевод игры на другие языки"
      organizers_item5: "Платный доступ по кодам"
      organizers_link: "Руководство организатора"
      manual_player_anchor: "игроку"
      manual_author_anchor: "автору-игры"
```

| key | en | uk | be | pl | tr | ka |
|---|---|---|---|---|---|---|
| hero_title | City games: find the code before anyone else | Міські ігри: знайди код першим | Гарадскія гульні: знайдзі код першым | Gry miejskie: znajdź kod jako pierwszy | Şehir oyunları: kodu herkesten önce bul | ქალაქის თამაშები: იპოვე კოდი ყველაზე ადრე |
| hero_lead | Teams hunt for codes all over the city — from their phones. | Команди шукають коди по всьому місту — з телефона. | Каманды шукаюць коды па ўсім горадзе — з тэлефона. | Drużyny szukają kodów w całym mieście — z telefonu. | Takımlar şehrin dört bir yanında kod arar — telefondan. | გუნდები კოდებს მთელ ქალაქში ეძებენ — ტელეფონით. |
| hero_signup | Sign up | Зареєструватися | Зарэгістравацца | Zarejestruj się | Kayıt ol | რეგისტრაცია |
| hero_how | How to play | Як грати | Як гуляць | Jak grać | Nasıl oynanır | როგორ ვითამაშოთ |
| upcoming_heading | Upcoming games | Найближчі ігри | Бліжэйшыя гульні | Najbliższe gry | Yaklaşan oyunlar | უახლოესი თამაშები |
| teams_count | Teams: %{count} of %{max} | Команд: %{count} з %{max} | Каманд: %{count} з %{max} | Drużyn: %{count} z %{max} | Takımlar: %{count} / %{max} | გუნდები: %{count} / %{max} |
| registration_open | Registration open | Реєстрація відкрита | Рэгістрацыя адкрыта | Rejestracja otwarta | Kayıt açık | რეგისტრაცია ღიაა |
| registration_closed | Registration closed | Реєстрація закрита | Рэгістрацыя закрыта | Rejestracja zamknięta | Kayıt kapalı | რეგისტრაცია დახურულია |
| running | Happening now | Іде зараз | Ідзе зараз | Trwa teraz | Şu anda sürüyor | ახლა მიმდინარეობს |
| gated | Access by code | За кодом доступу | Па кодзе доступу | Dostęp kodem | Erişim koduyla | წვდომის კოდით |
| gated_live | You have access | Доступ є | Доступ ёсць | Masz dostęp | Erişiminiz var | წვდომა გაქვთ |
| entry_rejected | Application rejected | Заявку відхилено | Заяўку адхілена | Zgłoszenie odrzucone | Başvuru reddedildi | განაცხადი უარყოფილია |
| member_note | Your team captain applies | Заявку подає капітан команди | Заяўку падае капітан каманды | Zgłoszenie składa kapitan drużyny | Başvuruyu takım kaptanı yapar | განაცხადს გუნდის კაპიტანი აგზავნის |
| no_team | Create a team or join one to play | Створіть команду або вступіть до неї, щоб грати | Стварыце каманду або ўступіце ў яе, каб гуляць | Załóż drużynę lub dołącz do niej, aby grać | Oynamak için bir takım kurun ya da bir takıma katılın | სათამაშოდ შექმენით გუნდი ან შეუერთდით მას |
| empty_title | No games scheduled right now | Зараз ігор не заплановано | Зараз гульняў не запланавана | Obecnie nie zaplanowano żadnych gier | Şu anda planlanmış oyun yok | ამჟამად თამაშები დაგეგმილი არ არის |
| empty_text | Check back later — or browse all games, including past ones. | Загляньте пізніше — або перегляньте всі ігри, включно з минулими. | Зазірніце пазней — або паглядзіце ўсе гульні, уключна з мінулымі. | Zajrzyj później — albo przejrzyj wszystkie gry, także minione. | Daha sonra tekrar bakın — ya da geçmişteki oyunlar dahil tüm oyunlara göz atın. | შემოიარეთ მოგვიანებით — ან ნახეთ ყველა თამაში, წარსულის ჩათვლით. |
| team_line | Team: «%{team}» | Команда: «%{team}» | Каманда: «%{team}» | Drużyna: «%{team}» | Takımınız: «%{team}» | გუნდი: «%{team}» |
| team_room | Team room | Кімната команди | Пакой каманды | Pokój drużyny | Takım odası | გუნდის ოთახი |
| how_heading | How to play | Як грати | Як гуляць | Jak grać | Nasıl oynanır | როგორ ვითამაშოთ |
| step1_title | Sign up | Зареєструйтеся | Зарэгіструйцеся | Zarejestruj się | Kayıt olun | დარეგისტრირდით |
| step1_text | All you need is a name and an e-mail; your password arrives by mail. | Потрібні лише ім'я та e-mail; пароль прийде листом. | Патрэбныя толькі імя і e-mail; пароль прыйдзе лістом. | Wystarczą nazwa i e-mail; hasło przyjdzie mailem. | Yalnızca bir ad ve e-posta yeterli; şifreniz e-postayla gelir. | საჭიროა მხოლოდ სახელი და ელფოსტა; პაროლი წერილით მოვა. |
| step2_title | Form a team | Зберіть команду | Збярыце каманду | Zbierz drużynę | Takımınızı kurun | შეკრიბეთ გუნდი |
| step2_text | Create a team or join one; the captain registers the team for a game. | Створіть команду або вступіть до неї; капітан записує команду на гру. | Стварыце каманду або ўступіце ў яе; капітан запісвае каманду на гульню. | Załóż drużynę lub dołącz do niej; kapitan zgłasza drużynę do gry. | Bir takım kurun ya da bir takıma katılın; takımı oyuna kaptan kaydeder. | შექმენით გუნდი ან შეუერთდით მას; კაპიტანი გუნდს თამაშზე არეგისტრირებს. |
| step3_title | Play from your phone | Грайте з телефона | Гуляйце з тэлефона | Graj z telefonu | Telefondan oynayın | ითამაშეთ ტელეფონით |
| step3_text | On game day, open the game: the task, the hints and the code field are on one screen. | У день гри відкрийте гру: завдання, підказки й поле для коду — на одному екрані. | У дзень гульні адкрыйце гульню: заданне, падказкі і поле для кода — на адным экране. | W dniu gry otwórz grę: zadanie, podpowiedzi i pole na kod — na jednym ekranie. | Oyun günü oyunu açın: görev, ipuçları ve kod alanı tek ekranda. | თამაშის დღეს გახსენით თამაში: დავალება, მინიშნებები და კოდის ველი — ერთ ეკრანზე. |
| how_more | More in the manual | Докладніше в посібнику | Падрабязней у дапаможніку | Więcej w podręczniku | Kılavuzda daha fazlası | დაწვრილებით სახელმძღვანელოში |
| organizers_heading | Run games in your city | Проводьте ігри у своєму місті | Праводзьце гульні ў сваім горадзе | Prowadź gry w swoim mieście | Kendi şehrinizde oyun düzenleyin | ჩაატარეთ თამაშები თქვენს ქალაქში |
| organizers_item1 | Levels with codes or quiz questions, imported from a list | Рівні з кодами або питаннями квізу, імпорт списком | Узроўні з кодамі або пытаннямі квізу, імпарт спісам | Poziomy z kodami lub pytaniami quizu, import z listy | Kodlu ya da test sorulu seviyeler, listeden içe aktarma | დონეები კოდებით ან ქვიზის კითხვებით, სიიდან იმპორტი |
| organizers_item2 | Test runs before the game | Тестові прогони перед грою | Тэставыя прагоны перад гульнёй | Przebiegi testowe przed grą | Oyundan önce deneme turları | სატესტო გაშვებები თამაშამდე |
| organizers_item3 | Run history and results | Історія прогонів і результати | Гісторыя прагонаў і вынікі | Historia przebiegów i wyniki | Tur geçmişi ve sonuçlar | გაშვებების ისტორია და შედეგები |
| organizers_item4 | Translating a game into other languages | Переклад гри іншими мовами | Пераклад гульні на іншыя мовы | Tłumaczenie gry na inne języki | Oyunun başka dillere çevrilmesi | თამაშის თარგმნა სხვა ენებზე |
| organizers_item5 | Paid access by code | Платний доступ за кодами | Платны доступ па кодах | Płatny dostęp za pomocą kodów | Kodla ücretli erişim | ფასიანი წვდომა კოდებით |
| organizers_link | Organizer's manual | Посібник організатора | Дапаможнік арганізатара | Podręcznik organizatora | Organizatör kılavuzu | ორგანიზატორის სახელმძღვანელო |
| manual_player_anchor | for-players | гравцеві | гульцу | dla-graczy | oyuncular-için | მოთამაშეებისთვის |
| manual_author_anchor | for-game-authors | автору-гри | аўтару-гульні | dla-autorów-gry | oyun-yazarları-için | თამაშის-ავტორებისთვის |

(The anchors were measured with `Manual::Renderer` against each shipped manual on 2026-10-01; the new spec re-verifies them.)

Then in each file, inside the existing `time:` → `formats:` mapping (create `time:`/`formats:` under the locale root only if the file has none — check first), add:

```yaml
      home_card: "%-d %B, %H:%M"
      home_row: "%-d %b, %H:%M"
```

In `spec/i18n_spec.rb`, add `time.formats.home_card` and `time.formats.home_row` to `known_legitimate_duplicates` (directly after `time.formats.short`): a strftime pattern is the same in every language by construction.

- [ ] **Step 4: Run** `bundle exec rspec spec/i18n_home_spec.rb spec/i18n_spec.rb spec/i18n_play_screen_spec.rb` — expect 0 failures (YAML parse check first).

- [ ] **Step 5: Commit**

```bash
git add config/locales spec/i18n_spec.rb spec/i18n_home_spec.rb
git commit -m "Add the home page's copy and date formats in seven languages

Hero, upcoming-games statuses, how-to-play, organizers, empty state and
team line, plus per-language manual anchors verified against each
shipped manual and two date formats for the card and rows."
```

---

### Task 3: `IndexHelper` — one status tag per game

**Files:** Create `app/helpers/index_helper.rb`, `spec/helpers/index_helper_spec.rb`.

**Interfaces — Consumes:** Task 2's keys. **Produces:** `home_registration_open?(game) -> Boolean`; `home_status_tag(game, entry: nil, gated_live: false) -> [String text, String css_class]`; `home_entry_for(game) -> GameEntry or nil` (the signed-in user's team's entry for the game's current run; nil for guests, team-less users and gated games; memoised per request).

- [ ] **Step 1: Write the failing spec**

```ruby
require "rails_helper"

describe IndexHelper, type: :helper do
  let(:game) { create_game }

  def entry(status)
    create_game_entry(:game => game, :team => create_team(:captain => create_user), :status => status)
  end

  describe "#home_registration_open?" do
    it "is open for a scheduled game under its limit with no deadline" do
      expect(helper.home_registration_open?(game)).to be(true)
    end

    it "is closed once the deadline has passed" do
      set_game_schedule!(game, :registration_deadline => 1.hour.ago, :starts_at => 1.day.from_now)
      expect(helper.home_registration_open?(game)).to be(false)
    end

    it "is closed once the game has started" do
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      expect(helper.home_registration_open?(game.reload)).to be(false)
    end
  end

  describe "#home_status_tag" do
    it "says a running game is happening now" do
      set_game_schedule!(game, :starts_at => 1.hour.ago)
      expect(helper.home_status_tag(game.reload)).to eq(["Идёт сейчас", "tag tag--live"])
    end

    it "shows the registration tag when there is no entry" do
      expect(helper.home_status_tag(game)).to eq(["Регистрация открыта", "tag tag--live"])
    end

    it "shows a pending application" do
      expect(helper.home_status_tag(game, :entry => entry("new"))).to eq(["Заявка подана", "tag"])
    end

    it "shows an accepted application" do
      expect(helper.home_status_tag(game, :entry => entry("accepted"))).to eq(["Вы зарегистрированы", "tag tag--live"])
    end

    it "shows a rejected application in danger" do
      expect(helper.home_status_tag(game, :entry => entry("rejected"))).to eq(["Заявка отклонена", "tag tag--danger"])
    end

    it "treats a recalled or cancelled entry as no entry" do
      %w[recalled canceled].each do |status|
        expect(helper.home_status_tag(game, :entry => entry(status))).to eq(["Регистрация открыта", "tag tag--live"])
      end
    end

    it "labels a code-gated game, live or not" do
      gated = create_game(:access_mode => "pass_required")
      expect(helper.home_status_tag(gated)).to eq(["По коду доступа", "tag"])
      expect(helper.home_status_tag(gated, :gated_live => true)).to eq(["Доступ есть", "tag tag--live"])
    end
  end
end
```

- [ ] **Step 2: Run it — expect `uninitialized constant IndexHelper` or undefined methods.** `bundle exec rspec spec/helpers/index_helper_spec.rb`

- [ ] **Step 3: Implement** `app/helpers/index_helper.rb`:

```ruby
# app/helpers/index_helper.rb
#
# The home page's per-game status: one tag (text and classes) for a game, as
# seen by the current visitor. Entry wording reuses the dashboard's keys
# (shared.game_entry_controls.*) so the two pages say the same thing.
module IndexHelper
  def home_registration_open?(game)
    game.status == :scheduled && game.can_request? &&
      (game.registration_deadline.nil? || game.registration_deadline > Time.now)
  end

  def home_status_tag(game, entry: nil, gated_live: false)
    return [t("index.index.running"), "tag tag--live"] if game.status == :running

    if game.pass_required?
      return gated_live ? [t("index.index.gated_live"), "tag tag--live"] : [t("index.index.gated"), "tag"]
    end

    case entry&.status
    when "new"      then [t("shared.game_entry_controls.applied"), "tag"]
    when "accepted" then [t("shared.game_entry_controls.registered"), "tag tag--live"]
    when "rejected" then [t("index.index.entry_rejected"), "tag tag--danger"]
    else
      if home_registration_open?(game)
        [t("index.index.registration_open"), "tag tag--live"]
      else
        [t("index.index.registration_closed"), "tag"]
      end
    end
  end

  # The signed-in user's team's entry for the game's current run -- the same
  # lookup the dashboard makes (GameEntry.of), memoised so each game costs one
  # query at most. Nil for guests, users with no team, and gated games (an
  # entry on a gated game authorises nothing).
  def home_entry_for(game)
    return nil unless logged_in? && current_user.team
    return nil if game.pass_required?

    @home_entries ||= {}
    @home_entries.fetch(game.id) { @home_entries[game.id] = GameEntry.of(current_user.team, game.current_run) }
  end
end
```

- [ ] **Step 4: Run it — expect 0 failures.** If `home_registration_open?` is wrongly true once the game started, check `Game#status` reads the reloaded run.

- [ ] **Step 5: Commit**

```bash
git add app/helpers/index_helper.rb spec/helpers/index_helper_spec.rb
git commit -m "Add IndexHelper: the home page's per-game status tag"
```

---

### Task 4: The page — guest view

**Files:** Modify `app/controllers/index_controller.rb`, `app/views/index/index.html.erb`, `public/stylesheets/screens.css`; create `app/views/index/{_hero,_upcoming,_next_game,_game_row,_how_to_play,_organizers}.html.erb`, `spec/requests/home_page_spec.rb`.

**Interfaces — Consumes:** `UpcomingGames` (Task 1), the keys (Task 2), `IndexHelper` (Task 3), existing `game_team_counts(games)` (returns `{:registered => {game_id => n}, …}`), `gated_play_status(games)` (`{game_id => true/false}`, empty for guests), `l_with_zone(time, format:)`.
**Produces:** partial `index/_next_game` takes locals `game:, counts:`; `index/_game_row` takes `game:, gated_status:`; the action slot inside `_next_game` is `<div class="next-game-action">…</div>` — Task 5 fills it for signed-in visitors.

- [ ] **Step 1: Write the failing guest spec**

`spec/requests/home_page_spec.rb`:

```ruby
require "rails_helper"

# The home page. Literal Russian is pinned rather than I18n.t(...), which
# would also pass with a key missing.
describe "the home page", type: :request do
  let(:doc) { Nokogiri::HTML(response.body) }

  def scheduled(name, at)
    game = create_game(:name => name)
    set_game_schedule!(game, :starts_at => at)
    game
  end

  describe "for a guest" do
    it "explains the game, shows the next game, and keeps one filled button" do
      scheduled("Ночной Бишкек", 1.day.from_now)
      get root_path

      expect(response.body).to include("Городские игры: найди код раньше всех")
      expect(doc.css(".btn--go").size).to eq(1)
      expect(doc.at_css(".btn--go").text.strip).to eq("Зарегистрироваться")
      expect(doc.at_css(".next-game").text).to include("Ночной Бишкек")
      expect(doc.at_css(".next-game").text).to include("Регистрация открыта")
      expect(doc.at_css("#how-to-play")).to be_present
      expect(response.body).to include("Проводите игры в своём городе")
    end

    it "keeps the frozen anchors" do
      get root_path

      link = doc.css("a").find { |a| a.text.strip == "Список игр" }
      expect(link["href"]).to eq(games_path)
      expect(doc.css("a[href='#{dashboard_path}']")).to be_empty
      expect(response.body).not_to include("Вы не авторизованы")
    end

    it "shows an empty state, still with the games-list link, when nothing is upcoming" do
      get root_path

      expect(response.body).to include("Сейчас игр не запланировано")
      expect(doc.css("a").map { |a| a.text.strip }).to include("Список игр")
    end

    it "lists a running game first, tagged as happening now" do
      running = create_game(:name => "Идущая")
      set_game_schedule!(running, :starts_at => 1.hour.ago)
      scheduled("Будущая", 1.day.from_now)
      get root_path

      first_row = doc.at_css(".game-row")
      expect(first_row.text).to include("Идущая")
      expect(first_row.text).to include("Идёт сейчас")
    end

    it "says an undated game has no start date yet" do
      undated = create_game(:name => "Без даты")
      set_game_schedule!(undated, :starts_at => nil)
      get root_path

      expect(doc.at_css(".next-game").text).to include("Дата начала игры ещё не назначена")
    end

    it "links how-to-play and organizers into the Russian manual's chapters" do
      get root_path

      expect(doc.css("a").map { |a| a["href"] }).to include("#{manual_path}#игроку", "#{manual_path}#автору-игры")
    end
  end
end
```

- [ ] **Step 2: Run it — expect failures** (old page). `bundle exec rspec spec/requests/home_page_spec.rb`

- [ ] **Step 3: Controller** — `app/controllers/index_controller.rb`, replace the body of `index`:

```ruby
  def index
    # The home page's games, classified and capped (app/services/upcoming_games.rb).
    # The full list lives at /games behind the "Список игр" link.
    @upcoming = UpcomingGames.call
  end
```

- [ ] **Step 4: Views**

`app/views/index/index.html.erb` (replace the whole file):

```erb
<%# The home page. Guests get the explanation (hero, how to play, organizers);
    signed-in players get only the games, with their team's status. Frozen
    anchors this page must keep: "Список игр" links to games_path
    (games-list.feature, index-page.feature); a signed-in user never sees
    "Зарегистрироваться" here (signup.feature:15); no /dashboard link for a
    guest (dashboard.feature). %>
<div class="home">
  <% unless logged_in? %>
    <%= render "index/hero" %>
  <% end %>
  <%= render "index/upcoming", upcoming: @upcoming %>
  <% unless logged_in? %>
    <%= render "index/how_to_play" %>
    <%= render "index/organizers" %>
  <% end %>
</div>
```

`app/views/index/_hero.html.erb`:

```erb
<section class="home-hero">
  <h1><%= t("index.index.hero_title") %></h1>
  <p><%= t("index.index.hero_lead") %></p>
  <div class="home-actions">
    <%= link_to t("index.index.hero_signup"), signup_path, class: "btn btn--go" %>
    <a href="#how-to-play" class="btn btn--quiet"><%= t("index.index.hero_how") %></a>
  </div>
</section>
```

`app/views/index/_upcoming.html.erb`:

```erb
<% games = upcoming.games %>
<% counts = game_team_counts(games) %>
<% gated_status = gated_play_status(games) %>
<section class="home-upcoming">
  <%# A signed-in page has no hero, so this heading is its h1. %>
  <%= content_tag(logged_in? ? :h1 : :h2, t("index.index.upcoming_heading"), class: "home-section-heading") %>
  <% if upcoming.empty? %>
    <div class="card">
      <h3><%= t("index.index.empty_title") %></h3>
      <p class="home-note"><%= t("index.index.empty_text") %></p>
    </div>
  <% else %>
    <% if upcoming.running.any? %>
      <ul class="game-rows">
        <% upcoming.running.each do |game| %>
          <%= render "index/game_row", game: game, gated_status: gated_status %>
        <% end %>
      </ul>
    <% end %>
    <% if upcoming.next_game %>
      <%= render "index/next_game", game: upcoming.next_game, counts: counts %>
    <% end %>
    <% rest = upcoming.scheduled + upcoming.gated %>
    <% if rest.any? %>
      <ul class="game-rows">
        <% rest.each do |game| %>
          <%= render "index/game_row", game: game, gated_status: gated_status %>
        <% end %>
      </ul>
    <% end %>
  <% end %>
  <p><%= link_to t("index.index.games_list"), games_path, class: "link-tap" %></p>
  <% if logged_in? && current_user.team %>
    <p class="home-note">
      <%= t("index.index.team_line", team: current_user.team.name) %> ·
      <%= link_to t("index.index.team_room"), team_room_path %>
    </p>
  <% end %>
</section>
```

`app/views/index/_next_game.html.erb`:

```erb
<% text, css = home_status_tag(game) %>
<article class="card next-game">
  <h3><%= link_to game.name, game_path(game) %></h3>
  <span class="<%= css %>"><%= text %></span>
  <div class="when">
    <%= game.starts_at ? l_with_zone(game.starts_at, format: :home_card) : t("games.show.starts_at_not_set") %>
  </div>
  <div class="meta">
    <%= t("index.index.teams_count", count: counts[:registered].fetch(game.id, 0), max: game.max_team_number) %>
  </div>
  <div class="next-game-action"></div>
</article>
```

`app/views/index/_game_row.html.erb`:

```erb
<% text, css = home_status_tag(game, entry: home_entry_for(game), gated_live: gated_status.fetch(game.id, false)) %>
<li class="game-row">
  <div>
    <%= link_to game.name, game_path(game), class: "name" %>
    <% if game.starts_at && !game.pass_required? %>
      <div class="when"><%= l_with_zone(game.starts_at, format: :home_row) %></div>
    <% end %>
  </div>
  <span class="<%= css %>"><%= text %></span>
</li>
```

`app/views/index/_how_to_play.html.erb`:

```erb
<section id="how-to-play">
  <h2 class="home-section-heading"><%= t("index.index.how_heading") %></h2>
  <ol class="timeline">
    <% 1.upto(3) do |n| %>
      <li>
        <span class="num" aria-hidden="true"><%= n %></span>
        <h3><%= t("index.index.step#{n}_title") %></h3>
        <p><%= t("index.index.step#{n}_text") %></p>
      </li>
    <% end %>
  </ol>
  <p><%= link_to t("index.index.how_more"), "#{manual_path}##{t("index.index.manual_player_anchor")}", class: "link-tap" %></p>
</section>
```

`app/views/index/_organizers.html.erb`:

```erb
<section class="panel home-organizers">
  <h2 class="home-section-heading"><%= t("index.index.organizers_heading") %></h2>
  <ul>
    <% 1.upto(5) do |n| %>
      <li><%= t("index.index.organizers_item#{n}") %></li>
    <% end %>
  </ul>
  <%= link_to t("index.index.organizers_link"), "#{manual_path}##{t("index.index.manual_author_anchor")}", class: "link-tap" %>
</section>
```

- [ ] **Step 5: CSS** — append to `public/stylesheets/screens.css`:

```css
/* --- Home page (index/index) ---------------------------------------------
 * Players first: hero, upcoming games (card + compact rows), how-to-play
 * timeline, organizers panel. One column, capped for reading on desktop.
 * Design: Superdesign drafts 7eaa33ad (guest) and 659ef6ac (signed-in). */
.home { max-width: 44rem; margin-inline: auto; }
.home > * + * { margin-top: var(--space-6); }
.home-hero > p { margin-top: var(--space-3); color: var(--text-dim); }
.home-actions { display: flex; flex-wrap: wrap; gap: var(--space-3); margin-top: var(--space-5); }
.home-actions .btn { flex: 1 1 12rem; }
.home-section-heading { font-size: var(--text-h2); line-height: 1.25; font-weight: 600; margin-bottom: var(--space-4); }
.home .link-tap { display: inline-flex; align-items: center; min-height: var(--tap); }
.home-note { font-size: var(--text-sm); color: var(--text-dim); }
.home .tag { white-space: nowrap; flex-shrink: 0; }

.next-game h3 { font-size: var(--text-lg); margin-bottom: var(--space-2); }
.next-game .when { margin-top: var(--space-2); font-size: var(--text-lg); font-weight: 600; }
.next-game .meta { font-size: var(--text-sm); color: var(--text-dim); }
.next-game-action:not(:empty) { margin-top: var(--space-4); }

.game-rows { list-style: none; }
.game-row { display: flex; justify-content: space-between; align-items: center; gap: var(--space-3);
            padding: var(--space-3) 0; border-bottom: 1px solid var(--border); }
.game-row > div { min-width: 0; }
.game-row .name { font-weight: 600; overflow-wrap: anywhere; }
.game-row .when { font-size: var(--text-sm); color: var(--text-dim); }

.timeline { list-style: none; display: flex; flex-direction: column; gap: var(--space-4); }
.timeline li { position: relative; padding-left: calc(1.5rem + var(--space-3)); }
.timeline li:not(:last-child)::before { content: ""; position: absolute; left: calc(0.75rem - 0.5px);
            top: 1.5rem; bottom: calc(var(--space-4) * -1); width: 1px; background: var(--border-input); }
.timeline .num { position: absolute; left: 0; top: 0; width: 1.5rem; height: 1.5rem; border: 1px solid var(--go);
            border-radius: 50%; display: flex; align-items: center; justify-content: center;
            font-size: var(--text-sm); font-weight: 600; color: var(--go); background: var(--bg); }
.timeline h3 { font-size: var(--text-lg); }

.home-organizers ul { list-style: disc; padding-left: var(--space-4); margin: var(--space-3) 0; }
.home-organizers li { font-size: var(--text-sm); }
```

- [ ] **Step 6: Run** `bundle exec rspec spec/requests/home_page_spec.rb spec/stylesheets/token_discipline_spec.rb spec/requests/home_page_games_list_spec.rb spec/requests/testing_game_visibility_spec.rb spec/requests/locale_switcher_spec.rb spec/requests/manual_spec.rb`. Expect 0 failures. The middle two assert on the home page's *old* games table and should still pass unchanged: a running game is a row, drafts/withdrawn/test-run games are excluded by `Game.visible`, and a re-listed game with the default 2099 start is the next-game card. If one fails because the new page deliberately omits something it asserted (e.g. a finished game — §1 excludes `:finished`), report DONE_WITH_CONCERNS naming the example and the spec section; do not edit either spec's intent.

- [ ] **Step 7: Run the frozen home scenarios** `bundle exec cucumber features/index-page features/games/games-list.feature features/authentication/login.feature features/signup/signup.feature features/dashboard/dashboard.feature` (isolated DB as above) — all must pass.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/index_controller.rb app/views/index public/stylesheets/screens.css spec/requests/home_page_spec.rb
git commit -m "Rebuild the home page: hero, upcoming games, how to play, organizers"
```

---

### Task 5: Signed-in statuses and the captain's actions

**Files:** Modify `app/views/index/_next_game.html.erb` (the `next-game-action` div), `app/views/shared/_game_entry_controls.html.erb`; extend `spec/requests/home_page_spec.rb`; create `spec/requests/game_entry_controls_classes_spec.rb`.

**Interfaces — Consumes:** Task 4's `_next_game` and `next-game-action` slot; `home_entry_for`, `home_status_tag` (Task 3); existing `shared/_game_entry_controls` (locals `game_entry:, game:, team:`), `dashboard.coming_games.you_are_author`.

- [ ] **Step 1: Write the failing specs** — append inside `describe "the home page"` in `spec/requests/home_page_spec.rb`:

```ruby
  describe "for a signed-in player" do
    let(:captain) { create_user }
    let!(:team)   { create_team(:captain => captain) }
    let!(:game)   { scheduled("Ночной Бишкек", 1.day.from_now) }

    def sign_in(user)
      put login_path, :params => { :email => user.email, :password => "1234" }
    end

    it "drops the explanation and never says Зарегистрироваться" do
      sign_in(captain)
      get root_path

      expect(response.body).not_to include("Городские игры: найди код раньше всех")
      expect(doc.at_css("#how-to-play")).to be_nil
      expect(response.body).not_to include("Проводите игры в своём городе")
      expect(response.body).not_to include("Зарегистрироваться")
      expect(doc.at_css("h1").text.strip).to eq("Ближайшие игры")
    end

    it "offers the captain the dashboard's apply button" do
      sign_in(captain)
      get root_path

      button = doc.at_css(".next-game .next-game-action button")
      expect(button.text.strip).to eq("Подать заявку на регистрацию")
      expect(button["class"].split).to include("btn", "btn--go")
    end

    it "shows an applied captain the recall control" do
      create_game_entry(:game => game, :team => team, :status => "new")
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.text).to include("Заявка подана")
      expect(action.css("button").map { |b| b.text.strip }).to include("Отозвать")
    end

    it "shows an accepted captain the decline control" do
      create_game_entry(:game => game, :team => team, :status => "accepted")
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.text).to include("Вы зарегистрированы")
      expect(action.css("button").map { |b| b.text.strip }).to include("Отказаться")
    end

    it "tells the captain when the registration deadline has passed" do
      set_game_schedule!(game, :registration_deadline => 1.hour.ago)
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.at_css(".notice").text).to include("опоздали на игру")
      expect(action.css("button")).to be_empty
      expect(doc.at_css(".next-game").text).to include("Регистрация закрыта")
    end

    it "tells the captain when the team limit is reached" do
      set_game_schedule!(game, :max_team_number => 1, :requested_teams_number => 1)
      sign_in(captain)
      get root_path

      action = doc.at_css(".next-game .next-game-action")
      expect(action.at_css(".notice").text).to include("превышено количество участников")
      expect(action.css("button")).to be_empty
    end

    it "offers a recalled captain the reapply control" do
      create_game_entry(:game => game, :team => team, :status => "recalled")
      sign_in(captain)
      get root_path

      expect(doc.at_css(".next-game .next-game-action button").text.strip).to eq("Подать заявку на регистрацию заново")
    end

    it "tells a member who is not the captain that the captain applies" do
      member = create_user
      team.members << member
      sign_in(member)
      get root_path

      expect(doc.at_css(".next-game .next-game-action").text).to include("Заявку подаёт капитан команды")
      expect(doc.css(".next-game button")).to be_empty
    end

    it "points a player with no team to the teams page" do
      loner = create_user
      sign_in(loner)
      get root_path

      link = doc.at_css(".next-game .next-game-action a")
      expect(link.text.strip).to eq("Создайте команду или вступите в неё, чтобы играть")
      expect(link["href"]).to eq(teams_path)
    end

    it "shows the author their own game without apply buttons" do
      sign_in(game.author)
      get root_path

      expect(doc.at_css(".next-game .next-game-action").text).to include("Вы автор игры")
      expect(doc.css(".next-game button")).to be_empty
    end

    it "shows the team's status on rows" do
      later = scheduled("Тайны старого города", 2.days.from_now)
      rejected = scheduled("Зимний марафон", 3.days.from_now)
      create_game_entry(:game => later, :team => team, :status => "accepted")
      create_game_entry(:game => rejected, :team => team, :status => "rejected")
      sign_in(captain)
      get root_path

      rows = doc.css(".game-row").map { |row| row.text.squish }
      expect(rows).to include(a_string_including("Тайны старого города", "Вы зарегистрированы"))
      expect(rows).to include(a_string_including("Зимний марафон", "Заявка отклонена"))
    end

    it "says whether the team holds access to a code-gated game" do
      gated = create_game(:name => "Платная", :access_mode => "pass_required")
      create_access_pass(:game => gated, :team => team)
      sign_in(captain)
      get root_path

      row = doc.css(".game-row").find { |r| r.text.include?("Платная") }
      expect(row.text).to include("Доступ есть")
    end

    it "names the team and links its room" do
      sign_in(captain)
      get root_path

      expect(response.body).to include("«#{team.name}»")
      expect(doc.css("a").map { |a| a["href"] }).to include(team_room_path)
    end
  end
```

`spec/requests/game_entry_controls_classes_spec.rb`:

```ruby
require "rails_helper"

# shared/_game_entry_controls rendered bare button_to's; the home page reuses
# it, so it gained .btn classes. The dashboard renders it too: same text, now
# styled. Frozen Cucumber steps press these buttons by their text.
describe "the game-entry controls on the dashboard", type: :request do
  it "renders the apply button styled, with its text unchanged" do
    captain = create_user
    create_team(:captain => captain)
    game = create_game
    set_game_schedule!(game, :starts_at => 1.day.from_now)
    put login_path, :params => { :email => captain.email, :password => "1234" }

    get dashboard_path

    button = Nokogiri::HTML(response.body).css("button").find { |b| b.text.strip == "Подать заявку на регистрацию" }
    expect(button).to be_present
    expect(button["class"].split).to include("btn", "btn--go")
  end
end
```

- [ ] **Step 2: Run them — expect failures** (empty action slot; unstyled buttons). `bundle exec rspec spec/requests/home_page_spec.rb spec/requests/game_entry_controls_classes_spec.rb`

- [ ] **Step 3: Fill the action slot** — in `app/views/index/_next_game.html.erb`, replace `<div class="next-game-action"></div>` with this one line (no whitespace inside the div, so a guest's slot is truly empty and `.next-game-action:not(:empty)` adds no gap):

```erb
  <div class="next-game-action"><%= render("index/card_action", game: game) if logged_in? %></div>
```

Create `app/views/index/_card_action.html.erb` (signed-in visitors only; the author case mirrors `dashboard/_coming_games.html.erb`):

```erb
<% entry = home_entry_for(game) %>
<% if game.created_by?(current_user) %>
  <p class="home-note"><%= t("dashboard.coming_games.you_are_author") %></p>
<% elsif current_user.captain? %>
  <%= render "shared/game_entry_controls", game_entry: entry, game: game, team: current_user.team %>
<% elsif current_user.team %>
  <% if entry.nil? || %w[recalled canceled].include?(entry.status) %>
    <p class="home-note"><%= t("index.index.member_note") %></p>
  <% else %>
    <% text, css = home_status_tag(game, entry: entry) %>
    <span class="<%= css %>"><%= text %></span>
  <% end %>
<% else %>
  <%= link_to t("index.index.no_team"), teams_path, class: "link-tap" %>
<% end %>
```

- [ ] **Step 4: Style the shared controls** — `app/views/shared/_game_entry_controls.html.erb`, replace the whole file with (same branches, same text; buttons gain classes; text outcomes gain a `.notice` span):

```erb
<% if game_entry %>
  <% case game_entry.status %>
  <% when "new" %>
    <span class="notice"><%= t("shared.game_entry_controls.applied") %></span>
    <%= button_to t("shared.game_entry_controls.recall"), recall_game_entry_path(game_entry), class: "btn" %>
  <% when "accepted" %>
    <span class="notice"><%= t("shared.game_entry_controls.registered") %></span>
    <%= button_to t("shared.game_entry_controls.decline"), cancel_game_entry_path(game_entry), class: "btn" %>
  <% when "recalled", "rejected", "canceled", nil %>
    <% if game.can_request? %>
      <%= button_to t("shared.game_entry_controls.reapply"), reopen_game_entry_path(game_entry), class: "btn btn--go" %>
    <% else %>
      <span class="notice"><%= t("shared.game_entry_controls.entries_exceeded") %></span>
    <% end %>
  <% end %>
<% else %>
  <% if !game.can_request? %>
    <span class="notice"><%= t("shared.game_entry_controls.entries_exceeded") %></span>
  <% elsif game.registration_deadline and game.registration_deadline <= Time.now %>
    <span class="notice"><%= t("shared.game_entry_controls.deadline_passed") %></span>
  <% else %>
    <%= button_to t("shared.game_entry_controls.apply"), new_game_entry_path(:game_id => game.id, :team_id => team.id), class: "btn btn--go" %>
  <% end %>
<% end %>
```

- [ ] **Step 5: Run** `bundle exec rspec spec/requests/home_page_spec.rb spec/requests/game_entry_controls_classes_spec.rb spec/helpers/index_helper_spec.rb` — 0 failures — then `bundle exec cucumber features/dashboard features/games features/signup features/authentication` (isolated DB) — all green; these drive the dashboard's entry buttons by text.

- [ ] **Step 6: Commit**

```bash
git add app/views/index/_next_game.html.erb app/views/index/_card_action.html.erb app/views/shared/_game_entry_controls.html.erb spec/requests/home_page_spec.rb spec/requests/game_entry_controls_classes_spec.rb
git commit -m "Show signed-in players their team's status and the captain's actions

The next-game card renders the dashboard's game-entry controls for a
captain, a note for a member, a teams link for a player without a team,
and 'you are the author' for the game's author. The shared controls gain
.btn classes, which also styles them on the dashboard; their text is
unchanged."
```

---

### Task 6: Layout spec

**Files:** Create `spec/layout/home_layout_spec.rb`.

**Interfaces — Consumes:** the page (Tasks 4–5); `LayoutMeasurement#measure(html, width, height, script, tmp_name:)`.

- [ ] **Step 1: Write the spec**

```ruby
require "rails_helper"
require_relative "../support/layout_measurement"

# The home page, measured in a real browser in both themes, guest and signed
# in. Excluded from the default run (needs chrome-headless-shell);
# LAYOUT_SPECS=1. A missing browser raises.
describe "the home page, measured", :layout, type: :request do
  include LayoutMeasurement

  def page_html(signed_in:)
    captain = create_user
    team = create_team(:captain => captain)
    [["Ночной Бишкек", 1.day.from_now], ["Тайны старого города", 2.days.from_now],
     ["Очень длинное название игры, которое не должно сдвигать статус за край экрана", 3.days.from_now]].each do |name, at|
      game = create_game(:name => name)
      set_game_schedule!(game, :starts_at => at)
      create_game_entry(:game => game, :team => team, :status => "rejected") if name.start_with?("Очень")
    end
    put login_path, :params => { :email => captain.email, :password => "1234" } if signed_in
    get root_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  def probe(theme)
    <<~JS
      document.documentElement.setAttribute("data-theme", "#{theme}");
      var tappables = Array.prototype.slice.call(document.querySelectorAll(".home .btn, .home .link-tap, .home button"));
      var tags = Array.prototype.slice.call(document.querySelectorAll(".home .tag"));
      var nums = Array.prototype.slice.call(document.querySelectorAll(".timeline .num"));
      var home = document.querySelector(".home");
      var RESULT = {
        theme: document.documentElement.getAttribute("data-theme"),
        tappableCount: tappables.length,
        shortTaps: tappables.filter(function (el) { return el.getBoundingClientRect().height < 43.5; })
                            .map(function (el) { return el.textContent.trim(); }),
        wrappedTags: tags.filter(function (el) { return el.getClientRects().length > 1 ||
                                  el.getBoundingClientRect().height > parseFloat(getComputedStyle(el).lineHeight) * 1.5; })
                         .map(function (el) { return el.textContent.trim(); }),
        tagsInside: tags.every(function (el) { return el.getBoundingClientRect().right <= document.documentElement.clientWidth + 0.5; }),
        numCount: nums.length,
        numsCentred: nums.every(function (el) {
          var li = el.parentElement, line = getComputedStyle(li, "::before"), r = el.getBoundingClientRect(), lr = li.getBoundingClientRect();
          if (li === li.parentElement.lastElementChild) return true;
          var lineX = lr.left + parseFloat(line.left) + parseFloat(line.width) / 2;
          return Math.abs((r.left + r.width / 2) - lineX) <= 1;
        }),
        homeWidth: Math.round(home.getBoundingClientRect().width),
        remPx: parseFloat(getComputedStyle(document.documentElement).fontSize),
        hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    JS
  end

  [true, false].each do |signed_in|
    %w[dark light].each do |theme|
      { "phone" => [ 390, 680 ], "desktop" => [ 1280, 800 ] }.each do |name, (width, height)|
        context "#{signed_in ? "signed in" : "guest"}, #{theme} theme at #{width}x#{height} -- #{name}" do
          let(:m) { measure(page_html(:signed_in => signed_in), width, height, probe(theme), :tmp_name => "home-measure.html") }

          it "measured the theme it was asked for" do
            expect(m["theme"]).to eq(theme)
            expect(m["tappableCount"]).to be >= 2
          end

          it "keeps every button and link at least 44px tall" do
            expect(m["shortTaps"]).to eq([])
          end

          it "keeps every status tag on one line and on screen" do
            expect(m["wrappedTags"]).to eq([])
            expect(m["tagsInside"]).to be(true)
          end

          it "does not scroll sideways" do
            expect(m["hOverflow"]).to eq(0)
          end

          if name == "desktop"
            it "caps the content at 44rem" do
              expect(m["homeWidth"]).to be <= (44 * m["remPx"]).ceil
            end
          end

          unless signed_in
            it "centres each timeline number on its connecting line" do
              expect(m["numCount"]).to eq(3)
              expect(m["numsCentred"]).to be(true)
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run** `LAYOUT_SPECS=1 bundle exec rspec spec/layout/home_layout_spec.rb` (foreground). Fix CSS for any failure, never the probe. Expected count: 2 views × 2 themes × 2 sizes = 8 contexts; 4 base examples each + desktop cap (4) + guest timeline (4) = 40 examples, 0 failures.

- [ ] **Step 3: Mutation-check** (revert each precisely): (a) remove `white-space: nowrap; flex-shrink: 0;` from `.home .tag` → "keeps every status tag on one line" fails at 390; (b) remove `max-width: 44rem;` from `.home` → "caps the content" fails at desktop; (c) change `.timeline .num`'s `left: 0` to `left: 4px` → "centres each timeline number" fails.

- [ ] **Step 4: Commit**

```bash
git add spec/layout/home_layout_spec.rb
git commit -m "Measure the home page in both themes, guest and signed in"
```

---

### Task 7: Documentation

**Files:** Modify `CLAUDE.md`. **Consumes:** the orchestrator's measured RSpec count (given in the dispatch).

- [ ] **Step 1: Edit** — (a) the "Layout is invisible to both suites" bullet: `spec/layout/` holds **six** specs, adding `home_layout_spec.rb` (guest and signed in, both themes: tap sizes, status tags on one line, timeline centring, 44rem cap, no sideways scroll); the next new screen gets a seventh file. (b) i18n leaf count: re-measure with the command in CLAUDE.md and update the figure and date, adding one sentence to the history (this branch: 37 keys under `index.index.*`/`time.formats.*`). (c) RSpec count line: the orchestrator's number, "measured 2026-10-01 at the commit that carries this line". (d) A short new paragraph under "Form errors, the type scale, and the styleguide" (or a new "## The home page" section if that reads better): `/` is `UpcomingGames` + `IndexHelper` + `app/views/index/_*`; guests get hero/how-to-play/organizers, signed-in players only the games; the captain's card reuses `shared/_game_entry_controls`; the frozen anchors it must keep (the four listed in Global Constraints above, with their feature files); manual links use per-locale anchor keys verified by `spec/i18n_home_spec.rb`.

- [ ] **Step 2: Verify and commit** — run the leaf-count command and `bundle exec rspec spec/i18n_spec.rb`; then

```bash
git add CLAUDE.md
git commit -m "Document the home page, the sixth layout spec, and the new counts"
```

---

### Task 8: Verification and PR (orchestrator)

- [ ] Each alone, fresh isolated DB: full RSpec (record the count, hand it to Task 7 before its dispatch); `LAYOUT_SPECS=1 bundle exec rspec spec/layout` (six files); `bundle exec cucumber`; the inherited-contract run — 228 (226 passed, 2 undefined) / 2325; `git diff origin/master -- features/` empty.
- [ ] Before/after screenshots, both themes, 390 and 1280: home as guest; home as a signed-in captain; the dashboard (its entry buttons change). Compare the home page with Superdesign drafts `7eaa33ad` and `659ef6ac`.
- [ ] Push and open the PR "A home page that says what this is: players-first landing" (spec/plan paths, canvas link, before/after, gates, the dashboard button change, out-of-scope list).
