# -*- encoding : utf-8 -*-
require "rails_helper"

describe User, '#captain?' do
  describe "when user is captain of some team" do
    before :each do
      @user = create_user
      create_team :captain => @user
    end

    it "returns true" do
      @user.captain?.should be_truthy
    end
  end

  describe "when user does not belong to any team" do
    before :each do
      @user = create_user
    end

    it "returns false" do
      @user.captain?.should be_falsey
    end
  end

  describe "when user is a regular member of some team" do
    before :each do
      @user = create_user
      captain = create_user
      team = create_team :captain => captain
      team.members << @user
      team.save
    end

    it "returns false" do
      @user.captain?.should be_falsey
    end
  end

  # Every example above has a captain, which is why this went unnoticed:
  # Team declares `belongs_to :captain, optional: true`, captain_id is a
  # nullable column, and nothing validates its presence -- so a captain-less
  # team is a state the model permits, even though TeamsController#create
  # always sets one today. Reaching `team.captain.id` on such a team raised
  # NoMethodError, and captain? is called from eight places including
  # SecurityFilters#ensure_team_captain, which gates quitting a game,
  # requesting entry, and inviting members. Those would have 500'd rather
  # than refused.
  describe "when the user's team has no captain at all" do
    it "returns false instead of raising" do
      user = create_user
      team = create_team              # create_team leaves :captain nil unless passed
      team.members << user
      team.save!

      expect(team.captain).to be_nil
      expect { user.reload.captain? }.not_to raise_error
      expect(user.reload.captain?).to be false
    end
  end
end
