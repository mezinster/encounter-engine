# -*- encoding : utf-8 -*-
require "rails_helper"

describe GamePassing, "answered_quesions" do
  subject do
    game_passing = GamePassing.new
    game_passing.answered_questions.clear
    game_passing
  end

  context "after initialization" do
    it "should behave like array" do
      subject.answered_questions.should be_kind_of(Array)
    end

    it "should be empty" do
      subject.answered_questions.should be_empty
    end
  end

  context "when it contains some values" do
    before :each do
      @question = Question.create! :correct_answer => 'answer'
      subject.answered_questions << @question
    end

    it "should be persisted correctly" do
      subject.save!
      GamePassing.last.answered_questions.should == [@question]
    end
  end

  context "when the column holds a row written in the old, pre-coder format" do
    before :each do
      subject.save!
      legacy_yaml = "--- !ruby/object:Question\nid: 1\n"
      ActiveRecord::Base.connection.execute(
        "UPDATE game_passings SET answered_questions = #{ActiveRecord::Base.connection.quote(legacy_yaml)} WHERE id = #{subject.id}"
      )
    end

    it "does not raise Psych::DisallowedClass and treats it as no answered questions" do
      reloaded = GamePassing.find(subject.id)

      expect { reloaded.answered_questions }.not_to raise_error
      expect(reloaded.answered_questions).to eq([])
    end

    it "logs a warning naming the affected game_passing id, instead of failing silently" do
      expect(Rails.logger).to receive(:warn).with(a_string_including("GamePassing##{subject.id}"))

      GamePassing.find(subject.id)
    end
  end
end
