# -*- encoding : utf-8 -*-
require "rails_helper"

# Stripping moved from Question to Answer#strip_spaces when migration 024
# extracted the answers table. The behaviour is still reached through
# Question#correct_answer, which is how callers use it.
describe Question, "#correct_answer" do
  describe "when the answer contains leading or trailing spaces" do
    subject { Question.new :correct_answer => "   bla bla   " }

    describe "when saved" do
      before :each do
        subject.save!
      end

      it "should strip redundant spaces" do
        subject.correct_answer.should == "bla bla"
      end
    end
  end
end
