# -*- encoding : utf-8 -*-
require "rails_helper"

describe Level do
  describe "#correct_answer=" do
    context "when there is no questions yet" do
      before :each do
        @correct_answer = "sekrit"
        subject.correct_answer = @correct_answer
      end

      it "should build a question with a given answer" do
        subject.questions.size.should == 1
        subject.questions.first.correct_answer.should == @correct_answer
      end
    end
  end

  describe "#correct_answer" do
    context "when there is no questions yet" do
      it "should return a blank value" do
        subject.correct_answer.should be_blank
      end
    end

    context "when there is one question" do
      before :each do
        subject.questions.build :correct_answer => "the_answer"
      end

      it "should return its answer" do
        subject.correct_answer.should == "the_answer"
      end
    end
  end
end
