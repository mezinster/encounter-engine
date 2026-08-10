# Quest Mode and Authorship Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the bulk importer to produce ordinary code levels alongside quiz levels, and let a game's author hand it to another player (with a superadmin override).

**Architecture:** Two independent halves that share no code. **Part A (Tasks 1–4)** changes the importer's parser and writer: a question block with exactly one option line becomes a code level rather than a quiz level, and a task may span several lines. No play-path code changes — a question with no correct options is already what `Level#find_question_by_answer` matches. **Part B (Tasks 5–8)** adds `Game#transfer_authorship_to!` as the single writer of `author_id` after creation, called from an author-facing form on the game page and from the superadmin console, mirroring `Team#set_captain!`.

**Tech Stack:** Rails 8, Ruby 3.3.12, RSpec (legacy `should` syntax enabled, prefer `expect`), sqlite in dev/test, plain ERB — **no Turbo, no rails-ujs**, so every state-changing control is a real `form_with`/`button_to`.

**Spec:** `docs/superpowers/specs/2026-08-10-quest-mode-and-authorship-design.md`

## Global Constraints

- **Ruby is not on `PATH` in non-login shells.** Prefix every command with:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`
- **Never edit any file under `features/`.** Not even whitespace. This plan touches none.
- **Every new user-facing string needs a key in all seven locale files**: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml`. `spec/i18n_spec.rb` enforces exact `ru`↔`en` parity; the other five must be a subset. The test environment sets `raise_on_missing_translations`, so a missing key raises rather than degrading.
- **Turkish never lets a case suffix land on an interpolated name.** Any key carrying `%{nickname}` or `%{game}` in `tr.yml` puts the suffix on a common noun (`«%{game}» adlı oyuna`) or uses a colon form.
- **Never add a Ruby-side `.upcase`/`.downcase` to user-facing text.**
- **Hash-rocket style** (`:key => value`) throughout, matching the surrounding files.
- Code, identifiers and comments in **English**; user-facing strings in **Russian** (via `t()`).
- Commit after every task. Branch off `master`; do not push or open a PR unless asked.

---

# Part A — Quest mode in the importer

### Task 1: Let a task span several lines

The parser's rule today is *"any line that is not an option line starts a new question"*. That is only correct because quiz questions are one line long. A three-line quest task would silently become three questions.

The new rule: **a text line starts a new block only if the previous meaningful line was an option line, or it is the first line.** Consecutive text lines join with `\n`. This is backward compatible by construction — in every existing paste each question line follows an option line, so every block boundary falls exactly where it did before.

**Files:**
- Modify: `app/models/quiz_import.rb:33-61` (the `parse` method)
- Test: `spec/models/quiz_import_spec.rb`

**Interfaces:**
- Produces: `QuizImport#questions` — unchanged shape, an array of `{ :text => String, :options => Array }`. `:text` may now contain `\n`.

- [ ] **Step 1: Write the failing tests**

Add to `spec/models/quiz_import_spec.rb`, immediately before the `describe "refusals"` block:

```ruby
  # A quest task is prose and runs to several lines. The rule that makes this
  # work -- a text line starts a new block only when it follows an OPTION line
  # -- is also what keeps every existing one-line paste parsing identically,
  # because in those every text line does follow an option line.
  describe "multi-line task text" do
    it "joins consecutive text lines into one block" do
      parsed = QuizImport.new(<<~TEXT)
        Дойдите до угла Киевской и Чуй.
        На стене дома — табличка с годом постройки.
        Сложите цифры года.
        A) *23
        B) 24
      TEXT

      expect(parsed).to be_valid
      expect(parsed.questions.size).to eq(1)
      expect(parsed.questions.first[:text])
        .to eq("Дойдите до угла Киевской и Чуй.\nНа стене дома — табличка с годом постройки.\nСложите цифры года.")
    end

    it "starts a new block at the first text line after an option line" do
      parsed = QuizImport.new(<<~TEXT)
        Первый.
        Ещё строка первого.
        A) *Да
        B) Нет
        Второй.
        A) *Да
        B) Нет
      TEXT

      expect(parsed.questions.size).to eq(2)
      expect(parsed.questions.first[:text]).to eq("Первый.\nЕщё строка первого.")
      expect(parsed.questions.last[:text]).to eq("Второй.")
    end

    # Blank lines were already ignored. They must stay ignored rather than
    # becoming a block separator, or a paste whose paragraphs are spaced out
    # would split into unanswerable fragments.
    it "does not treat a blank line as a block boundary" do
      parsed = QuizImport.new("Первая строка.\n\nВторая строка.\nA) *Да\nB) Нет\n")

      expect(parsed.questions.size).to eq(1)
      expect(parsed.questions.first[:text]).to eq("Первая строка.\nВторая строка.")
    end

    # THE regression guard for this task. The existing 71-question master list
    # is one-line questions throughout; if this changes, the owner's real
    # workflow has broken.
    it "parses an existing one-line paste exactly as before" do
      parsed = QuizImport.new(<<~TEXT)
        Первый?
        A) *Да
        B) Нет
        Второй?
        A) Да
        B) *Нет
      TEXT

      expect(parsed.questions.map { |q| q[:text] }).to eq([ "Первый?", "Второй?" ])
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import_spec.rb -e "multi-line task text"
```

Expected: FAIL. The first three examples fail on question count (each text line becomes its own question); the regression example passes already, which is the point of it.

- [ ] **Step 3: Change the block-boundary rule**

Replace the `parse` method in `app/models/quiz_import.rb` with:

```ruby
  def parse(text)
    current = nil
    previous_was_option = false

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
        previous_was_option = true
      else
        # A text line CONTINUES the block it is in unless an option line has
        # already been seen for that block. That is what lets a quest task run
        # to several lines, and it is also why every paste written before this
        # change parses identically: those have one-line questions, so every
        # text line in them follows an option line and still starts a block.
        #
        # Blank lines are skipped above and therefore do not separate blocks
        # either -- a paste with spaced-out paragraphs must not fragment.
        if current.nil? || previous_was_option
          current = { :text => line, :options => [], :line => number }
          @questions << current
        else
          current[:text] = "#{current[:text]}\n#{line}"
        end
        previous_was_option = false
      end
    end

    validate_questions
    add_error(1, :empty) if @questions.empty? && @errors.empty?

    # The line number is scaffolding for error messages, not part of the
    # parsed shape the writer consumes.
    @questions.each { |question| question.delete(:line) }
  end
```

- [ ] **Step 4: Run the whole parser and importer suite**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import_spec.rb spec/models/quiz_import/writer_spec.rb spec/requests/quiz_imports_spec.rb
```

Expected: PASS, all examples, 0 failures. If anything red appears here it is a real regression in the existing format — stop and investigate rather than adjusting the new examples.

- [ ] **Step 5: Commit**

```bash
git add app/models/quiz_import.rb spec/models/quiz_import_spec.rb
git commit -m "Let an imported task run to several lines

A text line now continues its block unless an option line has already
been seen for that block. Every existing paste has one-line questions,
so every text line in one follows an option line and still starts a
block -- the boundaries fall exactly where they fell before, which a
regression example pins."
```

---

### Task 2: Decide quest or quiz per block

**Files:**
- Modify: `app/models/quiz_import.rb` (add `assign_modes`, rewrite `validate_questions`, adjust `parse`)
- Modify: `spec/models/quiz_import_spec.rb:80-84` — the existing `"refuses a question with fewer than two options"` example encodes the rule being replaced and must go
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — drop `too_few_options`, add `no_answer_line` and `blank_code`
- Test: `spec/models/quiz_import_spec.rb`

**Interfaces:**
- Produces: each entry of `QuizImport#questions` gains `:mode` — `:quest` or `:quiz`. A `:quest` entry also carries `:code` (a `String`). Task 3's writer consumes both.

- [ ] **Step 1: Write the failing tests**

First **delete** this existing example from `spec/models/quiz_import_spec.rb` (it asserts the rule being replaced):

```ruby
    it "refuses a question with fewer than two options" do
      parsed = QuizImport.new("Вопрос?\nA) *Раз\n")

      expect(parsed).not_to be_valid
    end
```

Then add a new `describe` block immediately after the `"multi-line task text"` block from Task 1:

