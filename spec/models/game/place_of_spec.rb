# -*- encoding : utf-8 -*-
require "rails_helper"

describe Game, '#place_of' do
  before :each do
    @game = create_game
    3.times { create_level :game => @game }
  end

  describe "there are several teams finished the game" do
    before :each do
      @finished_teams = {}
      1.upto(5) do |place|
        team = create_team
        GamePassing.create!(:team => team, :game => @game, :game_run => @game.current_run, :finished_at => Time.now + place)
        @finished_teams[place] = team
      end      
    end

    describe "when there are teams still playing" do
      before :each do
        @playing_team = create_team
        GamePassing.create! :team => @playing_team, :game => @game, :game_run => @game.current_run, :current_level => @game.levels.second
      end

      it "should return correct place of each team" do
        @finished_teams.each do |place, team|
          @game.place_of(team).should == place
        end
      end

      it "should return nil if team didn't finish yet" do
        @game.place_of(@playing_team).should be_nil
      end

      it "should return nil if team didn't even startd yet" do
        @game.place_of(create_team).should be_nil
      end
    end
  end

  # Quiz levels charge time for a wrong pick. Ranking therefore compares
  # finished_at + penalty_seconds -- without this the penalty would be
  # recorded and never cost anyone a place.
  #
  # The examples above are the other half of the guarantee: they use no
  # penalties and still pass, which is what proves ranking is unchanged for
  # every game that predates this feature.
  describe "when a team has accrued a penalty" do
    def finished_team(finished_at:, penalty: 0)
      passing = create_game_passing(:level => @game.levels.first)
      passing.update_columns(:finished_at => finished_at, :penalty_seconds => penalty)
      passing.team
    end

    it "puts a big penalty behind a later clean finish" do
      guesser = finished_team(:finished_at => 2.hours.ago, :penalty => 2.hours.to_i)
      clean   = finished_team(:finished_at => 90.minutes.ago)

      expect(@game.place_of(clean)).to eq(1)
      expect(@game.place_of(guesser)).to eq(2)
    end

    it "leaves the order alone when the penalty is small enough not to matter" do
      first  = finished_team(:finished_at => 2.hours.ago, :penalty => 60)
      second = finished_team(:finished_at => 1.hour.ago)

      expect(@game.place_of(first)).to eq(1)
      expect(@game.place_of(second)).to eq(2)
    end
  end
end
