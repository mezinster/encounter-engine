# -*- encoding : utf-8 -*-
require File.join(File.dirname(__FILE__), '..', '..', 'spec_helper.rb')

describe GamePassing, "#current_level_entered_at" do
  describe "given a game with several levels" do
    before :each do
      @game = create_game
      3.times { create_level :game => @game }
      @game.reload
    end

    describe "given a game passing" do
      before :each do
        @game_passing = create_game_passing :current_level => @game.levels.first
      end

      describe "when game passing created" do
        it "should be equal to creation time" do
          # Compare instants, not formatted strings: the two attributes come
          # back in different zones (one UTC, one local), so #to_s differs even
          # when they refer to the same moment.
          @game_passing.current_level_entered_at.to_i.should == @game_passing.created_at.to_i
        end
      end

      describe "when team enters next level" do
        before :each do
          allow(Time).to receive(:now).and_return(@game_passing.created_at + 1.hour)
          allow(@game_passing).to receive(:correct_answer?).and_return(true)
          @game_passing.check_answer!(@game.levels.first.questions.first.correct_answer)
        end

        it "should be equal to time of level changing" do
          @game_passing.current_level_entered_at.should == Time.now
        end
      end

      describe "when team failed to enter next level" do
        before :each do
          @previous_value = @game_passing.current_level_entered_at

          allow(Time).to receive(:now).and_return(@game_passing.created_at + 1.hour)
          allow(@game_passing).to receive(:correct_answer?).and_return(false)
          @game_passing.check_answer!('incorrect-answer')
        end

        it "should be unchanged" do
          @game_passing.current_level_entered_at.should == @previous_value
        end
      end

      describe "when game passing is somehow updated" do
        before :each do
          @previous_value = @game_passing.current_level_entered_at

          @game_passing.touch
        end

        it "should be unchanged" do
          @game_passing.current_level_entered_at.should == @previous_value
        end
      end
    end
  end
end