```ruby
  # One option line is a code, two or more is a choice. The block decides for
  # itself, so a single paste may build both kinds.
  describe "quest blocks" do
    it "reads a single option line as a code" do
      parsed = QuizImport.new("Найдите табличку на доме 12.\nA) ФОНАРЬ\n")

      expect(parsed).to be_valid
      expect(parsed.questions.first[:mode]).to eq(:quest)
      expect(parsed.questions.first[:code]).to eq("ФОНАРЬ")
    end

    # Authors habitually mark the correct answer. On a lone option there is
    # nothing else it could mean, so it is stripped rather than refused.
    it "strips a leading asterisk from a lone code" do
      parsed = QuizImport.new("Найдите табличку.\nA) *ФОНАРЬ\n")

      expect(parsed).to be_valid
      expect(parsed.questions.first[:code]).to eq("ФОНАРЬ")
    end

    it "still reads two or more options as a quiz" do
      parsed = QuizImport.new("Столица Беларуси?\nA) Брест\nB) *Минск\n")

      expect(parsed.questions.first[:mode]).to eq(:quiz)
      expect(parsed.questions.first[:code]).to be_nil
    end

    it "reads a mixed paste, deciding block by block" do
      parsed = QuizImport.new(<<~TEXT)
        Найдите табличку.
        A) ФОНАРЬ
        Столица Беларуси?
        A) Брест
        B) *Минск
        Сколько ступеней?
        A) 33
      TEXT

      expect(parsed).to be_valid
      expect(parsed.questions.map { |q| q[:mode] }).to eq([ :quest, :quiz, :quest ])
    end
  end
```

And add to the existing `describe "refusals"` block, replacing the example deleted above:

```ruby
    it "refuses a block with no option line at all, naming the line" do
      parsed = QuizImport.new("Просто текст без ответа\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to eq(I18n.t("quiz_imports.errors.no_answer_line", :line => 1))
    end

    # A) * parses as an option whose text is "*", which strips to nothing.
    # Left unchecked this reaches Answer's presence validation INSIDE the
    # import transaction, turning a typo into a 500 instead of a
    # line-numbered rejection.
    it "refuses a quest block whose code is blank after the asterisk" do
      parsed = QuizImport.new("Найдите табличку.\nA) *\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to eq(I18n.t("quiz_imports.errors.blank_code", :line => 1))
    end

    # A quiz block still needs one. Narrowed to blocks with two or more
    # options -- on a lone option an asterisk is now optional.
    it "still refuses a two-option block with no asterisk" do
      parsed = QuizImport.new("Вопрос?\nA) Раз\nB) Два\n")

      expect(parsed).not_to be_valid
      expect(parsed.errors.first).to eq(I18n.t("quiz_imports.errors.no_correct_option", :line => 1))
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import_spec.rb
```

Expected: FAIL — `:mode` is nil everywhere, and the two new refusal examples raise `I18n::MissingTranslationData` for the keys that do not exist yet.

- [ ] **Step 3: Add and remove the locale keys**

In **all seven** files, inside the existing `quiz_imports: → errors:` block, **delete the `too_few_options:` line** (nothing will reference it any more) and add the two new keys.

`config/locales/ru.yml`:
```yaml
      no_answer_line: "строка %{line}: у задания нет ответа — добавьте строку вида «A) КОД»"
      blank_code: "строка %{line}: код пустой"
```

`config/locales/en.yml`:
```yaml
      no_answer_line: "line %{line}: the task has no answer — add a line in the form “A) CODE”"
      blank_code: "line %{line}: the code is empty"
```

`config/locales/uk.yml`:
```yaml
      no_answer_line: "рядок %{line}: у завдання немає відповіді — додайте рядок виду «A) КОД»"
      blank_code: "рядок %{line}: код порожній"
```

`config/locales/be.yml`:
```yaml
      no_answer_line: "радок %{line}: у задання няма адказу — дадайце радок выгляду «A) КОД»"
      blank_code: "радок %{line}: код пусты"
```

`config/locales/pl.yml`:
```yaml
      no_answer_line: "wiersz %{line}: zadanie nie ma odpowiedzi — dodaj wiersz w postaci „A) KOD”"
      blank_code: "wiersz %{line}: kod jest pusty"
```

`config/locales/tr.yml`:
```yaml
      no_answer_line: "satır %{line}: görevin yanıtı yok — “A) KOD” biçiminde bir satır ekleyin"
      blank_code: "satır %{line}: kod boş"
```

`config/locales/ka.yml`:
```yaml
      no_answer_line: "სტრიქონი %{line}: დავალებას პასუხი არ აქვს — დაამატეთ სტრიქონი სახით «A) კოდი»"
      blank_code: "სტრიქონი %{line}: კოდი ცარიელია"
```

- [ ] **Step 4: Add mode detection and rewrite validation**

In `app/models/quiz_import.rb`, insert `assign_modes` into `parse` between the loop and `validate_questions`:

```ruby
    assign_modes
    validate_questions
```

Then add `assign_modes` and replace `validate_questions` entirely:

```ruby
  # One option line is a code, two or more is a choice. Derived here rather
  # than in the writer so the whole of the format's surface stays testable
  # without fixtures.
  #
  # A block with NO options is labelled :quiz and rejected a moment later by
  # validate_questions. The label is never read, because an invalid paste never
  # reaches the writer.
  def assign_modes
    @questions.each do |question|
      question[:mode] = question[:options].size == 1 ? :quest : :quiz
      question[:code] = question[:options].first[:text] if question[:mode] == :quest
    end
  end

  # Every bad question is reported, not just the first. An author fixing one
  # error per round-trip is why bulk import stops being faster than adding
  # levels one at a time.
  def validate_questions
    @questions.each do |question|
      if question[:options].empty?
        add_error(question[:line], :no_answer_line)
      elsif question[:mode] == :quest
        # A) * parses as an option whose text is "*" and strips to nothing.
        # Caught here rather than at Answer's presence validation, which would
        # raise RecordInvalid inside the import transaction -- a 500 where the
        # author should have got a line number.
        add_error(question[:line], :blank_code) if question[:code].to_s.strip.empty?
      elsif question[:options].none? { |option| option[:correct] }
        add_error(question[:line], :no_correct_option)
      end
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 0 failures. `spec/i18n_spec.rb` proves the seven files still agree.

- [ ] **Step 6: Confirm nothing downstream referenced the deleted key**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
grep -rn "too_few_options" app config spec
```

Expected: **no output.** Any hit is a reference to a key that no longer exists and will raise at runtime.

- [ ] **Step 7: Commit**

```bash
git add app/models/quiz_import.rb spec/models/quiz_import_spec.rb config/locales
git commit -m "Read a single-option block as a code, not a quiz

One option line is a code, two or more is a choice, decided per block so
a single paste can build both kinds. too_few_options said 'fewer than
two options', which stops being true the moment one is legal, so it is
replaced rather than reworded: no_answer_line for a block with none, and
blank_code for 'A) *', which would otherwise reach Answer's presence
validation inside the import transaction and 500."
```

---

### Task 3: Write quest levels

**Files:**
- Modify: `app/models/quiz_import/writer.rb:57-81` (split `create_level`)
- Test: `spec/models/quiz_import/writer_spec.rb`

**Interfaces:**
- Consumes: question hashes from Task 2 — `{ :text, :options, :mode, :code }`. A hash with no `:mode` key takes the quiz branch, which is why the existing writer specs need no edit.
- Produces: `Writer#import!` returns the created `Level` records, unchanged.

- [ ] **Step 1: Write the failing tests**

Add a `quest` helper next to the existing `question` helper at the top of `spec/models/quiz_import/writer_spec.rb`:

```ruby
  def quest(text, code)
    { :text => text,
      :mode => :quest,
      :code => code,
      :options => [ { :text => code, :correct => false } ] }
  end
```

Then add this `describe` block after the existing `describe "#import!"` block:

