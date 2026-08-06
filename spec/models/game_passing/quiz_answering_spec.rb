require "rails_helper"

describe GamePassing, "answering a quiz question" do
  # A pure quiz level -- create_level always builds a code question via
  # correct_answer, which would make every example here silently exercise a
  # MIXED level instead (see finding 2 of the whole-branch review).
  let(:level)    { create_quiz_level }
  let(:question) { create_question(:level => level) }
  let(:passing)  { create_game_passing(:level => level) }

  let!(:paris)  { create_option(:question => question, :text => "Париж", :is_correct => true) }
  let!(:lyon)   { create_option(:question => question, :text => "Лион") }
  let!(:nice)   { create_option(:question => question, :text => "Ницца") }

  before { level.update_column(:wrong_answer_penalty, 300) }

  describe "correctness is set equality" do
    # This level has exactly one question, so a correct answer completes it
    # immediately and pass_level! resets answered_questions right back to
    # empty in the same call -- see the "advancing and finishing" examples
    # below for that transition. This example only pins the return value.
    it "accepts exactly the correct set" do
      expect(passing.answer_options!(question, [ paris.id ])).to be true
    end

    it "rejects a superset that includes a wrong option" do
      expect(passing.answer_options!(question, [ paris.id, lyon.id ])).to be false
      expect(passing.reload.answered_questions).to be_empty
    end

    it "rejects a subset missing a correct option" do
      lyon.update!(:is_correct => true)

      expect(passing.answer_options!(question, [ paris.id ])).to be false
    end

    it "rejects an empty selection" do
      expect(passing.answer_options!(question, [])).to be false
    end
  end

  describe "a wrong answer costs time" do
    it "adds exactly the level's penalty" do
      expect { passing.answer_options!(question, [ lyon.id ]) }
        .to change { passing.reload.penalty_seconds }.from(0).to(300)
    end

    # Deliberately unforgiving: forgiving repeats would let a team walk the
    # whole option space for the price of one mistake.
    it "charges a repeat of a combination already tried" do
      passing.answer_options!(question, [ lyon.id ])
      passing.answer_options!(question, [ lyon.id ])

      expect(passing.reload.penalty_seconds).to eq(600)
    end

    it "charges nothing for a correct answer" do
      expect { passing.answer_options!(question, [ paris.id ]) }
        .not_to change { passing.reload.penalty_seconds }
    end

    # Two teammates submitting a wrong answer at the same instant is normal
    # here. A read-modify-write (update_column against the in-memory value)
    # loses one of the two charges: both processes read penalty_seconds as 0
    # before either writes, so the second write clobbers the first instead of
    # adding to it. See finding 6 of the whole-branch review.
    it "does not lose a charge when two separately-loaded copies charge concurrently" do
      other = GamePassing.find(passing.id)

      passing.answer_options!(question, [ lyon.id ])
      other.answer_options!(question, [ lyon.id ])

      expect(passing.reload.penalty_seconds).to eq(600)
    end

    # THE property the whole penalty design turns on. current_level_entered_at
    # is the sole input to every hint countdown, so moving it would bring the
    # next hint CLOSER on a wrong answer -- punishing the team's ranking while
    # rewarding them with help.
    it "does not move the level clock" do
      # Both sides read the PERSISTED value. Comparing an in-memory timestamp
      # against a reloaded one fails on precision alone -- the attribute keeps
      # nanoseconds while the column stores microseconds -- which would look
      # like this property was broken when it was not.
      entered_at = passing.reload.current_level_entered_at

      passing.answer_options!(question, [ lyon.id ])

      expect(passing.reload.current_level_entered_at).to eq(entered_at)
    end
  end

  # A quiz level with two questions needs no new rule: level_answered? already
  # advances a level only when every question is answered -- but only when
  # any_code_passes is false, which newly created levels no longer default to.
  describe "a level with two quiz questions" do
    before { level.update_column(:any_code_passes, false) }

    let!(:second)   { create_question(:level => level) }
    let!(:s_right)  { create_option(:question => second, :text => "Да", :is_correct => true) }
    let!(:s_wrong)  { create_option(:question => second, :text => "Нет") }

    it "does not advance until both are answered" do
      passing.answer_options!(question, [ paris.id ])

      expect(passing.reload.current_level).to eq(level)
    end

    it "judges each question independently" do
      passing.answer_options!(question, [ paris.id ])
      passing.answer_options!(second, [ s_wrong.id ])

      passing.reload
      expect(passing.answered_questions).to eq([ question ])
      expect(passing.penalty_seconds).to eq(300)
    end
  end

  # No example above ever asserts the level actually advances or the game
  # actually finishes -- deleting `pass_level! if all_questions_answered?`
  # from answer_options! left 82 examples green across the whole suite (see
  # finding 2 of the whole-branch review). These pin the state transition the
  # feature exists for; each was confirmed to fail with that line removed and
  # to pass with it restored.
  describe "advancing and finishing" do
    it "moves current_level to the next level on a correct answer" do
      next_level = create_level(:game => level.game)

      expect { passing.answer_options!(question, [ paris.id ]) }
        .to change { passing.reload.current_level }.from(level).to(next_level)
    end

    it "sets finished_at when the correct answer completes the last level" do
      expect(level.next).to be_nil

      expect { passing.answer_options!(question, [ paris.id ]) }
        .to change { passing.reload.finished_at }.from(nil)
    end
  end
end
