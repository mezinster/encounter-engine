# Quiz Bulk Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a game's author paste a structured block of questions and turn it into quiz levels, with a preview before anything is written.

**Architecture:** Two plain classes and one controller. `QuizImport` parses text into questions or line-numbered errors and touches no database. `QuizImport::Writer` turns parsed questions into levels inside one transaction, skipping ones the game already has. `QuizImportsController` is a thin two-step wrapper: parse → preview → confirm.

**Spec:** `docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md`.

**Tech Stack:** Rails 8, RSpec, sqlite, Cucumber.

## Global Constraints

- **Never edit `features/**/*.feature`.**
- `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"` before every command.
- i18n keys in **all four** locales, **inside the existing block** for that screen — a duplicate key at the same level is silently discarded.
- Hash rockets; plain fixture helpers, **no FactoryBot**.
- **No Turbo, no rails-ujs** — every mutating control is a real form.
- **Baselines on this branch: RSpec 1128 / 0 failures / 6 pending; Cucumber 232 scenarios / 2342 steps / 0 failures.** Re-measure rather than trusting these.
- **Refusal signal and protected property in SEPARATE examples** (RSpec fails fast).
- **A mutation must fail for the predicted reason**, and you must check it took effect. Negative assertions pass vacuously until seen to fail.

---

### Task 1: `QuizImport` — the parser

Pure text in, structured questions or line-numbered errors out. No database, no Rails, so its whole surface is testable without fixtures.

**Files:** create `app/models/quiz_import.rb`, `spec/models/quiz_import_spec.rb`.