```ruby
  # The standard encounter shape: a task and a code, indistinguishable from a
  # level typed in on the per-level screen.
  describe "quest levels" do
    let(:game) { create_game }

    it "names them «Уровень N» and keeps the position numbering shared" do
      QuizImport::Writer.new(game, [ quest("Найдите табличку", "ФОНАРЬ"),
                                     question("Столица?", "*Минск", "Брест") ]).import!

      levels = game.levels.reload.order(:position)
      expect(levels.map(&:name)).to eq([ "Уровень 1", "Вопрос 2" ])
      expect(levels.map(&:position)).to eq([ 1, 2 ])
    end

    it "stores the code as the level's answer and creates no options" do
      QuizImport::Writer.new(game, [ quest("Найдите табличку", "ФОНАРЬ") ]).import!

      level = game.levels.reload.first
      expect(level.questions.count).to eq(1)
      expect(level.questions.first.options).to be_empty
      expect(level.correct_answer).to eq("ФОНАРЬ")
    end

    # The whole design rests on this: no correct options means Question#quiz?
    # is false, which is what routes the level down the code path instead of
    # the options path.
    it "produces a level that is not a quiz" do
      QuizImport::Writer.new(game, [ quest("Найдите табличку", "ФОНАРЬ") ]).import!

      expect(game.levels.reload.first.quiz?).to be false
    end

    it "keeps the multi-line task text intact" do
      QuizImport::Writer.new(game, [ quest("Первая строка.\nВторая строка.", "23") ]).import!

      expect(game.levels.reload.first.text).to eq("Первая строка.\nВторая строка.")
    end

    # THE end-to-end one. A writer assertion alone would pass on a level no
    # team could ever complete: this is the only example that crosses the
    # quiz?/reject boundary the two modes are separated by, through the same
    # method a real submission goes through.
    it "accepts its code through the ordinary play path" do
      QuizImport::Writer.new(game, [ quest("Найдите табличку", "ФОНАРЬ") ]).import!
      level = game.levels.reload.first
      passing = create_game_passing(:level => level)

      expect(passing.check_answer!("ФОНАРЬ")).to be true
    end

    it "rejects a wrong code through the ordinary play path" do
      QuizImport::Writer.new(game, [ quest("Найдите табличку", "ФОНАРЬ") ]).import!
      level = game.levels.reload.first
      passing = create_game_passing(:level => level)

      expect(passing.check_answer!("НЕВЕРНО")).to be false
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import/writer_spec.rb -e "quest levels"
```

Expected: FAIL — levels are named «Вопрос N», options are created from the code, and `correct_answer` returns the level number instead of the code.

- [ ] **Step 3: Split `create_level`**

In `app/models/quiz_import/writer.rb`, replace the `create_level` private method with three methods:

```ruby
    def create_level(question, number)
      question[:mode] == :quest ? create_quest_level(question, number) : create_quiz_level(question, number)
    end

    # The standard encounter shape. No options at all, which is what makes
    # Question#quiz? false and therefore routes the level through
    # Level#find_question_by_answer -- the same path a hand-made code level
    # takes. Nothing on the play side needed changing for this.
    def create_quest_level(question, number)
      level = game.levels.create!(
        :name => "Уровень #{number}",
        :text => question[:text],
        :any_code_passes => true,
        :wrong_answer_penalty => 0
      )

      level.questions.create!.answers.create!(:value => question[:code])

      level
    end

    def create_quiz_level(question, number)
      level = game.levels.create!(
        :name => "Вопрос #{number}",
        :text => question[:text],
        :any_code_passes => true,
        :wrong_answer_penalty => 0
      )

      record = level.questions.create!

      # Not decoration. Level#correct_answer reads
      # questions.first.answers.first.value with no safe navigation and
      # app/views/levels/show.html.erb renders it, so a quiz level with no
      # answer row 500s the level page. The value itself is never read by the
      # quiz path -- GamePassing#answer_options! compares option ids -- which
      # is why the level number serves as well as anything, and is what the
      # hand-made levels already carry.
      record.answers.create!(:value => number.to_s)

      question[:options].each do |option|
        record.options.create!(:text => option[:text], :is_correct => option[:correct])
      end

      level
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/quiz_import/writer_spec.rb
```

Expected: PASS, 0 failures — including every pre-existing example, which still take the quiz branch because their hashes carry no `:mode`.

- [ ] **Step 5: Commit**

```bash
git add app/models/quiz_import/writer.rb spec/models/quiz_import/writer_spec.rb
git commit -m "Write quest blocks as code levels

One question, one answer holding the code, no options -- which makes
Question#quiz? false and routes the level through
Level#find_question_by_answer, the same path a hand-made code level
takes. No play-side change was needed, and the spec proves it by
submitting the code through GamePassing#check_answer! rather than
asserting on the rows."
```

---

### Task 4: Show quest blocks in the preview, and say "levels" on screen

**Files:**
- Modify: `app/views/quiz_imports/preview.html.erb:29-41`
- Modify: `app/views/quiz_imports/new.html.erb` — render the option-line note
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — add `quiz_imports.preview.code_label` and `quiz_imports.new.option_line_note`; change `quiz_imports.new.title`, `quiz_imports.new.intro`, `quiz_imports.new.example`, `games.show.import_questions`
- Test: `spec/requests/quiz_imports_spec.rb`

**Interfaces:**
- Consumes: `question[:mode]` and `question[:code]` from Task 2, via `@writer.to_add` / `@writer.skipped`.

- [ ] **Step 1: Write the failing tests**

Add to `spec/requests/quiz_imports_spec.rb`, inside the existing `describe "previewing"` block:

```ruby
    it "shows the code for a quest block and the options for a quiz block" do
      sign_in(author)

      post game_quiz_import_path(game),
           :params => { :text => "Найдите табличку.\nA) ФОНАРЬ\nСтолица?\nA) Брест\nB) *Минск\n" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("quiz_imports.preview.code_label"))
      expect(response.body).to include("ФОНАРЬ")
      expect(response.body).to include("Минск")
    end
```

And add a new top-level `describe` block at the end of the file, before the final `end`:

```ruby
  # A mixed paste is the whole point of deciding per block.
  describe "confirming a mixed paste" do
    it "creates a code level and a quiz level side by side" do
      sign_in(author)

      post game_quiz_import_path(game),
           :params => { :text => "Найдите табличку.\nA) ФОНАРЬ\nСтолица?\nA) Брест\nB) *Минск\n",
                        :confirm => "1" }

      levels = game.levels.reload.order(:position)
      expect(levels.map(&:name)).to eq([ "Уровень 1", "Вопрос 2" ])
      expect(levels.map(&:quiz?)).to eq([ false, true ])
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/quiz_imports_spec.rb
```

Expected: FAIL — `quiz_imports.preview.code_label` raises `I18n::MissingTranslationData`.

- [ ] **Step 3: Add and change the locale keys**

Add `code_label:` inside the existing `quiz_imports: → preview:` block; add `option_line_note:` and **replace** the values of `title:`, `intro:` and `example:` inside `quiz_imports: → new:`; and replace the value of `games.show.import_questions`. All seven files.

`option_line_note` is the on-screen warning the design calls for in §A3: `OPTION_LINE` matches *any* single letter followed by `)`, so the second line of a task beginning `б) ...` is read as the code rather than as prose. The hazard predates this work; multi-line text makes it easier to reach, and it is documented rather than escaped because an escape character would be new syntax for a case no author has hit yet.

`config/locales/ru.yml`:
```yaml
      code_label: "код:"
```
```yaml
      title: "Импорт уровней в игру «%{game}»"
      intro: "Вставьте задания. Строка (или несколько строк подряд) — текст задания, затем ответы. Один ответ «A) КОД» — обычный уровень с кодом. Два и больше — вопрос с вариантами; правильный отметьте звёздочкой, две звёздочки — несколько правильных."
      example: "Дойдите до угла Киевской и Чуй.\nНа стене дома — табличка с годом постройки.\nA) 1967\n\nКакой город является столицей Беларуси?\nA) Брест\nB) Гродно\nC) *Минск"
      option_line_note: "Строка вида «буква) текст» всегда читается как ответ — даже посреди задания. Начинать с неё строку задания нельзя."
```
```yaml
      import_questions: "Импорт уровней списком"
```

