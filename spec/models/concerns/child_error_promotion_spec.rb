require "rails_helper"

# Rails' autosave validation reports an invalid child as
# "<Association> имеет неверное значение" -- the name of an association the
# author has never heard of, and no hint of what is actually wrong. On the
# new-level form an empty code produced "Questions имеет неверное значение",
# TWO levels above the real message, which already exists and is already
# translated (ru.yml: answer.value.blank -> "Вы не ввели вариант кода").
describe ChildErrorPromotion do
  let(:game) { create_game }

  describe "Level, whose codes are two associations deep" do
    it "reports what is actually wrong instead of naming the questions association" do
      level = Level.new(:name => "x", :text => "y", :game => game)
      level.correct_answer = ""

      expect(level).not_to be_valid
      expect(level.errors.full_messages).to include(I18n.t("activerecord.errors.models.answer.attributes.value.blank"))
      expect(level.errors.full_messages.join).not_to match(/Questions/i)
    end

    it "still reports its own attribute errors normally" do
      level = Level.new(:name => "", :text => "y", :game => game)
      level.correct_answer = "код"

      expect(level).not_to be_valid
      expect(level.errors[:name]).to be_present
    end

    it "is valid with a code, and promotes nothing" do
      level = Level.new(:name => "x", :text => "y", :game => game)
      level.correct_answer = "код"

      expect(level).to be_valid
      expect(level.errors).to be_empty
    end
  end

  describe "Question, whose codes are one association deep" do
    # The same defect on the "Добавить ещё один код" form, where it surfaced as
    # "Answers имеет неверное значение".
    it "reports what is actually wrong instead of naming the answers association" do
      question = Question.new(:level => create_level(:game => game))
      question.correct_answer = ""

      expect(question).not_to be_valid
      expect(question.errors.full_messages).to include(I18n.t("activerecord.errors.models.answer.attributes.value.blank"))
      expect(question.errors.full_messages.join).not_to match(/Answers/i)
    end
  end

  # Promoted to :base rather than onto the association attribute, because these
  # messages are complete sentences. Adding them to :questions would render
  # "Questions Вы не ввели вариант кода".
  it "adds no attribute name in front of a promoted message" do
    level = Level.new(:name => "x", :text => "y", :game => game)
    level.correct_answer = ""
    level.valid?

    expect(level.errors.full_messages).to eq([ I18n.t("activerecord.errors.models.answer.attributes.value.blank") ])
  end

  it "does not repeat the same message once per invalid child" do
    level = Level.new(:name => "x", :text => "y", :game => game)
    level.questions.build(:correct_answer => "")
    level.questions.build(:correct_answer => "")
    level.valid?

    expect(level.errors.full_messages.size).to eq(1)
  end
end
