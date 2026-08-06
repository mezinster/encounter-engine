require "rails_helper"

describe GamePassing, "#level_answered?" do
  let(:level)   { create_level }
  let(:passing) { create_game_passing(:level => level) }

  # create_level builds one question; these are the second and third.
  def add_question(code)
    question = Question.new(:correct_answer => code)
    question.level = level
    question.save!
    question
  end

  describe "when all codes are required" do
    before { level.update_column(:any_code_passes, false) }

    it "is false with one of three answered" do
      add_question("два"); add_question("три")
      passing.pass_question!(level.questions.first)

      expect(passing.level_answered?).to be false
    end

    it "is true once every question is answered" do
      second = add_question("два")
      passing.pass_question!(level.reload.questions.first)
      passing.pass_question!(second)

      expect(passing.level_answered?).to be true
    end
  end

  describe "when any code passes" do
    before { level.update_column(:any_code_passes, true) }

    it "is true with one of three answered" do
      add_question("два"); add_question("три")
      passing.pass_question!(level.questions.first)

      expect(passing.level_answered?).to be true
    end

    it "is false with nothing answered" do
      add_question("два")

      expect(passing.level_answered?).to be false
    end
  end

  # A newly created level is redundant by default -- the expectation an author
  # brings to a button labelled "Добавить ещё один код".
  it "defaults a newly created level to any_code_passes" do
    expect(create_level.any_code_passes).to be true
  end
end

describe GamePassing, "passing a level whose codes are redundant" do
  let(:game) { create_game }
  # Both eager and in this order. acts_as_list assigns position on create, so a
  # lazy `let(:level)` would be built AFTER next_level and `level.next` would
  # point the wrong way -- the advancement assertions would then fail for a
  # reason that has nothing to do with the rule under test.
  let!(:level)      { create_level(:game => game) }
  let!(:next_level) { create_level(:game => game) }
  let(:passing) { create_game_passing(:level => level) }

  before do
    second = Question.new(:correct_answer => "второй"); second.level = level; second.save!
    level.reload
  end

  it "advances on the first correct code when any code passes" do
    level.update_column(:any_code_passes, true)

    expect { passing.check_answer!(level.questions.first.correct_answer) }
      .to change { passing.reload.current_level }.from(level).to(next_level)
  end

  it "still requires both codes otherwise" do
    level.update_column(:any_code_passes, false)

    expect { passing.check_answer!(level.questions.first.correct_answer) }
      .not_to change { passing.reload.current_level }
  end

  # The quiz path asks the same question and must answer it the same way.
  it "applies the same rule to the quiz path" do
    level.update_column(:any_code_passes, true)
    question = level.questions.first
    right = create_option(:question => question, :text => "Париж", :is_correct => true)

    expect { passing.answer_options!(question, [ right.id ]) }
      .to change { passing.reload.current_level }.from(level).to(next_level)
  end

  # Flipping the mode must not teleport anyone. The check runs only when a team
  # submits; re-evaluating every passing on flip would complete levels for teams
  # who did nothing, and pass_level! stamps current_level_entered_at, which is
  # the sole input to every hint countdown.
  it "does not move a team that has already answered one code" do
    level.update_column(:any_code_passes, false)
    passing.pass_question!(level.questions.first)

    expect { level.update_column(:any_code_passes, true) }
      .not_to change { passing.reload.current_level }
  end
end