`config/locales/en.yml`:
```yaml
      code_label: "code:"
```
```yaml
      title: "Import levels into “%{game}”"
      intro: "Paste your tasks. One line (or several in a row) is the task text, then the answers. A single answer “A) CODE” makes an ordinary code level. Two or more make a multiple-choice question; mark the correct one with an asterisk, two asterisks for several correct."
      example: "Walk to the corner of Kievskaya and Chui.\nThere is a plaque on the wall giving the year it was built.\nA) 1967\n\nWhich city is the capital of Belarus?\nA) Brest\nB) Grodno\nC) *Minsk"
      option_line_note: "A line in the form “letter) text” is always read as an answer, even in the middle of a task. A task line must not start that way."
```
```yaml
      import_questions: "Import levels in bulk"
```

`config/locales/uk.yml`:
```yaml
      code_label: "код:"
```
```yaml
      title: "Імпорт рівнів у гру «%{game}»"
      intro: "Вставте завдання. Рядок (або кілька рядків поспіль) — текст завдання, потім відповіді. Одна відповідь «A) КОД» — звичайний рівень із кодом. Дві й більше — питання з варіантами; правильний позначте зірочкою, дві зірочки — кілька правильних."
      example: "Дійдіть до рогу Київської та Чуй.\nНа стіні будинку — табличка з роком побудови.\nA) 1967\n\nЯке місто є столицею Білорусі?\nA) Брест\nB) Гродно\nC) *Мінськ"
      option_line_note: "Рядок виду «літера) текст» завжди читається як відповідь — навіть посеред завдання. Рядок завдання не можна так починати."
```
```yaml
      import_questions: "Імпорт рівнів списком"
```

`config/locales/be.yml`:
```yaml
      code_label: "код:"
```
```yaml
      title: "Імпарт узроўняў у гульню «%{game}»"
      intro: "Устаўце заданні. Радок (або некалькі радкоў запар) — тэкст задання, потым адказы. Адзін адказ «A) КОД» — звычайны ўзровень з кодам. Два і больш — пытанне з варыянтамі; правільны адзначце зорачкай, дзве зорачкі — некалькі правільных."
      example: "Дайдзіце да вугла Кіеўскай і Чуй.\nНа сцяне дома — таблічка з годам пабудовы.\nA) 1967\n\nЯкі горад з'яўляецца сталіцай Беларусі?\nA) Брэст\nB) Гродна\nC) *Мінск"
      option_line_note: "Радок выгляду «літара) тэкст» заўсёды чытаецца як адказ — нават пасярод задання. Радок задання нельга так пачынаць."
```
```yaml
      import_questions: "Імпарт узроўняў спісам"
```

`config/locales/pl.yml`:
```yaml
      code_label: "kod:"
```
```yaml
      title: "Import poziomów do gry „%{game}”"
      intro: "Wklej zadania. Wiersz (lub kilka wierszy z rzędu) to treść zadania, potem odpowiedzi. Jedna odpowiedź „A) KOD” tworzy zwykły poziom z kodem. Dwie lub więcej tworzą pytanie z wariantami; poprawny oznacz gwiazdką, dwie gwiazdki oznaczają kilka poprawnych."
      example: "Dojdź do rogu Kijowskiej i Czuj.\nNa ścianie domu jest tabliczka z rokiem budowy.\nA) 1967\n\nKtóre miasto jest stolicą Białorusi?\nA) Brześć\nB) Grodno\nC) *Mińsk"
      option_line_note: "Wiersz w postaci „litera) tekst” zawsze jest czytany jako odpowiedź, nawet w środku zadania. Wiersz treści nie może się tak zaczynać."
```
```yaml
      import_questions: "Import poziomów listą"
```

`config/locales/tr.yml` — note the title puts the case suffix on `adlı oyuna`, never on `%{game}`:
```yaml
      code_label: "kod:"
```
```yaml
      title: "«%{game}» adlı oyuna seviye aktarımı"
      intro: "Görevleri yapıştırın. Bir satır (veya arka arkaya birkaç satır) görev metnidir, ardından yanıtlar gelir. Tek bir «A) KOD» yanıtı sıradan bir kod seviyesi oluşturur. İki ve daha fazlası seçenekli bir soru oluşturur; doğru olanı yıldızla işaretleyin, iki yıldız birden çok doğru yanıt demektir."
      example: "Kievskaya ile Çuy köşesine kadar yürüyün.\nBinanın duvarında yapım yılını veren bir levha var.\nA) 1967\n\nBelarus'un başkenti hangi şehirdir?\nA) Brest\nB) Grodno\nC) *Minsk"
      option_line_note: "«harf) metin» biçimindeki bir satır, görevin ortasında bile her zaman yanıt olarak okunur. Görev satırı böyle başlayamaz."
```
```yaml
      import_questions: "Toplu seviye aktarımı"
```

`config/locales/ka.yml`:
```yaml
      code_label: "კოდი:"
```
```yaml
      title: "დონეების იმპორტი თამაშში «%{game}»"
      intro: "ჩასვით დავალებები. ერთი სტრიქონი (ან რამდენიმე ზედიზედ) — დავალების ტექსტი, შემდეგ პასუხები. ერთი პასუხი «A) კოდი» ქმნის ჩვეულებრივ დონეს კოდით. ორი ან მეტი ქმნის კითხვას ვარიანტებით; სწორი მონიშნეთ ვარსკვლავით, ორი ვარსკვლავი ნიშნავს რამდენიმე სწორს."
      example: "მიდით კიევსკაიასა და ჩუის კუთხემდე.\nსახლის კედელზე არის ფირფიტა აშენების წლით.\nA) 1967\n\nრომელი ქალაქია ბელარუსის დედაქალაქი?\nA) ბრესტი\nB) გროდნო\nC) *მინსკი"
      option_line_note: "სტრიქონი სახით «ასო) ტექსტი» ყოველთვის იკითხება როგორც პასუხი — დავალების შუაშიც კი. დავალების სტრიქონი ასე ვერ დაიწყება."
```
```yaml
      import_questions: "დონეების სიით იმპორტი"
```

- [ ] **Step 4: Show the option-line warning on the paste screen**

In `app/views/quiz_imports/new.html.erb`, immediately after the `<pre class="card">` line that renders `quiz_imports.new.example`:

```erb
<p><%= t("quiz_imports.new.option_line_note") %></p>
```

- [ ] **Step 5: Render each block according to its mode**

In `app/views/quiz_imports/preview.html.erb`, replace the `<ul class="game-list">` body inside the `will_add` fieldset (lines 28–42) with:

```erb
  <ul class="game-list">
    <% @writer.to_add.each do |question| %>
      <li>
        <%# simple_format, not the raw text: a quest task may now carry
            newlines, and ERB would collapse them into one run-on line. %>
        <%= simple_format(question[:text]) %>
        <% if question[:mode] == :quest %>
          <p><%= t("quiz_imports.preview.code_label") %> <strong><%= question[:code] %></strong></p>
        <% else %>
          <ul>
            <% question[:options].each do |option| %>
              <li>
                <%# A glyph, not copy: deliberately not a locale key -- it reads the same in every language, and i18n_spec flags identical ru/en values as untranslated. %><%= option[:correct] ? "✓" : "" %>
                <%= option[:text] %>
              </li>
            <% end %>
          </ul>
        <% end %>
      </li>
    <% end %>
  </ul>
```

Also change the `skipped` fieldset's `<%= question[:text] %>` (line 20) to `<%= simple_format(question[:text]) %>`, for the same newline reason.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/quiz_imports_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 7: Run both full suites — Part A is now complete**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
```

Expected: RSpec 0 failures. Cucumber **232 scenarios (230 passed, 2 undefined), 2342 steps** — the 2 undefined are pre-existing empty placeholders, not a regression. Any other number means a feature file was touched or a shared string moved; stop and investigate.

- [ ] **Step 8: Commit**

```bash
git add app/views/quiz_imports/preview.html.erb app/views/quiz_imports/new.html.erb config/locales spec/requests/quiz_imports_spec.rb
git commit -m "Preview quest blocks as codes, and call the screen 'levels'

The preview renders a code for a quest block and the option list for a
quiz block, and simple_format replaces raw interpolation now that a task
may carry newlines. The screen imports levels rather than questions, so
its title, intro, example and the game-page link say so."
```

---

# Part B — Authorship transfer

Independent of Part A. Tasks 5–8 touch none of the same files and can be merged on their own.

### Task 5: `Game#transfer_authorship_to!`

**Files:**
- Modify: `app/models/game.rb` — add the method after `unfinish!` (around line 127), keeping it with the other `update_column` operator entry points
- Test: `spec/models/game/authorship_spec.rb` (create)

