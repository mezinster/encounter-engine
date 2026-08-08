# -*- encoding : utf-8 -*-
require "rails_helper"

# db/migrate/20260808070000_add_unique_index_to_game_entries_on_team_and_game.rb
# adds a unique index on game_entries (team_id, game_id), scoped to the
# "live" statuses ("new", "accepted") -- the same two GameEntriesController
# treats as occupying a slot. This is the database-level backstop behind
# GameEntriesController#new's existence check: even a request that bypasses
# the controller (a console script, a future code path) cannot leave a team
# holding two simultaneously-live entries for one game.
describe GameEntry do
  describe "uniqueness of a live entry per (team, game)" do
    it "rejects a second live entry for the same team and game" do
      game = create_game
      team = create_team

      GameEntry.create!(:game => game, :team => team, :status => "new")

      expect {
        GameEntry.create!(:game => game, :team => team, :status => "accepted")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The index is intentionally NOT a blanket uniqueness constraint: it must
    # not reject the legacy pattern GameEntry.of's comment documents and
    # spec/requests/game_registration_enforcement_spec.rb pins -- an entry
    # the author rejected, followed by a later entry for the same team that
    # was accepted. Only one of the two rows is ever "live" at a time.
    it "still allows a rejected entry to coexist with a later accepted one" do
      game = create_game
      team = create_team

      GameEntry.create!(:game => game, :team => team, :status => "rejected")

      expect {
        GameEntry.create!(:game => game, :team => team, :status => "accepted")
      }.not_to raise_error
    end
  end
end