**Interfaces:**
- Produces **`QuizImport.new(text)`** with `#questions` → array of `{ :text => String, :options => [{ :text => String, :correct => Boolean }] }`, `#errors` → array of `"строка N: …"` strings, and `#valid?` → `errors.empty?`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/quiz_import_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# Parses the format the owner already writes questions in -- the same block
# that was loaded into Викторина by a console script on 2026-08-08. See
# docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md.
RSpec.describe QuizImport do
  SAMPLE = <<~TEXT
    Какая порода собак считается миниатюрным родственником грейхаунда?
    A) Уиппет
    B) Той-терьер
    C) *Левретка
    D) Басенджи
    E) Салюки
    Какое устройство позволяет разговаривать по телефону без удерживания аппарата у уха?
    A) *Гарнитура
    B) Автомагнитола
  TEXT

  it "reads each question with its options in order" do
    parsed = QuizImport.new(SAMPLE)

    expect(parsed).to be_valid
    expect(parsed.questions.size).to eq(2)
    expect(parsed.questions.first[:text]).to start_with("Какая порода собак")
    expect(parsed.questions.first[:options].map { |o| o[:text] })
      .to eq(%w[Уиппет Той-терьер Левретка Басенджи Салюки])
  end

  it "marks the asterisked option correct and strips the asterisk" do
    parsed = QuizImport.new(SAMPLE)

    correct = parsed.questions.first[:options].select { |o| o[:correct] }
    expect(correct.map { |o| o[:text] }).to eq(["Левретка"])
  end

  # Two asterisks is the checkbox case. The parser only reports how many are
  # correct; Question#single_choice? turns that into radio vs checkbox at
  # render time, and answer_options! requires set equality.
  it "accepts more than one correct option" do
    parsed = QuizImport.new(<<~TEXT)
      Что из этого — города?
      A) *Минск
      B) Ручка
      C) *Тбилиси
    TEXT

    expect(parsed).to be_valid
    expect(parsed.questions.first[:options].count { |o| o[:correct] }).to eq(2)
  end

  it "ignores blank lines between questions" do
    parsed = QuizImport.new("Вопрос?\n\nA) *Да\n\nB) Нет\n")

    expect(parsed).to be_valid
    expect(parsed.questions.first[:options].size).to eq(2)
  end

  # Any letter, not only A-E: a list of six options must not silently lose its
  # sixth.
  it "accepts option letters past E" do
    parsed = QuizImport.new("Вопрос?\nA) *Раз\nB) Два\nF) Шесть\n")

    expect(parsed.questions.first[:options].map { |o| o[:text] }).to eq(%w[Раз Два Шесть])
  end

  describe "refusals" do
    it "refuses a question with no correct option, naming the line" do
      parsed = QuizImport.new("Вопрос?\nA) Раз\nB) Два\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to include("1")
    end

    it "refuses a question with fewer than two options" do
      parsed = QuizImport.new("Вопрос?\nA) *Раз\n")

      expect(parsed).not_to be_valid
    end

    it "refuses option lines that appear before any question" do
      parsed = QuizImport.new("A) *Раз\nB) Два\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to include("1")
    end

    it "reports every bad question, not just the first" do
      parsed = QuizImport.new("Первый?\nA) Раз\nB) Два\nВторой?\nC) Три\nD) Четыре\n")

      expect(parsed.errors.size).to eq(2)
    end

    # An empty paste is a refusal, not an empty success: importing nothing
    # silently would look like it worked.
    it "refuses empty text" do
      expect(QuizImport.new("   \n\n")).not_to be_valid
    end
  end
end
```

- [ ] **Step 2: Run it — every example fails on the missing constant.**

- [ ] **Step 3: Implement**

Create `app/models/quiz_import.rb`. A plain class, not an AR model — it exists to turn text into a structure and has no table:

```ruby
# -*- encoding : utf-8 -*-
#
# Parses the block format the owner already writes quizzes in:
#
#   Вопрос?
#   A) Вариант
#   B) *Правильный вариант
#
# A line that is not an option line starts a new question. A leading * marks a
# correct option. Any single letter is accepted as a label, not only A-E, so a
# list running past E does not silently lose its tail.
#
# Deliberately knows nothing about the database: it turns text into a
# structure and reports what it could not read. QuizImport::Writer does the
# writing, so the parser's whole surface is testable without fixtures.
class QuizImport
  OPTION_LINE = /\A(?<label>[[:alpha:]])\)\s*(?<text>.+)\z/

  attr_reader :questions, :errors

  def initialize(text)
    @questions = []
    @errors = []
    parse(text.to_s)
  end

  def valid?
    errors.empty?
  end

  private

  def parse(text)
    current = nil

    text.each_line.with_index(1) do |raw, number|
      line = raw.strip
      next if line.empty?

      if (match = OPTION_LINE.match(line))
        if current.nil?
          add_error(number, :option_before_question)
          next
        end

        option_text = match[:text].strip
        current[:options] << { :text => option_text.sub(/\A\*\s*/, ""),
                               :correct => option_text.start_with?("*") }
      else
        current = { :text => line, :options => [], :line => number }
        @questions << current
      end
    end

    validate_questions
    add_error(1, :empty) if @questions.empty? && @errors.empty?
    @questions.each { |question| question.delete(:line) }
  end

  # Every bad question is reported, not just the first: an author fixing a
  # paste one error per round-trip is why bulk import stops being faster than
  # the per-level form.
  def validate_questions
    @questions.each do |question|
      add_error(question[:line], :too_few_options) if question[:options].size < 2
      add_error(question[:line], :no_correct_option) if question[:options].none? { |o| o[:correct] }
    end
  end

  def add_error(line, key)
    @errors << I18n.t("quiz_imports.errors.#{key}", :line => line)
  end
end
```

- [ ] **Step 4: Add the four error locale keys** in all four files, under a new top-level `quiz_imports:` block (this is a new screen, so a new block is correct — do not nest it inside an existing one):

`ru`: `option_before_question: "строка %{line}: варианты идут до текста вопроса"` · `too_few_options: "строка %{line}: у вопроса меньше двух вариантов"` · `no_correct_option: "строка %{line}: не отмечен правильный вариант (звёздочкой)"` · `empty: "Текст пуст — нечего импортировать"`

`en`: `"line %{line}: options appear before any question text"` · `"line %{line}: the question has fewer than two options"` · `"line %{line}: no correct option is marked with an asterisk"` · `"The text is empty — there is nothing to import"`

`uk`: `"рядок %{line}: варіанти йдуть до тексту питання"` · `"рядок %{line}: у питання менше двох варіантів"` · `"рядок %{line}: не позначено правильний варіант (зірочкою)"` · `"Текст порожній — нема чого імпортувати"`

`ka`: `"ხაზი %{line}: ვარიანტები კითხვის ტექსტამდეა"` · `"ხაზი %{line}: კითხვას ორზე ნაკლები ვარიანტი აქვს"` · `"ხაზი %{line}: სწორი ვარიანტი ვარსკვლავით არ არის მონიშნული"` · `"ტექსტი ცარიელია — იმპორტისთვის არაფერია"`

- [ ] **Step 5: Run the spec and `spec/i18n_spec.rb`.** Both green.

- [ ] **Step 6: Mutate** — each observed failing, then restored:
  1. Drop the `option_before_question` branch → that example fails.
  2. Change `size < 2` to `size < 1` → the too-few-options example fails.
  3. Drop the `no_correct_option` check → that example fails.
  4. Change `[[:alpha:]]` to `[A-E]` → "accepts option letters past E" fails.
  5. Make `validate_questions` `return` after the first error → "reports every bad question" fails.

- [ ] **Step 7: Commit.**

---

### Task 2: `QuizImport::Writer` — turning parsed questions into levels

**Files:** create `app/models/quiz_import/writer.rb`, `spec/models/quiz_import/writer_spec.rb`.

**Interfaces:**
- Consumes `QuizImport#questions`.
- Produces **`QuizImport::Writer.new(game, questions)`** with `#skipped` and `#to_add` (computed without writing), and `#import!` which creates the levels in one transaction and returns the created levels.

Each added question produces, mirroring the 71 levels already in `Викторина`:

- a `Level` — `name: "Вопрос N"` (N continuing from `game.levels.maximum(:position)`), `text:` the question, `any_code_passes: true`, `wrong_answer_penalty: 0`;
- one `Question`, plus an `Answer` with `value: N.to_s`;
- the `Option` rows in order.

**The vestigial answer is load-bearing, not cosmetic.** `Level#correct_answer` reads
`questions.first.answers.first.value` with no safe navigation and `app/views/levels/show.html.erb:26`
renders it, so a quiz level without one **500s the level page**. One spec below pins that end to end
rather than asserting the row exists.

- [ ] **Step 1: Write the failing spec.** Cover: appends after existing levels with continuing numbering; sets the level fields; creates one option per parsed option with `is_correct` matching; a two-asterisk question yields `single_choice? == false`; **skips a question whose text the game already has** (whitespace- and case-insensitively) and reports it in `skipped`; `to_add`/`skipped` compute without writing (assert `Level.count` unchanged); `import!` is atomic (stub one `Level` save to raise and assert nothing was created); and — the end-to-end one — after `import!`, `level.correct_answer` returns a value rather than raising.

- [ ] **Step 2: Run it — fails on the missing constant.**

- [ ] **Step 3: Implement**, with the normalisation rule (`gsub(/\s+/, " ").strip.downcase`) matching the console script, and the whole of `import!` wrapped in `Level.transaction`.

- [ ] **Step 4: Run the spec.**

- [ ] **Step 5: Mutate** — drop the dedup and confirm the skip example fails; drop the `Answer` creation and confirm the `correct_answer` example fails (**check it fails on the raise, not on a count**); remove the transaction and confirm the atomicity example fails.

- [ ] **Step 6: Commit.**

---

### Task 3: `QuizImportsController` — paste, preview, confirm

**Files:** create `app/controllers/quiz_imports_controller.rb`, `app/views/quiz_imports/new.html.erb`, `app/views/quiz_imports/preview.html.erb`; modify `config/routes.rb`, `app/views/games/show.html.erb`, the four locale files; create `spec/requests/quiz_imports_spec.rb`.

**Routes**, inside the existing `resources :games do` block beside `resources :levels`:

```ruby
    resource :quiz_import, only: [ :new, :create ]
```

**The controller is one action with a preview branch**, so no server-side state carries between steps — the pasted text rides a hidden field:

- `new` renders the textarea.
- `create` parses. Invalid → re-render `new` with the errors and the text preserved. Valid and **no** `params[:confirm]` → render `preview`. Valid **with** `params[:confirm]` → `Writer#import!`, redirect to the game with a reconciliation notice.

**Filters, matching `LevelsController` exactly:** `find_game`, `ensure_author`, `ensure_editing_not_locked`, `ensure_game_was_not_started`.

- [ ] **Step 1: Write the failing request spec.** Cover: the author reaches `new`; a non-author is refused; a guest is refused; a superadmin reaches it (they inherit through `ensure_author`); posting valid text **without** confirm renders the preview and **creates nothing** (`expect { }.not_to change(Level, :count)`); posting **with** confirm creates the levels and redirects; posting invalid text re-renders with the error text and creates nothing; and posting to a **started** game is refused. Keep the refusal signal and the "creates nothing" property in **separate examples**.

- [ ] **Step 2: Run it — fails on the missing route.**

- [ ] **Step 3: Implement** the route, controller, both views and the locale keys. The preview view lists each question with its correct options marked, the skipped ones, and the reconciliation line; its confirm button is a real form carrying the text in a hidden field.

- [ ] **Step 4: Run the specs.**

- [ ] **Step 5: Mutate** — remove `ensure_author` and confirm the non-author example fails; remove `ensure_game_was_not_started` and confirm the started-game example fails; make `create` import without checking `params[:confirm]` and confirm the preview-writes-nothing example fails.

- [ ] **Step 6: Commit.**

---

### Task 4: The entry point, and verification

- [ ] **Step 1:** Add the link on `app/views/games/show.html.erb`, beside the existing `add_level` link (line 61), under the same `if ! @game.started?` condition. Label it `t("games.show.import_questions")` in all four locales — **re-read the frozen scenarios that inspect the game page before choosing the wording**, and confirm the label collides with none of them.

- [ ] **Step 2:** A request spec asserting the link appears for the author on an unstarted game and not once it has started. Mutate the condition to confirm the second example can fail.

- [ ] **Step 3:** Rebase onto master, `bin/rails db:test:prepare`, full `bundle exec rspec` and `bundle exec cucumber` — 0 failures, and `git diff origin/master --stat -- features/` prints nothing.

- [ ] **Step 4:** Push and `gh pr create --body-file`. The body must state: why the feature exists (the console script it replaces), the three owner decisions, the format and what is rejected, why the vestigial answer is load-bearing, and the mutation checks performed with their observed failures.