**Interfaces:**
- Produces: `Game#transfer_authorship_to!(user)` → returns the `User`. Raises `ArgumentError` on `nil`. **The only writer of `author_id` after creation.** Tasks 6 and 8 both call it and nothing else.

- [ ] **Step 1: Write the failing test**

Create `spec/models/game/authorship_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The single writer of author_id after creation, mirroring Team#set_captain!.
# See docs/superpowers/specs/2026-08-10-quest-mode-and-authorship-design.md.
RSpec.describe Game, "#transfer_authorship_to!" do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }

  it "moves author_id to the new author" do
    game.transfer_authorship_to!(successor)

    expect(game.reload.author_id).to eq(successor.id)
  end

  it "leaves the in-memory record agreeing with the row" do
    game.transfer_authorship_to!(successor)

    expect(game.author).to eq(successor)
  end

  it "turns author_of? over for both users" do
    game.transfer_authorship_to!(successor)
    game.reload

    expect(author.author_of?(game)).to be false
    expect(successor.author_of?(game)).to be true
  end

  it "refuses nil rather than orphaning the game" do
    expect { game.transfer_authorship_to!(nil) }.to raise_error(ArgumentError)
  end

  # THE trap. The superadmin path has no lifecycle refusals, so this method is
  # reached on running games -- and a running game fails its own validations,
  # because game_starts_in_the_future adds an error whenever starts_at is past
  # and author_finished_at is nil. update! would raise RecordInvalid on exactly
  # the games the operator path exists for.
  #
  # This is the bug withdraw!, restore!, unfinish!, lock_editing! and
  # unlock_editing! all shipped with. Their specs stayed green because
  # create_game defaults starts_at to 2099, so no example had ever exercised a
  # started game. This one does, deliberately.
  it "transfers a game that has already started" do
    running = create_game(:author => author, :starts_at => 1.minute.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)

    expect { running.transfer_authorship_to!(successor) }.not_to raise_error
    expect(running.reload.author_id).to eq(successor.id)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/authorship_spec.rb
```

Expected: FAIL with `NoMethodError: undefined method 'transfer_authorship_to!'`.

- [ ] **Step 3: Add the method**

In `app/models/game.rb`, immediately after `unfinish!`:

```ruby
  # The ONLY writer of author_id after creation, mirroring Team#set_captain!.
  # A game with two ways to change its author is a game whose access control
  # cannot be reasoned about from one place -- and author_id is what
  # ensure_author, ensure_author_if_game_is_draft and every author-only screen
  # ultimately read.
  #
  # update_column, not update!, carrying exactly the reasoning on withdraw!
  # above and for a sharper reason: the superadmin path has NO lifecycle
  # refusals, so this is reached on running games, and a running game fails
  # game_starts_in_the_future. update! would raise RecordInvalid on precisely
  # the games the operator path exists for.
  #
  # The assignment after the write keeps the in-memory record agreeing with the
  # row -- update_column writes the column but leaves the loaded association
  # pointing at the previous author, so a caller rendering game.author straight
  # afterwards would name the wrong person.
  def transfer_authorship_to!(user)
    raise ArgumentError, "no user" if user.nil?

    update_column(:author_id, user.id)
    self.author = user
    user
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/models/game/authorship_spec.rb
```

Expected: PASS, 5 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/game.rb spec/models/game/authorship_spec.rb
git commit -m "Add Game#transfer_authorship_to!

The single writer of author_id after creation, mirroring
Team#set_captain!. update_column deliberately: the superadmin path has
no lifecycle refusals, so this is reached on running games, and a
running game fails game_starts_in_the_future -- update! is the exact
bug withdraw! and its four siblings shipped with, kept green because no
spec had ever exercised a started game. This one does."
```

---

### Task 6: The author's hand-over action

**Files:**
- Modify: `config/routes.rb:107-115` — add `post :hand_over` to the games member block
- Modify: `app/controllers/games_controller.rb` — add `:hand_over` to the `find_game` and `ensure_author` filter lists, add the action
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — add the `games.hand_over` block
- Test: `spec/requests/game_authorship_spec.rb` (create)

**Interfaces:**
- Consumes: `Game#transfer_authorship_to!(user)` from Task 5.
- Produces: route helper `hand_over_game_path(game)` → `POST /games/:id/hand_over`, param `:nickname`. Task 7's form posts to it.

- [ ] **Step 1: Write the failing tests**

Create `spec/requests/game_authorship_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# An author hands a game to another player. Mirrors TeamsController#hand_over,
# including its asymmetry: the author waits for the race to end, the operator
# does not.
describe "handing a game over to another author", type: :request do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def superadmin
    user = create_user
    user.update!(:is_superadmin => true)
    user
  end

  describe "the author" do
    it "transfers the game and says who now owns it" do
      sign_in(author)

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(game.reload.author_id).to eq(successor.id)
      expect(flash[:notice]).to eq(I18n.t("games.hand_over.done", :nickname => successor.nickname))
    end

    # The redirect target is the games LIST, not the game, and deliberately:
    # a draft game is behind ensure_author_if_game_is_draft, so sending the
    # former author back to a game they no longer author would answer their
    # successful transfer with 401.
    it "redirects somewhere the former author can still reach" do
      draft = create_game(:author => author, :is_draft => true)
      sign_in(author)

      post hand_over_game_path(draft), :params => { :nickname => successor.nickname }

      expect(response).to redirect_to(games_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "loses access to the game it just gave away" do
      sign_in(author)
      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      get edit_game_path(game)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "refusals" do
    before { sign_in(author) }

    it "refuses a nickname nobody has, without saying so specifically" do
      post hand_over_game_path(game), :params => { :nickname => "нет-такого" }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.unknown_user"))
    end

    # The same message as an unknown nickname, so the field cannot be used to
    # find out which nicknames exist.
    it "refuses a transfer to yourself with the same message" do
      post hand_over_game_path(game), :params => { :nickname => author.nickname }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.unknown_user"))
    end

    # The lock means "under investigation". Letting its author pass the game to
    # a clean account is an escape hatch from the lock.
    it "refuses while editing is locked" do
      game.lock_editing!

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(game.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.locked"))
    end

    it "refuses while the game is running" do
      running = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)

      post hand_over_game_path(running), :params => { :nickname => successor.nickname }

      expect(running.reload.author_id).to eq(author.id)
      expect(flash[:alert]).to eq(I18n.t("games.hand_over.running"))
    end

    # A finished game IS transferable -- author_finished? clears the running
    # refusal, which is why the condition is not simply started?.
    it "allows a finished game" do
      finished = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      finished.update_column(:author_finished_at, Time.now)

      post hand_over_game_path(finished), :params => { :nickname => successor.nickname }

      expect(finished.reload.author_id).to eq(successor.id)
    end
  end

  describe "who may call it at all" do
    it "refuses a player who is not the author" do
      sign_in(create_user)

      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(response).to have_http_status(:unauthorized)
      expect(game.reload.author_id).to eq(author.id)
    end

    it "refuses a guest" do
      post hand_over_game_path(game), :params => { :nickname => successor.nickname }

      expect(response).to have_http_status(:unauthorized)
    end

    # ensure_author admits superadmins, and B-D3 gives them no lifecycle
    # refusals -- so the two guards above are the AUTHOR's, not everyone's.
    it "lets a superadmin transfer a running game through this same action" do
      running = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(superadmin)

      post hand_over_game_path(running), :params => { :nickname => successor.nickname }

      expect(running.reload.author_id).to eq(successor.id)
    end
  end

  describe "auditing" do
    it "records nothing when the author acts on their own game" do
      sign_in(author)

      expect do
        post hand_over_game_path(game), :params => { :nickname => successor.nickname }
      end.not_to change(AdminAction, :count)
    end

    it "records an operator acting on someone else's game, naming both sides" do
      operator = superadmin
      sign_in(operator)

      expect do
        post hand_over_game_path(game), :params => { :nickname => successor.nickname }
      end.to change(AdminAction, :count).by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("hand_over_authorship")
      expect(entry.target_type).to eq("Game")
      expect(entry.details).to eq("#{author.nickname} -> #{successor.nickname}")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_authorship_spec.rb
```

