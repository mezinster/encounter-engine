require "rails_helper"

describe Option do
  let(:level)    { create_level }
  let(:question) { create_question(:level => level) }

  it "belongs to a question and defaults to incorrect" do
    option = Option.create!(:question => question, :text => "Париж")

    expect(option.question).to eq(question)
    expect(option.is_correct).to be false
  end

  it "requires text" do
    expect(Option.new(:question => question, :text => "").valid?).to be false
  end

  # The whole design rests on this: no mode flag exists, so nothing can
  # disagree with reality about what kind of question this is.
  describe "a question is a quiz question iff it has options" do
    it "is not a quiz question with no options" do
      expect(question.quiz?).to be false
      expect(level.quiz?).to be false
    end

    it "is a quiz question as soon as one option exists" do
      create_option(:question => question, :text => "Париж")

      expect(question.reload.quiz?).to be true
      expect(level.reload.quiz?).to be true
    end
  end

  # Radio vs checkbox follows the data, so authors mark what is true rather
  # than picking a control.
  describe "#single_choice?" do
    it "is true when exactly one option is correct" do
      create_option(:question => question, :text => "Париж", :is_correct => true)
      create_option(:question => question, :text => "Лион")

      expect(question.reload.single_choice?).to be true
    end

    it "is false when several options are correct" do
      create_option(:question => question, :text => "Париж", :is_correct => true)
      create_option(:question => question, :text => "Лион",  :is_correct => true)

      expect(question.reload.single_choice?).to be false
    end
  end

  it "destroys its options with the question" do
    create_option(:question => question, :text => "Париж")

    expect { question.destroy }.to change { Option.count }.by(-1)
  end
end