Expected: FAIL with `NameError: undefined local variable or method 'hand_over_game_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the `resources :games do member do ... end` block (after `post :unlock`):

```ruby
      # Handing the game to another player. POST, not GET: this app has no
      # Turbo and no rails-ujs, so the view drives it with a real form.
      post :hand_over
```

- [ ] **Step 4: Add the locale keys**

Add a `hand_over:` block under the top-level `games:` key in all seven files, as a sibling of `show:`.

`config/locales/ru.yml`:
```yaml
    hand_over:
      done: "Авторство передано: %{nickname}"
      unknown_user: "Игрок с таким ником не найден. Проверьте написание."
      locked: "Нельзя передать авторство, пока редактирование игры заморожено"
      running: "Нельзя передать авторство, пока игра идёт"
```

`config/locales/en.yml`:
```yaml
    hand_over:
      done: "Authorship transferred to %{nickname}"
      unknown_user: "No player with that nickname. Check the spelling."
      locked: "Authorship cannot be transferred while the game’s editing is frozen"
      running: "Authorship cannot be transferred while the game is running"
```

`config/locales/uk.yml`:
```yaml
    hand_over:
      done: "Авторство передано: %{nickname}"
      unknown_user: "Гравця з таким ніком не знайдено. Перевірте написання."
      locked: "Не можна передати авторство, поки редагування гри заморожено"
      running: "Не можна передати авторство, поки гра триває"
```

`config/locales/be.yml`:
```yaml
    hand_over:
      done: "Аўтарства перададзена: %{nickname}"
      unknown_user: "Гульца з такім нікам не знойдзена. Праверце напісанне."
      locked: "Нельга перадаць аўтарства, пакуль рэдагаванне гульні замарожана"
      running: "Нельга перадаць аўтарства, пакуль гульня ідзе"
```

`config/locales/pl.yml` — colon form, so no case suffix has to land on the nickname:
```yaml
    hand_over:
      done: "Autorstwo przekazane: %{nickname}"
      unknown_user: "Nie znaleziono gracza o takim pseudonimie. Sprawdź pisownię."
      locked: "Nie można przekazać autorstwa, dopóki edycja gry jest zamrożona"
      running: "Nie można przekazać autorstwa, gdy gra trwa"
```

`config/locales/tr.yml` — the suffix goes on `adlı oyuncuya`, never on `%{nickname}`:
```yaml
    hand_over:
      done: "«%{nickname}» adlı oyuncuya yazarlık devredildi"
      unknown_user: "Bu takma ada sahip bir oyuncu bulunamadı. Yazımı kontrol edin."
      locked: "Oyunun düzenlenmesi donmuşken yazarlık devredilemez"
      running: "Oyun sürerken yazarlık devredilemez"
```

`config/locales/ka.yml`:
```yaml
    hand_over:
      done: "ავტორობა გადაეცა: %{nickname}"
      unknown_user: "ასეთი მეტსახელით მოთამაშე ვერ მოიძებნა. შეამოწმეთ მართლწერა."
      locked: "ავტორობის გადაცემა შეუძლებელია, სანამ თამაშის რედაქტირება გაყინულია"
      running: "ავტორობის გადაცემა შეუძლებელია, სანამ თამაში მიმდინარეობს"
```

- [ ] **Step 5: Label the new audit action**

`app/views/admin/audit/index.html.erb:34` renders the action name as
`t("admin.audit.index.action.#{entry.action}", :default => entry.action)`. That `:default` is deliberate — without it an unanticipated action would raise under `raise_on_missing_translations` and 500 the audit log for a superadmin. The cost is that a genuinely **missing key fails nowhere and renders as its own identifier**, which is what commit `5d5fefb` had to go back and fix for six actions. So a new audit action without a label is a silent defect no test catches.

Add `hand_over_authorship:` inside the existing `admin: → audit: → index: → action:` block in all seven files:

```yaml
# ru.yml
          hand_over_authorship: "Передал авторство игры"
# en.yml
          hand_over_authorship: "Handed over the game’s authorship"
# uk.yml
          hand_over_authorship: "Передав авторство гри"
# be.yml
          hand_over_authorship: "Перадаў аўтарства гульні"
# pl.yml
          hand_over_authorship: "Przekazał autorstwo gry"
# tr.yml
          hand_over_authorship: "Oyunun yazarlığını devretti"
# ka.yml
          hand_over_authorship: "გადასცა თამაშის ავტორობა"
```

- [ ] **Step 6: Add the action**

In `app/controllers/games_controller.rb`, add `:hand_over` to the `find_game` filter list (line 7) and to the `ensure_author` filter list (line 12). **Do not** add it to `ensure_editing_not_locked` — that filter answers with 401, and the design calls for a readable alert instead.

Then add the action after `unlock`:

```ruby
  # Handing the game to another player. Mirrors TeamsController#hand_over,
  # including its asymmetry.
  def hand_over
    # These two refusals are the AUTHOR's, not the operator's. B-D3 gives a
    # superadmin no lifecycle refusals at all -- exactly as
    # ensure_editing_not_locked already exempts them everywhere else -- which
    # is why this is an in-action check and not that filter: the filter answers
    # with 401, and an author meeting a rule deserves a sentence explaining it.
    unless current_user.superadmin?
      if @game.editing_locked?
        redirect_to games_path, :alert => t("games.hand_over.locked") and return
      end

      if @game.started? && !@game.author_finished?
        redirect_to games_path, :alert => t("games.hand_over.running") and return
      end
    end

    successor = User.find_by(:nickname => params[:nickname].to_s.strip)

    # Unlike Team#set_captain! there is no members association to scope the
    # lookup through -- the target is any user on the instance -- so exactness
    # IS the guard. Not-found and self-transfer share one message so the field
    # cannot be used to discover which nicknames exist.
    if successor.nil? || successor.id == current_user.id
      redirect_to games_path, :alert => t("games.hand_over.unknown_user") and return
    end

    # Both read BEFORE the write: afterwards @game.author is the successor, so
    # neither the audit details nor the operator test would say what happened.
    operator = acting_as_operator?(@game)
    previous = @game.author&.nickname

    @game.transfer_authorship_to!(successor)

    record_admin_action("hand_over_authorship", @game,
                        "#{previous} -> #{successor.nickname}") if operator

    # The games LIST, not the game. A draft sits behind
    # ensure_author_if_game_is_draft, so redirecting to a game the caller has
    # just stopped authoring would answer a successful transfer with 401.
    redirect_to games_path, :notice => t("games.hand_over.done", :nickname => successor.nickname)
  end
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_authorship_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/games_controller.rb config/locales spec/requests/game_authorship_spec.rb
git commit -m "Let an author hand a game to another player

Mirrors TeamsController#hand_over including its asymmetry: the author
waits for the race to end and cannot move a locked game, the superadmin
does neither. The lookup is an exact nickname because, unlike
Team#set_captain!, there is no members association to scope it through;
not-found and self-transfer share one message so the field cannot
enumerate nicknames. The redirect goes to the games list rather than the
game, or handing over a draft would answer with 401."
```

---

### Task 7: The author's form on the game page

**Files:**
- Modify: `app/views/games/show.html.erb` — add a fieldset inside the author block, between the `games/teams` render and the `game-control` div (around line 74)
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — add three `games.show.hand_over_*` keys
- Test: `spec/requests/game_authorship_spec.rb` (extend)

**Interfaces:**
- Consumes: `hand_over_game_path(game)` from Task 6, posting a `:nickname` param.

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block at the end of `spec/requests/game_authorship_spec.rb`, before the final `end`:

```ruby
  describe "the form on the game page" do
    it "is offered to the author" do
      sign_in(author)

      get game_path(game)

      expect(response.body).to include(hand_over_game_path(game))
      expect(response.body).to include(I18n.t("games.show.hand_over_button"))
    end

    # Offering a control the action would refuse is a promise the page cannot
    # keep -- the same rule the import link already follows.
    it "is not offered while the game is running" do
      running = create_game(:author => author, :starts_at => 1.minute.from_now)
      allow(Time).to receive(:now).and_return(1.hour.from_now)
      sign_in(author)

      get game_path(running)

      expect(response.body).not_to include(hand_over_game_path(running))
    end

    it "is not offered while editing is locked" do
      game.lock_editing!
      sign_in(author)

      get game_path(game)

      expect(response.body).not_to include(hand_over_game_path(game))
    end

    it "is not offered to a player who is not the author" do
      sign_in(create_user)

      get game_path(game)

      expect(response.body).not_to include(hand_over_game_path(game))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_authorship_spec.rb -e "the form on the game page"
```

Expected: FAIL — `games.show.hand_over_button` raises `I18n::MissingTranslationData`.

- [ ] **Step 3: Add the locale keys**

Add three keys inside the existing `games: → show:` block in all seven files, after `delete_link:`.

`config/locales/ru.yml`:
```yaml
      hand_over_legend: "Передача авторства"
      hand_over_label: "Ник нового автора"
      hand_over_button: "Передать авторство"
```

`config/locales/en.yml`:
```yaml
      hand_over_legend: "Transferring authorship"
      hand_over_label: "New author’s nickname"
      hand_over_button: "Transfer authorship"
```

`config/locales/uk.yml`:
```yaml
      hand_over_legend: "Передача авторства"
      hand_over_label: "Нік нового автора"
      hand_over_button: "Передати авторство"
```

`config/locales/be.yml`:
```yaml
      hand_over_legend: "Перадача аўтарства"
      hand_over_label: "Нік новага аўтара"
      hand_over_button: "Перадаць аўтарства"
```

`config/locales/pl.yml`:
```yaml
      hand_over_legend: "Przekazanie autorstwa"
      hand_over_label: "Pseudonim nowego autora"
      hand_over_button: "Przekaż autorstwo"
```

`config/locales/tr.yml`:
```yaml
      hand_over_legend: "Yazarlığın devri"
      hand_over_label: "Yeni yazarın takma adı"
      hand_over_button: "Yazarlığı devret"
```

`config/locales/ka.yml`:
```yaml
      hand_over_legend: "ავტორობის გადაცემა"
      hand_over_label: "ახალი ავტორის მეტსახელი"
      hand_over_button: "გადაცემა"
```

- [ ] **Step 4: Add the form**

In `app/views/games/show.html.erb`, insert between `<%= render "games/teams", teams: @teams %>` and the `<div class="game-control">` that follows it:

```erb
  <%# Rendered only when the action would actually allow it, matching the
      import link just above: offering a control the action refuses is a
      promise the page cannot keep. The two conditions are
      GamesController#hand_over's two author-side refusals.

      Its own fieldset, above the edit and delete rows, so the button that
      gives the game away is never the one next to the button the author
      meant to press. %>
  <% unless @game.editing_locked? || (@game.started? && !@game.author_finished?) %>
    <fieldset class="card">
      <legend><%= t("games.show.hand_over_legend") %></legend>

      <%# A real form: this app ships neither Turbo nor rails-ujs. %>
      <%= form_with url: hand_over_game_path(@game), method: :post do %>
        <p>
          <%= label_tag :nickname, t("games.show.hand_over_label") %>
          <%= text_field_tag :nickname, nil, :autocomplete => "off" %>
        </p>
        <p>
          <%= submit_tag t("games.show.hand_over_button"), :class => "btn" %>
        </p>
      <% end %>
    </fieldset>
  <% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/game_authorship_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 6: Prove no frozen scenario regressed**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec cucumber
```

Expected: **232 scenarios (230 passed, 2 undefined), 2342 steps.** This step exists because the new label lands on the game page, which frozen scenarios do inspect. Any other number means the label collided with something a scenario asserts — stop; do **not** edit the feature file.

- [ ] **Step 7: Commit**

```bash
git add app/views/games/show.html.erb config/locales spec/requests/game_authorship_spec.rb
git commit -m "Offer the hand-over form on the game page

Its own fieldset above the edit and delete rows, so the button that
gives the game away is never the one beside the button the author meant
to press. Rendered only when the action would allow it -- the same rule
the import link follows, because offering a control the action refuses
is a promise the page cannot keep."
```

---

### Task 8: The superadmin's override

**Files:**
- Modify: `config/routes.rb:17` — `resources :games, only: [ :index ]` gains a member route
- Modify: `app/controllers/admin/games_controller.rb` — add `AdminAudit` and the `set_author` action
- Modify: `app/views/admin/games/index.html.erb` — add the form to the per-row control cell
- Modify: `config/locales/{ru,en,uk,ka,tr,be,pl}.yml` — add `admin.games.index.set_author`, `admin.games.index.author_nickname`, `admin.games.author_set`, `admin.games.no_such_user`
- Modify: `spec/requests/admin_audit_spec.rb` — add `set_author` to the enumerated audited actions
- Test: `spec/requests/admin_game_authorship_spec.rb` (create)

**Interfaces:**
- Consumes: `Game#transfer_authorship_to!(user)` from Task 5.
- Produces: route helper `set_author_admin_game_path(game)` → `POST /admin/games/:id/set_author`, param `:nickname`.

- [ ] **Step 1: Write the failing tests**

Create `spec/requests/admin_game_authorship_spec.rb`:

```ruby
# -*- encoding : utf-8 -*-
require "rails_helper"

# The operator's override. Mirrors Admin::TeamsController#set_captain: the same
# model method as the author's own path, no lifecycle refusals, always audited.
describe "reassigning a game's author as an operator", type: :request do
  let(:author)    { create_user }
  let(:successor) { create_user }
  let(:game)      { create_game(:author => author) }
  let(:operator)  { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "reassigns the author and says who it now is" do
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(game.reload.author_id).to eq(successor.id)
    expect(response).to redirect_to(admin_games_path)
    expect(flash[:notice]).to eq(I18n.t("admin.games.author_set", :nickname => successor.nickname))
  end

  # B-D3: no lifecycle refusals at all, deliberately -- the same exemption
  # Team#in_live_race? documents for the superadmin captaincy path. This is the
  # example that would fail if transfer_authorship_to! used update! instead of
  # update_column.
  it "reassigns a running game" do
    running = create_game(:author => author, :starts_at => 1.minute.from_now)
    allow(Time).to receive(:now).and_return(1.hour.from_now)
    sign_in(operator)

    post set_author_admin_game_path(running), :params => { :nickname => successor.nickname }

    expect(running.reload.author_id).to eq(successor.id)
  end

  it "reassigns a game whose editing is locked" do
    game.lock_editing!
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(game.reload.author_id).to eq(successor.id)
  end

  it "refuses a nickname nobody has, changing nothing" do
    sign_in(operator)

    post set_author_admin_game_path(game), :params => { :nickname => "нет-такого" }

    expect(game.reload.author_id).to eq(author.id)
    expect(flash[:alert]).to eq(I18n.t("admin.games.no_such_user"))
  end

  # Refused before anything changes, matching Admin::UsersController#revoke, so
  # the log never holds an entry for a change that did not happen.
  it "writes no audit entry for a refused reassignment" do
    sign_in(operator)

    expect do
      post set_author_admin_game_path(game), :params => { :nickname => "нет-такого" }
    end.not_to change(AdminAction, :count)
  end

  it "records the reassignment, naming both sides" do
    sign_in(operator)

    expect do
      post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }
    end.to change(AdminAction, :count).by(1)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("set_author")
    expect(entry.target_type).to eq("Game")
    expect(entry.target_id).to eq(game.id)
    expect(entry.details).to eq("#{author.nickname} -> #{successor.nickname}")
  end

  it "refuses a player who is not a superadmin" do
    sign_in(author)

    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(response).to have_http_status(:unauthorized)
    expect(game.reload.author_id).to eq(author.id)
  end

  it "refuses a guest" do
    post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }

    expect(response).to have_http_status(:unauthorized)
  end

  it "offers the form on the console" do
    sign_in(operator)

    get admin_games_path

    expect(response.body).to include(set_author_admin_game_path(game))
  end
end
```

Also add to `spec/requests/admin_audit_spec.rb`, inside the existing `describe "the explicitly superadmin actions"` block:

```ruby
    it "records an author reassignment" do
      successor = create_user

      expect do
        post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }
      end.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("set_author")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_game_authorship_spec.rb
```

Expected: FAIL with `NameError: undefined local variable or method 'set_author_admin_game_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, replace line 17 inside the `namespace :admin` block:

```ruby
    # The console is otherwise read-only -- editing rides the author's own
    # forms. Authorship is the exception: there is no author's form an
    # operator can borrow when the point is that the current author cannot or
    # will not act. Mirrors admin teams' set_captain.
    resources :games, only: [ :index ] do
      post "set_author", on: :member
    end
```

- [ ] **Step 4: Add the locale keys**

Add `set_author:` and `author_nickname:` inside the existing `admin: → games: → index:` block, and `author_set:`/`no_such_user:` as siblings of `index:` under `admin: → games:` — the same flat-plus-nested shape `admin.teams` already uses.

`config/locales/ru.yml`:
```yaml
        set_author: "Сменить автора"
        author_nickname: "Ник автора"
```
```yaml
      author_set: "Автор игры изменён: %{nickname}"
      no_such_user: "Игрок с таким ником не найден"
```

`config/locales/en.yml`:
```yaml
        set_author: "Change author"
        author_nickname: "Author’s nickname"
```
```yaml
      author_set: "Game author changed to %{nickname}"
      no_such_user: "No player with that nickname"
```

`config/locales/uk.yml`:
```yaml
        set_author: "Змінити автора"
        author_nickname: "Нік автора"
```
```yaml
      author_set: "Автора гри змінено: %{nickname}"
      no_such_user: "Гравця з таким ніком не знайдено"
```

`config/locales/be.yml`:
```yaml
        set_author: "Змяніць аўтара"
        author_nickname: "Нік аўтара"
```
```yaml
      author_set: "Аўтар гульні зменены: %{nickname}"
      no_such_user: "Гульца з такім нікам не знойдзена"
```

`config/locales/pl.yml`:
```yaml
        set_author: "Zmień autora"
        author_nickname: "Pseudonim autora"
```
```yaml
      author_set: "Autor gry zmieniony: %{nickname}"
      no_such_user: "Nie znaleziono gracza o takim pseudonimie"
```

`config/locales/tr.yml`:
```yaml
        set_author: "Yazarı değiştir"
        author_nickname: "Yazarın takma adı"
```
```yaml
      author_set: "Oyunun yazarı değiştirildi: %{nickname}"
      no_such_user: "Bu takma ada sahip bir oyuncu bulunamadı"
```

`config/locales/ka.yml`:
```yaml
        set_author: "ავტორის შეცვლა"
        author_nickname: "ავტორის მეტსახელი"
```
```yaml
      author_set: "თამაშის ავტორი შეიცვალა: %{nickname}"
      no_such_user: "ასეთი მეტსახელით მოთამაშე ვერ მოიძებნა"
```

- [ ] **Step 5: Label the new audit action**

Same reasoning as Task 6, Step 5 — `:default => entry.action` means a missing label renders as a raw identifier and no test fails. Add `set_author:` inside `admin: → audit: → index: → action:` in all seven files:

```yaml
# ru.yml
          set_author: "Сменил автора игры"
# en.yml
          set_author: "Changed the game’s author"
# uk.yml
          set_author: "Змінив автора гри"
# be.yml
          set_author: "Змяніў аўтара гульні"
# pl.yml
          set_author: "Zmienił autora gry"
# tr.yml
          set_author: "Oyunun yazarını değiştirdi"
# ka.yml
          set_author: "შეცვალა თამაშის ავტორი"
```

- [ ] **Step 6: Add the action**

Replace `app/controllers/admin/games_controller.rb` with:

```ruby
# Read-only by design, with one exception. Editing rides the author's own forms
# -- ensure_author admits superadmins -- so there is no second, subtly
# different game editor to keep in sync with the first.
#
# set_author is the exception because there is no author's form to borrow when
# the whole point is that the current author cannot or will not act. It writes
# through Game#transfer_authorship_to!, the same method the author's own path
# calls; nothing here touches author_id directly.
class Admin::GamesController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def index
    # "What just appeared on my instance?" is the operator's first question.
    #
    # game_passings is preloaded because the view renders a count per row.
    # Without it this console issues one COUNT per game -- the one query
    # pattern a screen that lists *everything* can least afford.
    @games = Game.includes(:author, :game_passings).order(:created_at => :desc)
  end

  # No lifecycle refusals, deliberately -- the same exemption the comment on
  # Team#in_live_race? documents for the superadmin captaincy path. An operator
  # reassigns a game precisely BECAUSE it is running badly.
  def set_author
    game = Game.find(params[:id])
    successor = User.find_by(:nickname => params[:nickname].to_s.strip)

    # Refused before anything changes, matching Admin::UsersController#revoke,
    # so the log never holds an entry for a change that did not happen.
    if successor.nil?
      redirect_to admin_games_path, :alert => t("admin.games.no_such_user") and return
    end

    # Read before the write: afterwards game.author is the successor, so the
    # entry would record the change as having no origin.
    previous = game.author&.nickname

    game.transfer_authorship_to!(successor)
    record_admin_action("set_author", game, "#{previous} -> #{successor.nickname}")

    redirect_to admin_games_path,
                :notice => t("admin.games.author_set", :nickname => successor.nickname)
  end
end
```

- [ ] **Step 7: Add the form to the console**

In `app/views/admin/games/index.html.erb`, inside the last `<td>`, after the closing `<% end %>` of the `game.deletable?` block and before `</td>`:

```erb
        <%# Inline per row, exactly as admin/teams/index does for set_captain.
            A text field rather than a select: the target is any user on the
            instance, not a bounded association, so a dropdown would list the
            entire membership on every row. %>
        <div class="game-control">
          <%= form_with url: set_author_admin_game_path(game), method: :post do %>
            <%= label_tag "nickname_#{game.id}", t("admin.games.index.author_nickname") %>
            <%= text_field_tag :nickname, nil, :id => "nickname_#{game.id}", :autocomplete => "off" %>
            <%= submit_tag t("admin.games.index.set_author"), :class => "btn" %>
          <% end %>
        </div>
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec spec/requests/admin_game_authorship_spec.rb spec/requests/admin_audit_spec.rb spec/i18n_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 9: Run both full suites — the plan is complete**

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
bundle exec rspec
bundle exec cucumber
bin/rails zeitwerk:check
```

Expected: RSpec 0 failures. Cucumber **232 scenarios (230 passed, 2 undefined), 2342 steps.** `zeitwerk:check` reports no autoloading problems.

**Do not quote a remembered RSpec example count** — it has moved repeatedly and stale copies have been cited as current. Read the number off this run.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/admin/games_controller.rb app/views/admin/games/index.html.erb config/locales spec/requests/admin_game_authorship_spec.rb spec/requests/admin_audit_spec.rb
git commit -m "Let a superadmin reassign any game's author

The console's first non-index action, and the exception to its
read-only rule: there is no author's form to borrow when the point is
that the current author cannot or will not act. It writes through
Game#transfer_authorship_to! like the author's own path, has no
lifecycle refusals -- the same exemption Team#in_live_race? documents
for superadmin captaincy -- and is always audited, with the refusal
returning before anything changes so the log holds no entry for a
change that did not happen."
```

---

## Notes for the implementer

**Two independent halves.** Tasks 1–4 (importer) and Tasks 5–8 (authorship) share no file. Either can be merged without the other. If review stalls on one, ship the other.

**Three things that will look like mistakes but are not:**

1. **`update_column` in `Game#transfer_authorship_to!`** — not sloppiness. See the comment on the method and the started-game example in Task 5.
2. **The lock and running checks live in the action, not in `ensure_editing_not_locked`** — the filter answers 401; the design calls for a readable alert, and the checks must not apply to superadmins.
3. **`hand_over` redirects to the games list, not the game** — a draft is behind `ensure_author_if_game_is_draft`, so redirecting to a game you just stopped authoring answers a successful transfer with 401.

**One thing no test will catch, so do not skip it.** Both new audit actions need a label under `admin.audit.index.action.*` (Task 6 Step 5, Task 8 Step 5). The audit view passes `:default => entry.action`, so a missing label does not raise — it silently renders the raw identifier in the log. Commit `5d5fefb` had to go back and fix exactly that for six earlier actions.

**If a Cucumber count other than 232/2342 appears, stop.** Do not edit a `.feature` file to make it pass. Three amendments have ever been authorised, each by the repository owner explicitly, and each is recorded in `CLAUDE.md`.
